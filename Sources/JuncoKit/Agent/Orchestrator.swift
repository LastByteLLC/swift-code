// Orchestrator.swift — Main agent pipeline
//
// classify → strategy → plan → execute (2-phase) → reflect
// All features wired: permissions, build verification, diff preview,
// micro-skills, scratchpad, web search, notifications.

import Foundation
import FoundationModels

public actor Orchestrator {

  private let adapter: AFMAdapter
  private let shell: SafeShell
  private let files: FileTools
  private let swiftValidator: SwiftValidator
  private let validatorRegistry: ValidatorRegistry
  private let contextPacker: ContextPacker
  private let reflectionStore: ReflectionStore
  private let skillLoader: SkillLoader
  private let scratchpad: Scratchpad
  private let buildRunner: BuildRunner
  private let diffPreview: DiffPreview
  private let permissionService: PermissionService
  private let patchApplier: PatchApplier
  private let fileWatcher: FileWatcher
  private let lspClient: LSPClient
  private let linter: PostGenerationLinter
  private let errorExtractor: ErrorRegionExtractor
  private let templateRenderer: TemplateRenderer
  private let webResearch: WebResearch
  private let workingDirectory: String
  public let domain: DomainConfig
  private let intentClassifier: IntentClassifier
  private var lspStarted = false

  private var projectIndex: [IndexEntry] = []
  private var needsReindex = true
  private var activeCallbacks: PipelineCallbacks = .none

  public private(set) var verbose: Bool = false
  public func setVerbose(_ value: Bool) { verbose = value }

  public private(set) var metrics: SessionMetrics

  public private(set) var lastDiffs: [String] = []
  public private(set) var lastBuildResult: String?

  public init(adapter: AFMAdapter, workingDirectory: String) {
    self.adapter = adapter
    self.workingDirectory = workingDirectory
    self.shell = SafeShell(workingDirectory: workingDirectory)
    self.swiftValidator = SwiftValidator()
    self.validatorRegistry = ValidatorRegistry.default()
    self.files = FileTools(workingDirectory: workingDirectory)
    self.contextPacker = ContextPacker(workingDirectory: workingDirectory)
    self.reflectionStore = ReflectionStore(projectDirectory: workingDirectory)
    self.skillLoader = SkillLoader(workingDirectory: workingDirectory)
    self.scratchpad = Scratchpad(projectDirectory: workingDirectory)
    self.buildRunner = BuildRunner(
      workingDirectory: workingDirectory,
      domain: DomainDetector(workingDirectory: workingDirectory).detect()
    )
    self.diffPreview = DiffPreview()
    self.patchApplier = PatchApplier(workingDirectory: workingDirectory)
    self.permissionService = PermissionService(workingDirectory: workingDirectory)
    self.domain = DomainDetector(workingDirectory: workingDirectory).detect()
    self.intentClassifier = IntentClassifier()
    self.fileWatcher = FileWatcher(directory: workingDirectory)
    self.lspClient = LSPClient(workingDirectory: workingDirectory)
    self.linter = PostGenerationLinter()
    self.errorExtractor = ErrorRegionExtractor()
    self.templateRenderer = TemplateRenderer()
    self.webResearch = WebResearch()
    self.metrics = SessionMetrics()
  }

  /// Start background file watching. Call once after init.
  public func startFileWatcher() async {
    // Use a Sendable flag box to communicate across actor boundary
    let reindexFlag = ReindexFlag()
    await fileWatcher.start {
      reindexFlag.set()
    }
    // Poll the flag before each run via checkFileWatcher()
    self.reindexFlag = reindexFlag
  }

  private var reindexFlag: ReindexFlag?

  /// Check if the file watcher detected changes. Called at start of run().
  private func checkFileWatcher() {
    if let flag = reindexFlag, flag.consume() {
      needsReindex = true
      debug("FileWatcher: changes detected, reindexing")
    }
  }

  // MARK: - Public API

  public func run(
    query: String,
    referencedFiles: [String] = [],
    urlContext: String? = nil,
    callbacks: PipelineCallbacks = .none
  ) async throws -> RunResult {
    var memory = WorkingMemory(query: query, workingDirectory: workingDirectory)
    lastDiffs = []
    lastBuildResult = nil
    activeCallbacks = callbacks

    // Conversational short-circuit
    if let directResponse = handleConversational(query) {
      return RunResult(memory: memory, reflection: AgentReflection(
        taskSummary: "Conversational query", insight: directResponse,
        improvement: "", succeeded: true
      ))
    }

    // Shell command detection: if input is valid bash syntax and the first
    // word is a real executable (not a task keyword), run it directly.
    if let shellResult = await detectAndRunShellCommand(query) {
      memory.addObservation(StepObservation(
        tool: "bash", outcome: shellResult.exitCode == 0 ? .ok : .error,
        keyFact: String(shellResult.formatted(maxTokens: 120).prefix(120))
      ))
      return RunResult(memory: memory, reflection: AgentReflection(
        taskSummary: "Shell command", insight: shellResult.formatted(maxTokens: 800),
        improvement: "", succeeded: shellResult.exitCode == 0
      ))
    }

    // Pre-read @-referenced files
    var explicitContext = ""
    for path in referencedFiles {
      if let content = try? files.read(path: path, maxTokens: Config.fileReadMaxTokens) {
        explicitContext += "--- @\(path) ---\n\(content)\n\n"
        memory.touch(path)
        debug("PRE-READ @\(path): \(TokenBudget.estimate(content)) tokens")
      }
    }

    // Research Mode: auto-fetch URLs embedded in the query
    if webResearch.hasURLs(in: query) {
      debug("RESEARCH: fetching URLs from query")
      let urlCtx = await webResearch.fetchURLContext(from: query, budget: 400)
      if !urlCtx.isEmpty {
        explicitContext += urlCtx.text + "\n"
        debug("RESEARCH → \(urlCtx.sourceCount) source(s), \(urlCtx.tokens) tokens")
      }
    } else if let urlCtx = urlContext {
      explicitContext += urlCtx + "\n"
      debug("URL context: \(TokenBudget.estimate(urlCtx)) tokens")
    }

    // Check if file watcher detected external changes
    checkFileWatcher()

    // Build or refresh project index
    if needsReindex || projectIndex.isEmpty {
      let indexer = FileIndexer(workingDirectory: workingDirectory)
      projectIndex = indexer.indexProject(extensions: domain.fileExtensions)
      needsReindex = false
      debug("Indexed \(projectIndex.count) symbols from \(domain.displayName) project")
    }

    // Classify
    let intent = try await classify(query: query, memory: &memory, explicitTargets: referencedFiles)
    memory.intent = intent
    memory.mode = intent.agentMode
    await callbacks.onMode?(memory.mode)
    debug("CLASSIFY → mode:\(memory.mode.rawValue) domain:\(intent.domain) type:\(intent.taskType) complexity:\(intent.complexity) targets:\(intent.targets)")

    // Research Mode: search web for disambiguation when needed
    // Triggered when the query is ambiguous (explore with no targets) or
    // references external APIs/frameworks.
    if explicitContext.isEmpty &&
       webResearch.needsResearch(query: query, intent: intent.taskType, targets: intent.targets) {
      debug("RESEARCH: searching web for context")
      let searchCtx = await webResearch.searchContext(query: query, budget: 300)
      if !searchCtx.isEmpty {
        explicitContext += searchCtx.text + "\n"
        debug("RESEARCH → \(searchCtx.sourceCount) source(s), \(searchCtx.tokens) tokens")
      }
    }

    // Mode dispatch — each mode has its own pipeline variant
    switch memory.mode {
    case .build:
      return try await runBuild(memory: &memory, explicitContext: explicitContext, callbacks: callbacks)
    case .search:
      return try await runSearch(memory: &memory, explicitContext: explicitContext, callbacks: callbacks)
    case .plan:
      return try await runPlan(memory: &memory, explicitContext: explicitContext, callbacks: callbacks)
    case .research:
      return try await runResearch(memory: &memory, explicitContext: explicitContext, callbacks: callbacks)
    }
  }

  // MARK: - Build Mode (default pipeline)

  private func runBuild(
    memory: inout WorkingMemory,
    explicitContext: String,
    callbacks: PipelineCallbacks
  ) async throws -> RunResult {
    let query = memory.query
    let intent = memory.intent!

    // Explain/explore shortcut with @-files — supports streaming
    if (intent.taskType == "explain" || intent.taskType == "explore") && !explicitContext.isEmpty {
      debug("SHORTCUT: explain/explore with @-referenced files, skipping plan")
      let explainPrompt = "Task: \(query)\n\nContent:\n\(TokenBudget.truncate(explicitContext, toTokens: 2500))"
      let systemPrompt = "You are a coding assistant. Explain the provided code or documentation clearly and concisely. \(domain.promptHint)"
      memory.trackCall(estimatedTokens: TokenBudget.execute.total)

      let response: String
      if let onStream = callbacks.onStream {
        // Stream output chunk by chunk for real-time display
        response = try await adapter.generateStreaming(
          prompt: explainPrompt, system: systemPrompt, onChunk: onStream
        )
      } else {
        response = try await adapter.generate(prompt: explainPrompt, system: systemPrompt)
      }

      let reflection = AgentReflection(
        taskSummary: "Explained \(intent.targets.joined(separator: ", "))",
        insight: response, improvement: "", succeeded: true
      )
      debug("EXPLAIN → \(TokenBudget.estimate(response)) tokens")
      try? reflectionStore.save(query: query, reflection: reflection)
      metrics.tasksCompleted += 1
      metrics.totalTokensUsed += memory.totalTokensUsed
      metrics.totalLLMCalls += memory.llmCalls
      return RunResult(memory: memory, reflection: reflection, wasStreamed: true)
    }

    // Fast path: DISABLED — the LoRA adapter makes the full pipeline reliable,
    // and the fast path hits context window limits on non-trivial file creation.
    // The regular pipeline (strategy → plan → execute) gives the model separate
    // token budgets per stage, avoiding overflow.
    if false && intent.taskType == "add" && intent.complexity == "simple" {
      let newTargets = intent.targets.filter { !files.exists($0) }
      if !newTargets.isEmpty && newTargets.count <= 2 && explicitContext.isEmpty {
        debug("FAST PATH: simple create for \(newTargets)")

        let urls = Self.extractURLs(query)
        let urlHint = urls.isEmpty ? "" : "\nIMPORTANT: Use these exact URLs in the code (do not substitute): \(urls.joined(separator: ", "))"

        for target in newTargets {
          let prompt = """
            Create the file \(target).
            User request: \(query)\(urlHint)
            Project root: \(workingDirectory)
            """
          memory.trackCall(estimatedTokens: TokenBudget.execute.total)

          let params = try await adapter.generateStructured(
            prompt: prompt,
            system: "Generate the file path and complete content. Follow the user's request precisely. \(domain.promptHint)",
            as: CreateParams.self
          )
          let path = target.isEmpty ? params.filePath : target
          var content = params.content

          // Validate with retry
          var retries = 0
          while retries < Config.maxValidationRetries {
            let feedback = validatorRegistry.validate(code: content, filePath: path)
            guard let error = feedback else { break }
            retries += 1
            debug("FAST PATH validation retry \(retries): \(error)")
            memory.trackCall(estimatedTokens: 800)
            let fixed = try await adapter.generateStructured(
              prompt: "Fix this code.\nError: \(error)\n\nCode:\n\(content)",
              system: "Fix the error. Return the complete corrected file.",
              as: CreateParams.self
            )
            content = fixed.content
          }

          // Final validation
          if let finalError = validatorRegistry.validate(code: content, filePath: path) {
            memory.addObservation(StepObservation(tool: "create", outcome: .error, keyFact: finalError))
            memory.addError(finalError)
            continue
          }

          // Permission + write
          let decision = await askPermission(tool: "create", target: path, detail: "\(content.count) chars")
          guard decision != .deny else { continue }
          memory.touch(path)
          metrics.filesModified += 1
          try files.write(path: path, content: content)
          lastDiffs.append(diffPreview.diffWrite(filePath: path, existingContent: nil, newContent: content))
          memory.addObservation(StepObservation(tool: "create", outcome: .ok, keyFact: "Created \(path) (\(content.count) chars)"))

          // Post-write verification: check URLs were preserved
          for url in urls {
            if !content.contains(url) {
              memory.addError("URL not found in output: \(url)")
            }
          }

          // Post-write verification: check quoted requirements
          if let missing = Self.verifyContent(content: content, query: query) {
            debug("Content verification: \(missing)")
          }
        }

        // Build verify
        if metrics.filesModified > 0 {
          let buildResult = await buildRunner.verify()
          if !buildResult.isEmpty {
            lastBuildResult = buildResult
            if buildResult.contains("FAIL") {
              memory.addError("Build failed: \(String(buildResult.prefix(200)))")
            }
          }
        }

        let reflection = AgentReflection(
          taskSummary: "Created \(newTargets.joined(separator: ", "))",
          insight: memory.didSucceed ? "Files created successfully." : "Some files could not be created.",
          improvement: "", succeeded: memory.didSucceed
        )
        debug("FAST PATH → succeeded:\(reflection.succeeded)")
        try? reflectionStore.save(query: query, reflection: reflection)
        metrics.tasksCompleted += 1
        metrics.totalTokensUsed += memory.totalTokensUsed
        metrics.totalLLMCalls += memory.llmCalls
        return RunResult(memory: memory, reflection: reflection)
      }
    }

    let strategy = try await discoverStrategy(query: query, intent: intent, memory: &memory)
    memory.strategy = strategy
    debug("STRATEGY → approach:\(strategy.approach) start:\(strategy.startingPoints) risk:\(strategy.risk)")

    let plan = try await plan(
      query: query, intent: intent, strategy: strategy,
      memory: &memory, explicitContext: explicitContext
    )

    let maxSteps: Int
    switch intent.complexity {
    case "simple": maxSteps = 3
    case "moderate": maxSteps = 5
    default: maxSteps = 8
    }
    let cappedSteps = Array(plan.steps.prefix(maxSteps))
    if plan.steps.count > maxSteps {
      debug("PLAN capped from \(plan.steps.count) to \(maxSteps) steps")
    }
    memory.plan = AgentPlan(steps: cappedSteps)
    debug("PLAN → \(cappedSteps.count) steps:")
    for (i, step) in cappedSteps.enumerated() {
      debug("  [\(i + 1)] \(step.tool): \(step.instruction) → \(step.target)")
    }

    // Execute with progress callbacks, error recovery, and loop detection
    var lastActions: [(tool: String, target: String)] = []
    var filesWereModified = false
    let totalSteps = cappedSteps.count

    for (index, step) in cappedSteps.enumerated() {
      memory.currentStepIndex = index

      // Progress callback
      await callbacks.onProgress?(index + 1, totalSteps, step.instruction)

      // Loop detection
      if lastActions.count >= 2 {
        let prev = lastActions.suffix(2)
        let stepTool = step.tool
        if prev.allSatisfy({ $0.tool == stepTool && $0.target == step.target }) {
          debug("LOOP detected at step \(index + 1) — breaking")
          memory.addError("Loop detected: repeated \(stepTool) on \(step.target)")
          break
        }
      }

      // Execute with retry support
      var attempt = 0
      let maxRetries = 2

      while true {
        do {
          let observation = try await executeStep(step: step, memory: &memory)
          memory.addObservation(observation)
          lastActions.append((tool: observation.tool, target: step.target))
          if ["create", "write", "edit", "patch"].contains(observation.tool) {
            filesWereModified = true
          }
          debug("EXEC[\(index + 1)] → [\(observation.outcome.rawValue)] \(observation.tool): \(observation.keyFact)")

          // Check if the step itself reported an error in output
          if observation.outcome == .error, let handler = callbacks.onStepError, attempt < maxRetries {
            let recovery = await handler(index + 1, observation.keyFact)
            switch recovery {
            case .retry:
              attempt += 1
              debug("RETRY step \(index + 1), attempt \(attempt)")
              continue
            case .abort:
              debug("ABORT at step \(index + 1)")
              memory.addError("Aborted by user at step \(index + 1)")
              break
            case .skip:
              break
            }
          }
          break  // Move to next step

        } catch let pipelineError as PipelineError {
          // Typed pipeline errors — handle based on recoverability
          debug("EXEC[\(index + 1)] → [PIPELINE ERROR] \(pipelineError)")
          if pipelineError.isRetryable && attempt < maxRetries {
            attempt += 1
            debug("AUTO-RETRY step \(index + 1), attempt \(attempt) (retryable pipeline error)")
            continue
          }
          memory.addError("Step \(index + 1): \(pipelineError)")
          memory.addObservation(StepObservation(
            tool: step.tool, outcome: .error, keyFact: "\(pipelineError)"
          ))
          lastActions.append((tool: step.tool, target: step.target))
          break

        } catch {
          memory.addError("Step \(index + 1): \(error)")
          memory.addObservation(StepObservation(
            tool: step.tool, outcome: .error, keyFact: "\(error)"
          ))
          lastActions.append((tool: step.tool, target: step.target))
          debug("EXEC[\(index + 1)] → [ERROR] \(error)")

          // Error recovery callback
          if let handler = callbacks.onStepError, attempt < maxRetries {
            let recovery = await handler(index + 1, "\(error)")
            switch recovery {
            case .retry:
              attempt += 1
              debug("RETRY step \(index + 1), attempt \(attempt)")
              continue
            case .abort:
              debug("ABORT at step \(index + 1)")
              memory.addError("Aborted by user at step \(index + 1)")
              break
            case .skip:
              break
            }
          }
          break  // Move to next step
        }
      }

      // Check if we should abort the whole pipeline
      if memory.errors.last?.contains("Aborted") == true {
        break
      }

      // Early termination: if step 1 create succeeded for a simple task, skip remaining
      if intent.complexity == "simple" && index == 0 && cappedSteps.count > 1 {
        if let lastObs = memory.observations.last,
           lastObs.tool == "create" && lastObs.outcome == .ok {
          debug("EARLY EXIT: simple create succeeded on step 1, skipping \(cappedSteps.count - 1) remaining steps")
          break
        }
      }
    }

    // Build verification + LSP diagnostics after modifications
    // Only verify if modified files match the project's domain extensions
    let domainExtensions = Set(domain.fileExtensions)
    let modifiedDomainFiles = memory.touchedFiles.filter { path in
      let ext = (path as NSString).pathExtension.lowercased()
      return domainExtensions.contains(ext)
    }

    if filesWereModified && !modifiedDomainFiles.isEmpty {
      // Start LSP lazily on first edit (only for Swift projects)
      if domain.kind == .swift && !lspStarted {
        lspStarted = await lspClient.start()
        if lspStarted { debug("LSP: sourcekit-lsp started") }
      }

      let buildResult = await buildRunner.verify()
      if !buildResult.isEmpty {
        lastBuildResult = buildResult
        debug("BUILD → \(buildResult)")

        // Feed build errors back into memory for reflection
        if buildResult.contains("FAIL") {
          memory.addError("Build failed: \(String(buildResult.prefix(200)))")
        }
      }

      // LSP diagnostics for modified Swift files
      if lspStarted {
        for file in memory.touchedFiles where file.hasSuffix(".swift") {
          let diags = await lspClient.diagnostics(file: file)
          for diag in diags {
            let msg = "[\(diag.severity)] \(file):\(diag.line): \(diag.message)"
            memory.addError(msg)
            debug("LSP → \(msg)")
          }
        }
      }
    }

    // Build-fix reflexion loop: attempt to fix build errors before reflecting
    await buildAndFix(memory: &memory)

    let reflection = try await reflect(memory: &memory)
    debug("REFLECT → succeeded:\(reflection.succeeded) insight:\(reflection.insight)")

    try? reflectionStore.save(query: query, reflection: reflection)

    metrics.tasksCompleted += 1
    metrics.totalTokensUsed += memory.totalTokensUsed
    metrics.totalLLMCalls += memory.llmCalls

    return RunResult(memory: memory, reflection: reflection)
  }

  // MARK: - Search Mode

  /// Cached rg availability (checked once).
  nonisolated(unsafe) private static var _hasRg: Bool?
  private static func hasRg() -> Bool {
    if let cached = _hasRg { return cached }
    let p = Process()
    p.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    p.arguments = ["rg"]
    p.standardOutput = FileHandle.nullDevice
    p.standardError = FileHandle.nullDevice
    do { try p.run(); p.waitUntilExit() } catch { _hasRg = false; return false }
    _hasRg = p.terminationStatus == 0
    return _hasRg!
  }

  private func runSearch(
    memory: inout WorkingMemory,
    explicitContext: String,
    callbacks: PipelineCallbacks
  ) async throws -> RunResult {
    let query = memory.query
    debug("SEARCH MODE → \(query)")

    // Step 1: Generate search queries via LLM
    let fileList = files.listFiles().prefix(25).joined(separator: "\n")
    let sqPrompt = Prompts.searchQueryPrompt(query: query, fileHints: fileList)
    memory.trackCall(estimatedTokens: 600)
    let searchQueries = try await adapter.generateStructured(
      prompt: sqPrompt, system: Prompts.searchQuerySystem, as: SearchQueries.self
    )
    debug("SEARCH queries: \(searchQueries.queries) | files: \(searchQueries.fileHints)")

    // Step 2: Execute searches (deterministic, no LLM)
    var hits: [SearchHit] = []

    // 2a: grep/rg for each query term
    for term in searchQueries.queries.prefix(5) {
      let escaped = shellEscape(term)
      let cmd: String
      if Self.hasRg() {
        cmd = "rg --type swift -n \(escaped) . 2>/dev/null | head -8"
      } else {
        cmd = "grep -rn \(escaped) . --include='*.swift' 2>/dev/null | head -8"
      }
      if let result = try? await shell.execute(cmd), result.exitCode == 0 {
        for line in result.stdout.components(separatedBy: "\n") where !line.isEmpty {
          if let hit = parseGrepLine(line, term: term) {
            hits.append(hit)
          }
        }
      }
    }

    // 2b: Read file hints directly
    for fileHint in searchQueries.fileHints.prefix(3) {
      let matched = files.listFiles().filter {
        $0.lowercased().contains(fileHint.lowercased()) ||
        ($0 as NSString).lastPathComponent.lowercased() == fileHint.lowercased()
      }
      for file in matched.prefix(2) {
        if let content = try? files.read(path: file, maxTokens: 300) {
          hits.append(SearchHit(
            file: file, line: 1,
            snippet: String(content.prefix(200)),
            source: "file", score: 3.0
          ))
        }
      }
    }

    // 2c: RAG symbol search
    for term in searchQueries.queries.prefix(3) {
      let packed = contextPacker.pack(
        query: term, index: projectIndex, budget: 150
      )
      if packed != "(no relevant code found)" {
        hits.append(SearchHit(
          file: "index", line: 0,
          snippet: String(packed.prefix(200)),
          source: "rag", score: 1.0
        ))
      }
    }

    // Step 3: Rank, deduplicate, format
    let ranked = rankAndDeduplicate(hits)
    let hitsText = formatHits(ranked.prefix(10))
    debug("SEARCH → \(ranked.count) hits")

    // Step 4: Synthesize answer via LLM
    if ranked.isEmpty {
      let reflection = AgentReflection(
        taskSummary: "Search: \(query)",
        insight: "No results found for this query. Try rephrasing or using different terms.",
        improvement: "", succeeded: false
      )
      metrics.tasksCompleted += 1
      return RunResult(memory: memory, reflection: reflection)
    }

    memory.trackCall(estimatedTokens: 800)
    let response = try await adapter.generateStructured(
      prompt: Prompts.searchSynthesizePrompt(query: query, hits: hitsText),
      system: Prompts.searchSynthesizeSystem,
      as: AgentResponse.self
    )

    let insight = response.answer + (response.details.isEmpty ? "" : "\n\n" +
      response.details.map { "  • \($0)" }.joined(separator: "\n"))
    let reflection = AgentReflection(
      taskSummary: "Search: \(query)",
      insight: insight,
      improvement: response.followUp.joined(separator: "; "),
      succeeded: true
    )

    metrics.tasksCompleted += 1
    metrics.totalTokensUsed += memory.totalTokensUsed
    metrics.totalLLMCalls += memory.llmCalls
    return RunResult(memory: memory, reflection: reflection)
  }

  /// Parse a grep/rg output line into a SearchHit.
  private func parseGrepLine(_ line: String, term: String) -> SearchHit? {
    // Format: ./path/to/file.swift:42:  matched content
    let parts = line.split(separator: ":", maxSplits: 2)
    guard parts.count >= 2 else { return nil }
    let file = String(parts[0]).replacingOccurrences(of: "./", with: "")
    let lineNum = Int(parts[1]) ?? 0
    let snippet = parts.count > 2 ? String(parts[2]).trimmingCharacters(in: .whitespaces) : ""
    return SearchHit(file: file, line: lineNum, snippet: String(snippet.prefix(120)), source: "grep", score: 2.0)
  }

  /// Deduplicate hits by file+line proximity, sort by score.
  private func rankAndDeduplicate(_ hits: [SearchHit]) -> [SearchHit] {
    var seen: Set<String> = []
    var unique: [SearchHit] = []
    for hit in hits.sorted(by: { $0.score > $1.score }) {
      let key = "\(hit.file):\(hit.line / 5)"  // Group lines within 5 of each other
      if seen.insert(key).inserted {
        unique.append(hit)
      }
    }
    return unique
  }

  /// Format search hits for prompt injection.
  private func formatHits(_ hits: some Collection<SearchHit>) -> String {
    hits.map { hit in
      if hit.line > 0 {
        return "[\(hit.file):\(hit.line)] \(hit.snippet)"
      } else {
        return "[\(hit.file)] \(hit.snippet)"
      }
    }.joined(separator: "\n")
  }

  // MARK: - Plan Mode

  private func runPlan(
    memory: inout WorkingMemory,
    explicitContext: String,
    callbacks: PipelineCallbacks
  ) async throws -> RunResult {
    let query = memory.query
    debug("PLAN MODE → \(query)")

    // Step 1: Gather context (read-only)
    var context = explicitContext
    if context.isEmpty {
      // Read key project files for context
      for file in ["Package.swift", "README.md"] {
        if files.exists(file), let content = try? files.read(path: file, maxTokens: 200) {
          context += "--- \(file) ---\n\(content)\n\n"
        }
      }
      // RAG search for relevant symbols
      let packed = contextPacker.pack(
        query: query, index: projectIndex, budget: 300,
        preferredFiles: memory.intent?.targets ?? []
      )
      if packed != "(no relevant code found)" {
        context += packed
      }
    }

    // Step 2: Generate structured plan via LLM
    let planPrompt = Prompts.planModePrompt(
      query: query, context: TokenBudget.truncate(context, toTokens: 600)
    )
    memory.trackCall(estimatedTokens: 1200)
    let structuredPlan = try await adapter.generateStructured(
      prompt: planPrompt, system: Prompts.planModeSystem, as: StructuredPlan.self
    )

    // Step 3: Format as readable output
    var output = structuredPlan.summary + "\n"
    for section in structuredPlan.sections {
      output += "\n\(section.heading)\n"
      for item in section.items {
        output += "  - \(item)\n"
      }
      if !section.files.isEmpty {
        output += "  Files: \(section.files.joined(separator: ", "))\n"
      }
    }
    if !structuredPlan.questions.isEmpty {
      output += "\nQuestions:\n"
      for q in structuredPlan.questions {
        output += "  ? \(q)\n"
      }
    }
    if !structuredPlan.concerns.isEmpty {
      output += "\nConcerns:\n"
      for c in structuredPlan.concerns {
        output += "  ! \(c)\n"
      }
    }

    let reflection = AgentReflection(
      taskSummary: "Plan: \(query)",
      insight: output,
      improvement: structuredPlan.questions.first ?? "",
      succeeded: true
    )

    metrics.tasksCompleted += 1
    metrics.totalTokensUsed += memory.totalTokensUsed
    metrics.totalLLMCalls += memory.llmCalls
    return RunResult(memory: memory, reflection: reflection)
  }

  // MARK: - Research Mode

  private func runResearch(
    memory: inout WorkingMemory,
    explicitContext: String,
    callbacks: PipelineCallbacks
  ) async throws -> RunResult {
    let query = memory.query
    debug("RESEARCH MODE → \(query)")

    // Step 1: Generate research queries via LLM
    memory.trackCall(estimatedTokens: 600)
    let researchQueries = try await adapter.generateStructured(
      prompt: Prompts.researchQueryPrompt(query: query),
      system: Prompts.researchQuerySystem,
      as: ResearchQueries.self
    )
    debug("RESEARCH queries: \(researchQueries.webSearches) | urls: \(researchQueries.urls)")

    // Step 2: Execute research (web search + URL fetch, concurrent)
    var researchContext = ""

    // 2a: Web searches
    let search = WebSearch()
    for searchQuery in researchQueries.webSearches.prefix(3) {
      if let result = await search.search(query: searchQuery, maxResults: 3) {
        let formatted = search.formatForPrompt(result, budget: 200)
        researchContext += formatted + "\n"
      }
    }

    // 2b: URL fetches
    let fetcher = URLFetcher()
    let urls = researchQueries.urls.prefix(3).compactMap { URL(string: $0) }
    let fetched = await fetcher.fetchAll(urls: urls, totalBudget: 400)
    if let formatted = fetcher.formatForPrompt(fetched: fetched, budget: 300) {
      researchContext += formatted
    }

    // Step 3: Synthesize findings via LLM
    if researchContext.isEmpty {
      let reflection = AgentReflection(
        taskSummary: "Research: \(query)",
        insight: "No results found. The search queries may not have returned relevant results. Try rephrasing.",
        improvement: "", succeeded: false
      )
      metrics.tasksCompleted += 1
      return RunResult(memory: memory, reflection: reflection)
    }

    memory.trackCall(estimatedTokens: 800)
    let response = try await adapter.generateStructured(
      prompt: Prompts.researchSynthesizePrompt(
        query: query,
        context: TokenBudget.truncate(researchContext, toTokens: 600)
      ),
      system: Prompts.researchSynthesizeSystem,
      as: AgentResponse.self
    )

    // Step 4: Store in scratchpad for future Build Mode reference
    let key = "research-\(query.prefix(30).replacingOccurrences(of: " ", with: "-"))"
    scratchpad.write(key: key, value: String(response.answer.prefix(300)))

    let insight = response.answer + (response.details.isEmpty ? "" : "\n\n" +
      response.details.map { "  • \($0)" }.joined(separator: "\n"))
    let reflection = AgentReflection(
      taskSummary: "Research: \(query)",
      insight: insight,
      improvement: response.followUp.joined(separator: "; "),
      succeeded: true
    )

    metrics.tasksCompleted += 1
    metrics.totalTokensUsed += memory.totalTokensUsed
    metrics.totalLLMCalls += memory.llmCalls
    return RunResult(memory: memory, reflection: reflection)
  }

  // MARK: - Conversational

  private func handleConversational(_ query: String) -> String? {
    let lower = query.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)

    let identityPatterns = [
      "who are you", "what are you", "introduce yourself",
      "what is junco", "what can you do", "what can junco do",
      "what do you do", "what does junco do", "help me",
      "what are your capabilities", "tell me about yourself",
      "tell me about junco",
    ]
    if identityPatterns.contains(where: { lower.contains($0) }) {
      return "I'm junco, an on-device AI coding agent running on Apple Foundation Models. " +
        "I can fix bugs, add features, refactor code, explain code, write tests, and search your project. " +
        "I work entirely locally — no cloud, no API keys. " +
        "Detected domain: \(domain.displayName). Type /help for commands."
    }

    let greetings = ["hello", "hi", "hey", "good morning", "good evening", "howdy", "sup"]
    if greetings.contains(where: { lower == $0 || lower.hasPrefix($0 + " ") || lower.hasPrefix($0 + ",") }) {
      return "Hello! I'm junco, your local coding agent. What would you like to work on? " +
        "Try something like: fix the bug in @main.swift, or: explain the auth module."
    }

    if lower.contains("thank") || lower == "thanks" || lower == "ty" {
      return "You're welcome! Let me know if there's anything else."
    }

    return nil
  }

  /// Detect if the user typed a bare shell command and run it directly.
  /// Uses bash -n for syntax validation + checks if the first word is a
  /// real executable AND not an intent keyword (fix, create, explain, etc.).
  private func detectAndRunShellCommand(_ query: String) async -> ShellResult? {
    let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return nil }

    // Extract first word
    let firstWord = trimmed.split(separator: " ", maxSplits: 1).first
      .map { String($0).lowercased() } ?? ""

    // If first word is an intent keyword, it's a task description not a command
    if Self.intentKeywords[firstWord] != nil { return nil }

    // Validate syntax with bash -n (parse without execution)
    let syntaxCheck = Process()
    syntaxCheck.executableURL = URL(fileURLWithPath: "/bin/bash")
    syntaxCheck.arguments = ["-n", "-c", trimmed]
    syntaxCheck.standardOutput = FileHandle.nullDevice
    syntaxCheck.standardError = FileHandle.nullDevice
    do {
      try syntaxCheck.run()
      syntaxCheck.waitUntilExit()
    } catch { return nil }
    guard syntaxCheck.terminationStatus == 0 else { return nil }

    // Check if the first word is an actual executable
    let whichCheck = Process()
    whichCheck.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    whichCheck.arguments = [firstWord]
    whichCheck.standardOutput = FileHandle.nullDevice
    whichCheck.standardError = FileHandle.nullDevice
    do {
      try whichCheck.run()
      whichCheck.waitUntilExit()
    } catch { return nil }
    guard whichCheck.terminationStatus == 0 else { return nil }

    // It's a real shell command — execute it
    debug("SHELL COMMAND detected: \(trimmed)")
    do {
      return try await shell.execute(trimmed)
    } catch {
      return nil
    }
  }

  // MARK: - Pipeline Stages

  private static let intentKeywords: [String: String] = [
    // English
    "explain": "explain", "describe": "explain", "what": "explain",
    "how": "explain", "why": "explain", "summarize": "explain",
    "fix": "fix", "debug": "fix", "repair": "fix",
    "add": "add", "create": "add", "implement": "add", "write": "add",
    "refactor": "refactor", "clean": "refactor", "simplify": "refactor",
    "test": "test",
    "find": "explore", "search": "explore", "grep": "explore",
    "where": "explore", "list": "explore", "show": "explore",
    // Spanish
    "explica": "explain", "explicar": "explain", "qué": "explain",
    "¿qué": "explain", "cómo": "explain", "¿cómo": "explain",
    "arregla": "fix", "corrige": "fix", "repara": "fix",
    "añade": "add", "agrega": "add", "crea": "add",
    "busca": "explore", "encuentra": "explore",
    // French
    "décris": "explain", "qu'est-ce": "explain",
    "répare": "fix",
    "ajoute": "add", "crée": "add",
    "cherche": "explore", "trouve": "explore",
    // German
    "erkläre": "explain", "was": "explain", "wie": "explain",
    "behebe": "fix", "repariere": "fix",
    "füge": "add", "erstelle": "add",
    // Portuguese / French shared
    "explique": "explain", "corrija": "fix", "adicione": "add",
    // Japanese (romanized)
    "setsumei": "explain", "naoshite": "fix",
  ]

  private func classify(
    query: String, memory: inout WorkingMemory, explicitTargets: [String] = []
  ) async throws -> AgentIntent {
    let firstWord = query.lowercased().split(separator: " ").first.map(String.init) ?? ""
    let keywordOverride = Self.intentKeywords[firstWord]

    if let mlResult = intentClassifier.classifyWithConfidence(query), mlResult.confidence > Config.mlClassifierConfidence {
      let finalLabel = keywordOverride ?? mlResult.label
      if keywordOverride != nil && keywordOverride != mlResult.label {
        debug("ML classifier: \(mlResult.label) → overridden to \(finalLabel) (keyword: \(firstWord))")
      } else {
        debug("ML classifier: \(finalLabel) (confidence: \(String(format: "%.2f", mlResult.confidence)))")
      }
      metrics.mlClassifications += 1

      let targets: [String]
      if !explicitTargets.isEmpty {
        targets = explicitTargets
      } else {
        let fileList = files.listFiles()
        let matched = fileList.filter { path in
          query.lowercased().contains((path as NSString).lastPathComponent.lowercased())
        }
        targets = matched.isEmpty ? Array(fileList.prefix(3)) : matched
      }

      // Heuristic mode from taskType: explore + no targets → search
      let inferredMode: String
      if finalLabel == "explore" && targets.isEmpty {
        inferredMode = "search"
      } else if finalLabel == "explain" && explicitTargets.isEmpty {
        inferredMode = "research"
      } else {
        inferredMode = "build"
      }

      return AgentIntent(
        domain: domain.kind.rawValue, taskType: finalLabel,
        complexity: targets.count > 2 ? "moderate" : "simple",
        mode: inferredMode, targets: targets
      )
    }

    debug("ML classifier: low confidence, falling back to LLM")
    let fileList = files.listFiles().prefix(25).joined(separator: "\n")
    let prompt = Prompts.classifyPrompt(
      query: query, fileHints: TokenBudget.truncate(fileList, toTokens: 150)
    )
    memory.trackCall(estimatedTokens: TokenBudget.classify.total)
    return try await adapter.generateStructured(
      prompt: prompt, system: Prompts.classifySystem, as: AgentIntent.self
    )
  }

  private func discoverStrategy(
    query: String, intent: AgentIntent, memory: inout WorkingMemory
  ) async throws -> AgentStrategy {
    // Deterministic strategy for common intent/complexity combinations.
    // Only fall through to LLM for unusual or complex cases.
    if let fast = deterministicStrategy(intent: intent) {
      debug("STRATEGY → deterministic: \(fast.approach)")
      return fast
    }

    let prompt = Prompts.strategyPrompt(query: query, intent: intent)
    memory.trackCall(estimatedTokens: TokenBudget.strategy.total)
    return try await adapter.generateStructured(
      prompt: prompt, system: Prompts.strategySystem, as: AgentStrategy.self
    )
  }

  /// Maps common intent types to strategies without an LLM call.
  /// Returns nil for complex or unusual tasks that need LLM reasoning.
  private func deterministicStrategy(intent: AgentIntent) -> AgentStrategy? {
    switch intent.taskType {
    case "fix":
      return AgentStrategy(
        approach: "read-then-edit",
        startingPoints: intent.targets,
        risk: "Ensure fix doesn't break other code"
      )
    case "add" where intent.complexity == "simple":
      return AgentStrategy(
        approach: "decompose",
        startingPoints: intent.targets,
        risk: "Follow project conventions"
      )
    case "explain", "explore":
      return AgentStrategy(
        approach: "search-then-plan",
        startingPoints: intent.targets,
        risk: "none"
      )
    case "refactor":
      return AgentStrategy(
        approach: "read-then-edit",
        startingPoints: intent.targets,
        risk: "Preserve existing behavior"
      )
    case "test":
      return AgentStrategy(
        approach: "test-first",
        startingPoints: intent.targets,
        risk: "Test isolation"
      )
    default:
      return nil
    }
  }

  private func plan(
    query: String, intent: AgentIntent, strategy: AgentStrategy,
    memory: inout WorkingMemory, explicitContext: String = ""
  ) async throws -> AgentPlan {
    // Deterministic plan: single-file creation (skip LLM planning)
    if intent.taskType == "add" && intent.complexity == "simple" {
      let newTargets = intent.targets.filter { !files.exists($0) }
      if !newTargets.isEmpty {
        let steps = newTargets.map { target in
          PlanStep(instruction: "Create \(target) as requested", tool: "create", target: target)
        }
        debug("DETERMINISTIC PLAN: \(steps.count) create step(s)")
        return AgentPlan(steps: steps)
      }
    }

    let fileContext: String
    if !explicitContext.isEmpty {
      fileContext = TokenBudget.truncate(explicitContext, toTokens: TokenBudget.plan.context)
    } else {
      fileContext = contextPacker.pack(
        query: query, index: projectIndex,
        budget: TokenBudget.plan.context, preferredFiles: strategy.startingPoints
      )
    }
    let prompt = Prompts.planPrompt(
      query: query, intent: intent, strategy: strategy, fileContext: fileContext
    )
    memory.trackCall(estimatedTokens: TokenBudget.plan.total)
    return try await adapter.generateStructured(
      prompt: prompt, system: Prompts.planSystem, as: AgentPlan.self
    )
  }

  private func executeStep(
    step: PlanStep, memory: inout WorkingMemory
  ) async throws -> StepObservation {
    let codeContext: String
    if !step.target.isEmpty, files.exists(step.target) {
      codeContext = (try? files.read(path: step.target, maxTokens: 600)) ?? ""
    } else {
      codeContext = contextPacker.pack(
        query: step.instruction, index: projectIndex,
        budget: 600, preferredFiles: Array(memory.touchedFiles)
      )
    }
    // Use tool from plan directly — no redundant ToolChoice LLM call.
    // The plan already specified which tool to use; re-asking wastes a call.
    let toolName = step.toolName
    debug("  tool: \(toolName.rawValue) (from plan)")

    // Resolve tool parameters and execute (with fallback on context overflow)
    let action: ToolAction
    do {
      action = try await resolveToolAction(
        tool: toolName, step: step, codeContext: codeContext, memory: &memory
      )
    } catch let error as LLMError where toolName == .create {
      if case .contextOverflow = error {
        if step.target.hasSuffix(".swift") {
          // Swift files: two-phase generation (skeleton + fill)
          debug("  context overflow on create — falling back to two-phase generation")
          let twoPhaseContent = try await generateTwoPhase(step: step, memory: &memory)
          let linted = linter.lint(content: twoPhaseContent, filePath: step.target)
          let fallbackAction = ToolAction.create(path: step.target, content: linted)
          let toolOutput = await executeToolSafe(action: fallbackAction, memory: &memory)
          return compressObservation(tool: "create", output: toolOutput, step: step.instruction)
        } else {
          // Non-Swift files: retry with ultra-minimal prompt
          debug("  context overflow on create — retrying with minimal prompt")
          let minimalPrompt = "Create \(step.target): \(String(memory.query.prefix(100)))"
          let retry = try await adapter.generateStructured(
            prompt: minimalPrompt,
            system: "Generate the file content only. Be very concise.",
            as: CreateParams.self,
            options: GenerationOptions(maximumResponseTokens: 2000)
          )
          let retryPath = step.target.isEmpty ? retry.filePath : step.target
          let fallbackAction = ToolAction.create(path: retryPath, content: retry.content)
          let toolOutput = await executeToolSafe(action: fallbackAction, memory: &memory)
          return compressObservation(tool: "create", output: toolOutput, step: step.instruction)
        }
      }
      throw error
    }
    debug("  action: \(action)")

    let toolOutput = await executeToolSafe(action: action, memory: &memory)

    // Notify CLI for live action log
    await activeCallbacks.onToolResult?(action.toolLabel, action.targetPath ?? "", toolOutput)

    return compressObservation(tool: toolName.rawValue, output: toolOutput, step: step.instruction)
  }

  private func resolveToolAction(
    tool: ToolName, step: PlanStep, codeContext: String,
    memory: inout WorkingMemory
  ) async throws -> ToolAction {
    let base = "Step: \(step.instruction)\nTarget: \(step.target)\nProject root: \(workingDirectory)"
    memory.trackCall(estimatedTokens: 600)

    switch tool {
    case .bash:
      let p = try await adapter.generateStructured(
        prompt: base,
        system: "Generate a bash command. Working directory: \(workingDirectory). Use relative paths.",
        as: BashParams.self
      )
      return .bash(command: p.command)

    case .read:
      if !step.target.isEmpty, files.exists(step.target) {
        return .read(path: step.target)
      }
      let p = try await adapter.generateStructured(
        prompt: base, system: "Specify the file path to read.", as: ReadParams.self
      )
      return .read(path: p.filePath)

    case .create:
      let createTarget = step.target.isEmpty ? "" : step.target
      let createTargetLower = createTarget.lowercased()

      // Route 1: Template-based generation for structured file formats
      // The model fills in simple intent fields; the template guarantees valid syntax.
      if templateRenderer.shouldUseTemplate(filePath: createTarget) {
        let intentPrompt = "\(base)\nUser request: \(TokenBudget.truncate(memory.query, toTokens: 200))"
        memory.trackCall(estimatedTokens: 600)
        if let rendered = try await templateRenderer.resolveTemplate(
          filePath: createTarget, prompt: intentPrompt, adapter: adapter
        ) {
          return .create(path: createTarget, content: rendered)
        }
      }

      // Route 2: Plain text generation for code and prose files
      // Per TN3193: avoid @Generable for large content — JSON escaping doubles token cost.
      // Generate content as plain text; file path comes from the plan step target.
      let createURLs = Self.extractURLs(memory.query)
      let createURLHint = createURLs.isEmpty ? "" : "\nUse these exact URLs: \(createURLs.joined(separator: ", "))"

      var createSystem = "Output only the file content. No markdown fences, no explanation."
      if createTargetLower.hasSuffix(".swift") {
        let skillHint = skillLoader.skillHints(
          domain: memory.intent?.domain ?? "swift",
          taskType: memory.intent?.taskType ?? "add",
          budget: 100
        )
        if let hint = skillHint { createSystem += " " + hint }
      }

      let createPrompt = "Create \(createTarget).\nRequest: \(TokenBudget.truncate(memory.query, toTokens: 150))\(createURLHint)"

      // Plain text generation — TokenGuard applied automatically in adapter
      var content = try await adapter.generate(prompt: createPrompt, system: createSystem)
      content = linter.cleanPlainTextOutput(content, filePath: createTarget)
      let path = createTarget.isEmpty ? createTarget : createTarget
      return .create(path: path, content: content)

    case .write:
      let writeURLs = Self.extractURLs(memory.query)
      let writeURLHint = writeURLs.isEmpty ? "" : "\nIMPORTANT: Use these exact URLs (do not substitute): \(writeURLs.joined(separator: ", "))"
      let p = try await adapter.generateStructured(
        prompt: "\(base)\nUser request: \(TokenBudget.truncate(memory.query, toTokens: 150))\(writeURLHint)\n\nExisting:\n\(codeContext)",
        system: "Generate file path and complete content to write. Follow the user's request precisely.",
        as: WriteParams.self
      )
      let writePath = step.target.isEmpty ? p.filePath : step.target
      return .write(path: writePath, content: p.content)

    case .edit:
      let editSystem = "Specify exact text to find and its replacement. Find text must match the file exactly. Use a full line or block, not a single word."
      // Priority-weighted prompt: file content is most critical, then request, then hints
      let reflectionHint = reflectionStore.formatForPrompt(query: memory.query) ?? ""
      let skillHint = step.target.hasSuffix(".swift")
        ? (skillLoader.skillHints(domain: memory.intent?.domain ?? "swift", taskType: memory.intent?.taskType ?? "fix", budget: 100) ?? "")
        : ""
      let editBudget = TokenBudget.contextWindow - TokenBudget.estimate(editSystem) - 150 - 400
      let editPrompt = base + "\nRequest: " + TokenBudget.truncate(memory.query, toTokens: 100) + "\n\n"
        + TokenBudget.packSections([
          PromptSection(label: "File", content: codeContext, priority: 90),
          PromptSection(label: "Memory", content: memory.compactDescription(tokenBudget: 150), priority: 70),
          PromptSection(label: "Past experience", content: reflectionHint, priority: 30),
          PromptSection(label: "Hints", content: skillHint, priority: 20),
        ], budget: editBudget)
      let editInputEst = TokenBudget.estimate(editPrompt) + TokenBudget.estimate(editSystem) + 150
      let editMaxOutput = max(400, TokenBudget.contextWindow - editInputEst - 100)
      let p = try await adapter.generateStructured(
        prompt: editPrompt,
        system: editSystem,
        as: EditParams.self,
        options: GenerationOptions(maximumResponseTokens: editMaxOutput)
      )
      let editPath = step.target.isEmpty ? p.filePath : step.target
      return .edit(path: editPath, find: p.find, replace: p.replace)

    case .patch:
      let p = try await adapter.generateStructured(
        prompt: "\(base)\n\nFile content:\n\(codeContext)",
        system: "Generate a unified diff patch for this file. Use +/- line prefixes and @@ hunk headers.",
        as: PatchParams.self
      )
      return .patch(path: p.filePath, diff: p.patch)

    case .search:
      let p = try await adapter.generateStructured(
        prompt: base, system: "Specify a grep pattern.", as: SearchParams.self
      )
      return .search(pattern: p.pattern)

    // Switch is exhaustive — no unknown tools possible with ToolName enum
    }
  }

  // MARK: - Two-Phase Code Generation

  /// Generate a complex Swift file by first creating a skeleton (imports, type, properties,
  /// method signatures), then filling each method body in a separate LLM call.
  /// Each phase gets its own fresh 4K context window — no overflow risk.
  private func generateTwoPhase(
    step: PlanStep,
    memory: inout WorkingMemory
  ) async throws -> String {
    let query = TokenBudget.truncate(memory.query, toTokens: 150)
    debug("  two-phase: generating skeleton")

    // Phase 1: Skeleton
    memory.trackCall(estimatedTokens: 800)
    let skeleton = try await adapter.generateStructured(
      prompt: "Create the structure for: \(step.instruction)\nUser request: \(query)",
      system: "Generate ONLY the file skeleton: imports, type declaration, properties, and method signatures WITHOUT bodies. No implementation code.",
      as: CodeSkeleton.self
    )

    // Assemble skeleton
    var lines: [String] = []
    lines.append(skeleton.imports)
    lines.append("")
    lines.append(skeleton.typeDeclaration)
    for prop in skeleton.properties.components(separatedBy: "\n") where !prop.isEmpty {
      lines.append("    \(prop.trimmingCharacters(in: .whitespaces))")
    }
    lines.append("")

    // Phase 2: Fill each method body
    let propsSummary = TokenBudget.truncate(skeleton.properties, toTokens: 80)
    for sig in skeleton.methodSignatures where !sig.isEmpty {
      let shortSig = String(sig.prefix(120))
      debug("  two-phase: filling method \(shortSig.prefix(50))")
      memory.trackCall(estimatedTokens: 400)
      let body = try await adapter.generateStructured(
        prompt: "\(shortSig)\nContext: \(propsSummary)",
        system: "Implement this Swift method. Return only the method with body. Be concise.",
        as: MethodBody.self
      )
      lines.append("    \(body.implementation.trimmingCharacters(in: .whitespaces))")
      lines.append("")
    }

    lines.append("}")
    var result = lines.joined(separator: "\n")

    // Lint the assembled file
    let path = step.target
    result = linter.lint(content: result, filePath: path)

    return result
  }

  // MARK: - Validation + Fix Helper

  /// Lint, validate, and retry-fix code up to maxValidationRetries.
  /// Used by both create and write tool execution paths.
  /// Returns the (possibly fixed) content, or nil with an error message if validation still fails.
  private func validateAndFix(
    content: String,
    filePath: String,
    memory: inout WorkingMemory
  ) async throws -> (content: String, error: String?) {
    var content = linter.lint(content: content, filePath: filePath)

    var retries = 0
    while retries < Config.maxValidationRetries {
      let feedback = swiftValidator.feedbackForLLM(code: content, filePath: filePath)
      guard let error = feedback else { break }
      retries += 1

      if let region = errorExtractor.extract(content: content, errorMessage: error) {
        debug("Targeted retry \(retries) for \(filePath) (lines \(region.startLine)-\(region.endLine)): \(error)")
        memory.trackCall(estimatedTokens: 500)
        let fixed = try await adapter.generateStructured(
          prompt: "Fix this code.\nError: \(String(error.prefix(200)))\n\nCode:\n\(region.text)",
          system: "Fix ONLY this code region. Return the corrected code.",
          as: CodeFragment.self
        )
        content = errorExtractor.splice(original: content, region: region, fix: fixed.content)
      } else {
        debug("Full retry \(retries) for \(filePath): \(error)")
        memory.trackCall(estimatedTokens: 800)
        let truncatedCode = TokenBudget.truncate(content, toTokens: 800)
        let fixed = try await adapter.generateStructured(
          prompt: "Fix this code.\nError: \(String(error.prefix(200)))\n\nCode:\n\(truncatedCode)",
          system: "Fix the error. Return the complete corrected file.",
          as: CreateParams.self
        )
        content = fixed.content
      }
      content = linter.lint(content: content, filePath: filePath)
    }

    if let finalError = validatorRegistry.validate(code: content, filePath: filePath) {
      debug("Validation failed after \(retries) retries for \(filePath): \(finalError)")
      return (content, "VALIDATION FAILED: \(finalError)")
    }

    return (content, nil)
  }

  // MARK: - Build-Fix Reflexion Loop

  /// After all execute steps, run a build and attempt to fix errors.
  /// Uses targeted retry: extract error region, fix just that part.
  private func buildAndFix(memory: inout WorkingMemory, maxCycles: Int = 2) async {
    guard metrics.filesModified > 0 else { return }
    guard domain.buildCommand != nil else { return }

    for cycle in 0..<maxCycles {
      let buildResult = await buildRunner.verify()
      guard !buildResult.isEmpty, buildResult.contains("error:") else {
        if cycle > 0 { debug("Build-fix cycle \(cycle + 1): clean build") }
        return
      }

      debug("Build-fix cycle \(cycle + 1): \(buildResult.prefix(100))")
      lastBuildResult = buildResult

      let errors = errorExtractor.parseErrors(buildResult)
      guard !errors.isEmpty else { return }

      // Fix up to 3 errors per cycle, only in files we modified
      for error in errors.prefix(3) {
        let errorPath = error.filePath
        guard memory.touchedFiles.contains(errorPath) || memory.touchedFiles.contains(where: { errorPath.hasSuffix($0) }) else {
          continue // Don't touch files we didn't modify
        }

        guard let fileContent = try? files.read(path: errorPath, maxTokens: 2000) else { continue }
        guard let region = errorExtractor.extract(content: fileContent, errorLine: error.line) else { continue }

        debug("  build-fix: \(errorPath):\(error.line) — \(error.message)")
        memory.trackCall(estimatedTokens: 500)

        do {
          let fixed = try await adapter.generateStructured(
            prompt: "Fix this code.\nError: \(error.message)\n\nCode:\n\(region.text)",
            system: "Fix ONLY this code region. Return the corrected code.",
            as: CodeFragment.self
          )

          let newContent = errorExtractor.splice(original: fileContent, region: region, fix: fixed.content)
          let linted = linter.lint(content: newContent, filePath: errorPath)
          try files.write(path: errorPath, content: linted)
        } catch {
          debug("  build-fix failed: \(error)")
        }
      }
    }
  }

  private func reflect(memory: inout WorkingMemory) async throws -> AgentReflection {
    // Skip LLM reflection on clean success — saves 1 call.
    // Only use LLM for failures/partial success where insight is valuable.
    if memory.didSucceed && memory.errors.isEmpty {
      let taskType = memory.intent?.taskType ?? "Task"
      return AgentReflection(
        taskSummary: "\(taskType) completed",
        insight: "All \(memory.observations.count) steps succeeded.",
        improvement: "",
        succeeded: true
      )
    }

    let prompt = Prompts.reflectPrompt(memory: memory)
    memory.trackCall(estimatedTokens: TokenBudget.reflect.total)
    var reflection = try await adapter.generateStructured(
      prompt: prompt, system: Prompts.reflectSystem, as: AgentReflection.self
    )
    // Override AFM's succeeded judgment with deterministic check —
    // AFM almost always generates true regardless of actual outcomes.
    reflection.succeeded = memory.didSucceed
    return reflection
  }

  // MARK: - Permission Handling

  /// Check permission: pre-approved rules first, then callback to CLI.
  private func askPermission(tool: String, target: String, detail: String) async -> PermissionDecision {
    // Check persistent always-allow rules
    if permissionService.isAllowed(tool: tool, target: target) {
      debug("Permission: \(tool) \(target) — pre-approved")
      return .allow
    }

    // Ask the CLI via callback
    if let handler = activeCallbacks.onPermission {
      let decision = await handler(tool, target, detail)
      // If user chose always-allow, persist the rule
      if decision == .alwaysAllow {
        permissionService.saveAlwaysAllow(tool: tool, target: target)
      }
      return decision
    }

    // No callback (pipe mode or tests) — auto-allow
    return .allow
  }

  // MARK: - Tool Execution (with permissions + diff capture)

  private func executeToolSafe(action: ToolAction, memory: inout WorkingMemory) async -> String {
    do {
      return try await executeTool(action: action, memory: &memory)
    } catch {
      return "ERROR: \(error)"
    }
  }

  private func executeTool(action: ToolAction, memory: inout WorkingMemory) async throws -> String {
    // Centralized permission check for file-modifying tools
    if action.requiresPermission, let target = action.targetPath {
      let decision = await askPermission(tool: action.toolLabel, target: target, detail: action.permissionDetail)
      guard decision != .deny else { return "DENIED: \(action.toolLabel) \(target)" }
    }

    switch action {
    case .bash(let command):
      metrics.bashCommandsRun += 1
      let result = try await shell.execute(command)
      return result.formatted(maxTokens: Config.toolOutputMaxTokens)

    case .read(let path):
      memory.touch(path)
      return try files.read(path: path, maxTokens: Config.fileReadMaxTokens)

    case .create(let path, var content):
      // Fail if file already exists — use edit for existing files
      if files.exists(path) {
        return "ERROR: File already exists: \(path). Use edit to modify existing files."
      }
      // Lint → validate → targeted retry
      let validated = try await validateAndFix(content: content, filePath: path, memory: &memory)
      content = validated.content
      if let validationError = validated.error {
        return validationError
      }

      memory.touch(path)
      metrics.filesModified += 1
      try files.write(path: path, content: content)

      guard files.exists(path) else {
        return "ERROR: File not created despite write succeeding: \(path)"
      }

      let createDiff = diffPreview.diffWrite(filePath: path, existingContent: nil, newContent: content)
      lastDiffs.append(createDiff)
      return "Created \(path) (\(content.count) chars)"

    case .write(let path, var content):
      // Lint → validate → targeted retry (same pipeline as create)
      let writeValidated = try await validateAndFix(content: content, filePath: path, memory: &memory)
      content = writeValidated.content
      if let validationError = writeValidated.error {
        return validationError
      }

      let existing = try? files.read(path: path, maxTokens: 2000)
      memory.touch(path)
      metrics.filesModified += 1
      try files.write(path: path, content: content)

      let diff = diffPreview.diffWrite(filePath: path, existingContent: existing, newContent: content)
      lastDiffs.append(diff)
      return "Written \(path) (\(content.count) chars)"

    case .edit(let path, let find, let replace):
      // Capture before content for diff
      let before = try? files.read(path: path, maxTokens: 2000)
      memory.touch(path)
      metrics.filesModified += 1

      do {
        try files.edit(path: path, find: find, replace: replace)
      } catch is FileToolError {
        try files.edit(path: path, find: find, replace: replace, fuzzy: true)
      }

      // Per-tool verification: confirm the replacement text is present
      let afterContent = try? files.read(path: path, maxTokens: 2000)
      if let after = afterContent, !replace.isEmpty {
        let checkSnippet = String(replace.prefix(60))
        if !after.contains(checkSnippet) {
          return "ERROR: Edit verification failed — replacement text not found in \(path)"
        }
      }

      // Capture after + generate diff
      if let before, afterContent != nil {
        if let d = diffPreview.diff(filePath: path, originalContent: before, find: find, replace: replace) {
          lastDiffs.append(d)
        }
      }
      return "Edited \(path)"

    case .patch(let path, let diff):
      let before = try? files.read(path: path, maxTokens: 2000)
      memory.touch(path)
      metrics.filesModified += 1

      do {
        try patchApplier.apply(patch: diff, to: path)
        if let before {
          let after = (try? files.read(path: path, maxTokens: 2000)) ?? ""
          let d = diffPreview.diffWrite(filePath: path, existingContent: before, newContent: after)
          lastDiffs.append(d)
        }
        return "Patched \(path)"
      } catch {
        return "Patch failed: \(error)"
      }

    case .search(let pattern):
      let cmd = "grep -rn \(shellEscape(pattern)) . --include='*.swift' | head -20"
      let result = try await shell.execute(cmd)
      return result.formatted(maxTokens: Config.toolOutputMaxTokens)
    }
  }

  private func compressObservation(tool: String, output: String, step: String) -> StepObservation {
    let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
    let outcome: StepOutcome
    if output.hasPrefix("DENIED") {
      outcome = .denied
    } else if output.hasPrefix("VALIDATION FAILED") {
      outcome = .validationFailed
    } else if output.contains("ERROR") || output.contains("FAILED") {
      outcome = .error
    } else {
      outcome = .ok
    }
    let keyFact = lines.first.map(String.init) ?? "no output"
    return StepObservation(tool: tool, outcome: outcome, keyFact: String(keyFact.prefix(120)))
  }

  // MARK: - Helpers

  /// Extract URLs from text for literal passthrough to code generation prompts.
  /// These URLs should be embedded in generated code, NOT fetched.
  static func extractURLs(_ text: String) -> [String] {
    guard let detector = try? NSDataDetector(
      types: NSTextCheckingResult.CheckingType.link.rawValue
    ) else { return [] }
    let range = NSRange(text.startIndex..., in: text)
    return detector.matches(in: text, range: range).compactMap { match in
      Range(match.range, in: text).map { String(text[$0]) }
    }
  }

  /// Verify that key quoted terms from the user's query appear in the generated content.
  /// Returns a description of missing content, or nil if all present.
  static func verifyContent(content: String, query: String) -> String? {
    // Extract double-quoted and single-quoted strings from the query
    let pattern = #""([^"]+)"|'([^']+)'"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    let range = NSRange(query.startIndex..., in: query)
    let matches = regex.matches(in: query, range: range)

    var missing: [String] = []
    for match in matches {
      for group in 1...2 {
        if let r = Range(match.range(at: group), in: query) {
          let value = String(query[r])
          if !content.contains(value) {
            missing.append(value)
          }
        }
      }
    }
    return missing.isEmpty ? nil : "Missing required content: \(missing.joined(separator: ", "))"
  }

  private func shellEscape(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  private func debug(_ message: String) {
    guard verbose else { return }
    // Dim gray — visible if you look for it but doesn't compete with output
    let styled = "\u{1B}[2m[debug] \(message)\u{1B}[0m\n"
    FileHandle.standardError.write(styled.data(using: .utf8) ?? Data())
  }
}

// MARK: - Types

public struct RunResult: Sendable {
  public let memory: WorkingMemory
  public let reflection: AgentReflection
  /// True if the response was already streamed to the user via callbacks.
  public let wasStreamed: Bool

  public init(memory: WorkingMemory, reflection: AgentReflection, wasStreamed: Bool = false) {
    self.memory = memory
    self.reflection = reflection
    self.wasStreamed = wasStreamed
  }
}

public enum OrchestratorError: Error, Sendable {
  case editFailed(String)
  case toolFailed(String)
}

/// Thread-safe flag for cross-actor communication (FileWatcher → Orchestrator).
/// Thread-safe atomic boolean flag. Used for cross-boundary signaling.
public final class ReindexFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  public init() {}

  public func set() { lock.withLock { value = true } }
  public func consume() -> Bool { lock.withLock { let v = value; value = false; return v } }
}

public struct SessionMetrics: Sendable {
  public var tasksCompleted: Int = 0
  public var totalTokensUsed: Int = 0
  public var totalLLMCalls: Int = 0
  public var filesModified: Int = 0
  public var bashCommandsRun: Int = 0
  public var mlClassifications: Int = 0
}
