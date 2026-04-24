// swiftlint:disable file_length
// Orchestrator.swift — Main agent pipeline
//
// classify → plan → execute (2-phase) → reflect
// All features wired: permissions, build verification, diff preview,
// micro-skills, scratchpad, web search, notifications.

import Foundation
import FoundationModels

public actor Orchestrator {

  private let adapter: any LLMAdapter

  /// The display name of the active model backend.
  nonisolated public var backendName: String { adapter.backendName }
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
  private let treeSitterRepair: TreeSitterRepair
  private let errorExtractor: ErrorRegionExtractor
  private let templateRenderer: TemplateRenderer
  private let webResearch: WebResearch
  private let candidateGenerator: CandidateGenerator
  private let signatureIndex: SignatureIndex
  private let apiProvider: TieredAPISurfaceProvider
  private let workingDirectory: String
  public let domain: DomainConfig
  private let intentClassifier: IntentClassifier
  private let projectAnalyzer: ProjectAnalyzer
  private let taskResolver: TaskResolver
  private var lspStarted = false

  private var projectIndex: [IndexEntry] = []
  private let embeddingIndex: EmbeddingIndex
  private var referenceGraph: ReferenceGraph = .empty
  private var projectSnapshot: ProjectSnapshot = .empty
  private var needsReindex = true
  private var activeCallbacks: PipelineCallbacks = .none

  public private(set) var verbose: Bool = false
  public func setVerbose(_ value: Bool) { verbose = value }

  public private(set) var metrics: SessionMetrics

  public private(set) var lastDiffs: [String] = []
  public private(set) var lastBuildResult: String?

  public init(adapter: any LLMAdapter, workingDirectory: String) {
    self.adapter = adapter
    self.workingDirectory = workingDirectory
    let embeddingCache = URL(fileURLWithPath: workingDirectory)
      .appendingPathComponent(Config.projectDirName)
      .appendingPathComponent("embedding_cache.json")
    self.embeddingIndex = EmbeddingIndex(cacheURL: embeddingCache)
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
    self.projectAnalyzer = ProjectAnalyzer()
    self.taskResolver = TaskResolver(workingDirectory: workingDirectory)
    self.fileWatcher = FileWatcher(directory: workingDirectory)
    self.lspClient = LSPClient(workingDirectory: workingDirectory)
    self.linter = PostGenerationLinter()
    self.treeSitterRepair = TreeSitterRepair()
    self.errorExtractor = ErrorRegionExtractor()
    self.templateRenderer = TemplateRenderer()
    self.webResearch = WebResearch()
    self.candidateGenerator = CandidateGenerator(
      adapter: adapter,
      shell: SafeShell(workingDirectory: workingDirectory),
      candidateCount: Config.candidateCount,
      temperature: Config.candidateTemperature
    )
    self.signatureIndex = SignatureIndex.builtIn()
    let swiftInterfaceIdx = SwiftInterfaceIndex(
      cacheDirectory: "\(workingDirectory)/\(Config.projectDirName)/api_cache"
    )
    self.apiProvider = TieredAPISurfaceProvider(
      swiftInterfaceIndex: swiftInterfaceIdx,
      lspClient: self.lspClient,
      staticFallback: self.signatureIndex
    )
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
    modeOverride: AgentMode? = nil,
    callbacks: PipelineCallbacks = .none
  ) async throws -> RunResult {
    var memory = WorkingMemory(query: query, workingDirectory: workingDirectory)
    lastDiffs = []
    lastBuildResult = nil
    activeCallbacks = callbacks

    var rsp = TraceEvent.Payload()
    rsp.userPrompt = query
    rsp.notes = "refs=\(referencedFiles.count) override=\(modeOverride.map { $0.rawValue } ?? "nil")"
    await TraceContext.emit(kind: .runStart, stage: "root", payload: rsp)
    let runStartNs = DispatchTime.now().uptimeNanoseconds

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

    // Build or refresh project index + embedding index + reference graph
    if needsReindex || projectIndex.isEmpty {
      let indexer = FileIndexer(workingDirectory: workingDirectory)
      projectIndex = indexer.indexProject(extensions: domain.fileExtensions)
      needsReindex = false
      debug("Indexed \(projectIndex.count) symbols from \(domain.displayName) project")

      // Build reference graph (uses tree-sitter for type usage extraction)
      let symIndex = SymbolIndex(entries: projectIndex)
      let projectFiles = files.listFiles(extensions: domain.fileExtensions)
      referenceGraph = ReferenceGraph.build(
        from: symIndex, projectFiles: projectFiles,
        extractor: TreeSitterExtractor(), fileReader: files
      )
      debug("Reference graph: \(referenceGraph.edgeCount) edges")

      // Build project snapshot for task resolution
      projectSnapshot = projectAnalyzer.analyze(
        index: projectIndex, domain: domain, files: files
      )
      debug("Snapshot: \(projectSnapshot.models.count) models, \(projectSnapshot.views.count) views, \(projectSnapshot.services.count) services")

      // Build embedding index in background (non-blocking)
      let entries = projectIndex
      Task.detached(priority: .utility) { [embeddingIndex] in
        await embeddingIndex.buildIndex(from: entries)
      }

      // Preload SDK API surfaces for frameworks used in the project
      let detectedFrameworks = Set(projectIndex.filter { $0.kind == .import }.map(\.symbolName))
      let provider = apiProvider
      Task.detached(priority: .utility) {
        await provider.preloadFrameworks(detectedFrameworks)
      }
    }

    // Classify
    await TraceContext.emit(kind: .stageStart, stage: "classify")
    let classifyStartNs = DispatchTime.now().uptimeNanoseconds
    let intent = try await classify(query: query, memory: &memory, explicitTargets: referencedFiles)
    let classifyMs = Double(DispatchTime.now().uptimeNanoseconds - classifyStartNs) / 1_000_000.0
    await TraceContext.emitStageEnd("classify", durationMs: classifyMs,
      notes: "mode=\(intent.agentMode.rawValue) domain=\(intent.domain) type=\(intent.taskType) complexity=\(intent.complexity)")
    memory.intent = intent

    // Mode resolution: user override > post-classification check > LLM classification
    if let override = modeOverride, override != .build {
      // User explicitly selected a mode via shift+tab — respect it
      memory.mode = override
      debug("MODE → \(override.rawValue) (user override)")
    } else {
      memory.mode = intent.agentMode

      // @-files provide context to ANY mode — don't force a mode based on their presence.
    }

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

    // Mode dispatch — build modifies files, answer reads + responds
    let dispatchStage = memory.mode == .build ? "build" : "answer"
    await TraceContext.emit(kind: .stageStart, stage: dispatchStage)
    let dispatchStartNs = DispatchTime.now().uptimeNanoseconds
    let result: RunResult
    do {
      switch memory.mode {
      case .build:
        result = try await runBuild(memory: &memory, explicitContext: explicitContext, callbacks: callbacks)
      case .answer:
        result = try await runAnswer(memory: &memory, explicitContext: explicitContext, callbacks: callbacks)
      }
    } catch {
      let ms = Double(DispatchTime.now().uptimeNanoseconds - dispatchStartNs) / 1_000_000.0
      await TraceContext.emitStageEnd(dispatchStage, durationMs: ms, error: error)
      let runMs = Double(DispatchTime.now().uptimeNanoseconds - runStartNs) / 1_000_000.0
      await TraceContext.emitStageEnd("root", durationMs: runMs, error: error)
      throw error
    }
    let dispatchMs = Double(DispatchTime.now().uptimeNanoseconds - dispatchStartNs) / 1_000_000.0
    let summary = "llmCalls=\(memory.llmCalls) tokens=\(memory.totalTokensUsed) succeeded=\(result.reflection.succeeded)"
    await TraceContext.emitStageEnd(dispatchStage, durationMs: dispatchMs, notes: summary)
    let runMs = Double(DispatchTime.now().uptimeNanoseconds - runStartNs) / 1_000_000.0
    await TraceContext.emit(kind: .runEnd, stage: "root", durationMs: runMs,
      payload: { var p = TraceEvent.Payload(); p.notes = summary; return p }())
    return result
  }

  // MARK: - Build Mode (default pipeline)

  private func runBuild(
    memory: inout WorkingMemory,
    explicitContext: String,
    callbacks: PipelineCallbacks
  ) async throws -> RunResult {
    let query = memory.query
    let intent = memory.intent!

    // Task resolution: recipe templates (0 LLM calls) → LLM fallback (1 call)
    let tasks = try await taskResolver.resolve(
      query: query, intent: intent, snapshot: projectSnapshot,
      index: projectIndex, explicitContext: explicitContext, adapter: adapter
    )
    debug("TASKS → \(tasks.count) task(s) via \(tasks.isEmpty ? "none" : "resolver"):")
    for (i, task) in tasks.enumerated() {
      debug("  [\(i + 1)] \(task.action.rawValue): \(task.target)")
    }

    // Multi-file scaffolds: override complexity to prevent early termination
    if tasks.count >= 4, intent.complexity == "simple" {
      memory.intent = AgentIntent(
        domain: intent.domain, taskType: intent.taskType,
        complexity: "complex", mode: intent.mode, targets: intent.targets
      )
      debug("Complexity override: simple → complex (scaffold with \(tasks.count) tasks)")
    }

    // Execute tasks directly (1 LLM call per task)
    var filesWereModified = false
    let totalTasks = tasks.count

    for (index, task) in tasks.enumerated() {
      memory.currentStepIndex = index

      // Progress callback
      await callbacks.onProgress?(index + 1, totalTasks, "\(task.action.rawValue) \(task.target)")

      // Stuck detection: abort when 50%+ of tasks have failed AND at least 3 errors
      let errorCount = memory.observations.filter { $0.outcome == .error }.count
      let totalCount = memory.observations.count
      if errorCount >= 3 && errorCount * 2 >= totalCount {
        debug("GUARDRAIL: stuck — \(errorCount)/\(totalCount) tasks failed, aborting")
        memory.addError("Stuck: \(errorCount) of \(totalCount) tasks failed.")
        break
      }

      if ProcessInfo.processInfo.environment["JUNCO_ORCH_TRACE"] == "1" {
        FileHandle.standardError.write(Data("[ORCH-runBuild] task \(index + 1)/\(tasks.count) start: \(task.action.rawValue) \(task.target)\n".utf8))
      }
      let obStartT = Date()
      let observation = await executeConcreteTask(task: task, memory: &memory)
      memory.addObservation(observation)
      if task.action == .create || task.action == .edit {
        filesWereModified = true
      }
      if ProcessInfo.processInfo.environment["JUNCO_ORCH_TRACE"] == "1" {
        FileHandle.standardError.write(Data("[ORCH-runBuild] task \(index + 1) done in \(String(format: "%.1f", Date().timeIntervalSince(obStartT)))s outcome=\(observation.outcome.rawValue)\n".utf8))
      }
      debug("TASK[\(index + 1)] → [\(observation.outcome.rawValue)] \(observation.tool): \(observation.keyFact)")

      // Early termination on simple create success (check memory.intent, not stale local)
      if memory.intent?.complexity == "simple" && index == 0 && tasks.count > 1 {
        if observation.outcome == .ok && task.action == .create {
          debug("EARLY EXIT: simple create succeeded on task 1")
          break
        }
      }
    }

    // Also support legacy PlanStep path for LLM-generated plans
    // (used when TaskResolver falls back to LLM decomposition that produces PlanSteps)
    if tasks.isEmpty {
      // Fallback to old plan path
      let plan = try await plan(
      query: query, intent: intent,
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
    let totalSteps = cappedSteps.count

    for (index, step) in cappedSteps.enumerated() {
      memory.currentStepIndex = index

      // Progress callback
      await callbacks.onProgress?(index + 1, totalSteps, step.instruction)

      // Guardrails — deterministic checks between steps (inspired by SWE-Agent)

      // Loop detection: same tool+target repeated
      if lastActions.count >= 2 {
        let prev = lastActions.suffix(2)
        let stepTool = step.tool
        if prev.allSatisfy({ $0.tool == stepTool && $0.target == step.target }) {
          debug("GUARDRAIL: loop detected at step \(index + 1) — breaking")
          memory.addError("Loop detected: repeated \(stepTool) on \(step.target)")
          break
        }
      }

      // Stuck detection: abort when 50%+ of steps have failed AND at least 3 errors
      let stepErrorCount = memory.observations.filter { $0.outcome == .error }.count
      let stepTotalCount = memory.observations.count
      if stepErrorCount >= 3 && stepErrorCount * 2 >= stepTotalCount {
        debug("GUARDRAIL: stuck — \(stepErrorCount)/\(stepTotalCount) steps failed, aborting")
        memory.addError("Stuck: \(stepErrorCount) of \(stepTotalCount) steps failed. Try a different approach.")
        break
      }

      // Scope check: simple task with too many steps
      if memory.intent?.complexity == "simple" && index >= 3 {
        debug("GUARDRAIL: simple task exceeded 3 steps, stopping")
        break
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
    } // end if tasks.isEmpty (legacy plan fallback)

    // Build verification + LSP diagnostics after modifications
    // Only verify if modified files match the project's domain extensions
    let domainExtensions = Set(domain.fileExtensions)
    let modifiedDomainFiles = memory.touchedFiles.filter { path in
      let ext = (path as NSString).pathExtension.lowercased()
      return domainExtensions.contains(ext)
    }

    let skipBuildVerify = ProcessInfo.processInfo.environment["JUNCO_SKIP_BUILD_FIX"] == "1"
    if filesWereModified && !modifiedDomainFiles.isEmpty && !skipBuildVerify {
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

    let postStartT = Date()
    func postTrace(_ m: String) {
      if ProcessInfo.processInfo.environment["JUNCO_ORCH_TRACE"] == "1" {
        FileHandle.standardError.write(Data("[ORCH-post] \(m) (+\(String(format: "%.2f", Date().timeIntervalSince(postStartT)))s)\n".utf8))
      }
    }
    postTrace("buildAndFix")
    // Build-fix reflexion loop: attempt to fix build errors before reflecting
    await buildAndFix(memory: &memory)
    postTrace("buildAndFix done")

    // Persist type manifest to scratchpad for cross-turn coherence
    if memory.touchedFiles.count > 1 {
      let manifest = projectSnapshot.typeSignatureBlock(budget: 200)
      if !manifest.isEmpty {
        scratchpad.write(key: "generated_types", value: manifest)
      }
    }
    postTrace("scratchpad done")

    let reflection = reflect(memory: memory)
    debug("REFLECT → succeeded:\(reflection.succeeded) insight:\(reflection.insight)")
    postTrace("reflect done")

    try? reflectionStore.save(query: query, reflection: reflection)
    postTrace("reflectionStore.save done")

    metrics.tasksCompleted += 1
    metrics.totalTokensUsed += memory.totalTokensUsed
    metrics.totalLLMCalls += memory.llmCalls

    return RunResult(memory: memory, reflection: reflection)
  }

  // MARK: - Answer Mode (unified: search, plan, research, explain)

  /// Unified answer pipeline — routes to search, plan, or research sub-paths.
  /// Replaces the former separate search/plan/research modes.
  private func runAnswer(
    memory: inout WorkingMemory,
    explicitContext: String,
    callbacks: PipelineCallbacks
  ) async throws -> RunResult {
    let query = memory.query
    let intent = memory.intent

    // Sub-type dispatch based on intent + query analysis

    // 1. Explain/explore shortcut with @-files (streaming)
    if let intent, (intent.taskType == "explain" || intent.taskType == "explore") && !explicitContext.isEmpty {
      debug("ANSWER: explain/explore with @-referenced files")
      let explainPrompt = "Task: \(query)\n\nContent:\n\(TokenBudget.truncate(explicitContext, toTokens: 2500))"
      let systemPrompt = "You are a coding assistant. Explain the provided code or documentation clearly and concisely. \(domain.promptHint)"
      memory.trackCall(estimatedTokens: TokenBudget.execute.total)

      let response: String
      if let onStream = callbacks.onStream {
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

    // 2. Plan-related queries
    let lower = query.lowercased()
    let isPlanQuery = lower.hasPrefix("plan ") || lower.hasPrefix("outline ") ||
      lower.hasPrefix("design ") || lower.hasPrefix("architect ") ||
      lower.hasPrefix("scope ") || lower.hasPrefix("break down ") ||
      lower.contains("what would it take") || lower.contains("what steps")
    if isPlanQuery {
      return try await runPlan(memory: &memory, explicitContext: explicitContext, callbacks: callbacks)
    }

    // 3. Research queries (external APIs, docs, no local symbols found)
    let (identifiers, _) = Self.extractSearchTerms(query)
    let hasLocalSymbols = identifiers.contains { term in
      projectIndex.contains { $0.symbolName.caseInsensitiveCompare(term) == .orderedSame }
    }
    let isExternalQuery = !hasLocalSymbols && (
      lower.contains("documentation") || lower.contains("apple docs") ||
      lower.hasPrefix("research ") || lower.contains("how does") && !hasLocalSymbols ||
      lower.contains("what's new in")
    )
    if isExternalQuery && explicitContext.isEmpty {
      return try await runResearch(memory: &memory, explicitContext: explicitContext, callbacks: callbacks)
    }

    // 4. Default: deterministic search (most common answer sub-type)
    return try await runSearch(memory: &memory, explicitContext: explicitContext, callbacks: callbacks)
  }

  // MARK: - Search (internal)

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

  // MARK: - Search Term Extraction

  /// Extract search terms from a natural language query.
  /// Returns (identifiers, keywords) — identifiers are CamelCase/@ symbols,
  /// keywords are remaining significant words.
  /// Uses NLTK stop word list (loaded from Resources/stopwords.txt).
  private static func extractSearchTerms(_ query: String) -> (identifiers: [String], keywords: [String]) {
    let words = query.components(separatedBy: CharacterSet.alphanumerics.union(.init(charactersIn: "@_")).inverted)
      .filter { !$0.isEmpty }

    var identifiers: [String] = []
    var keywords: [String] = []

    for word in words {
      if StopWords.contains(word) { continue }

      // CamelCase or @-prefixed → code identifier (highest value)
      if word.first?.isUppercase == true || word.hasPrefix("@") {
        identifiers.append(word)
      } else if word.count >= 3 {
        keywords.append(word)
      }
    }

    return (identifiers, keywords)
  }

  /// Detect if a query is asking for a count. Returns true for "how many X" style queries.
  private static func isCountQuery(_ query: String) -> Bool {
    let lower = query.lowercased()
    // Look for quantity question patterns — not phrase matching on the full query,
    // just checking if quantity words co-occur with question structure.
    let hasQuantityWord = ["many", "count", "number", "total"].contains(where: { lower.contains($0) })
    let hasQuestionWord = ["how", "what"].contains(where: { lower.hasPrefix($0) })
    return hasQuantityWord && hasQuestionWord
  }

  /// Detect if a query is interpretive (needs LLM summary) vs locational (results speak for themselves).
  private static func isInterpretiveQuery(_ query: String) -> Bool {
    let lower = query.lowercased()
    return lower.hasPrefix("how do") || lower.hasPrefix("how does") ||
           lower.hasPrefix("how are") || lower.hasPrefix("why") ||
           lower.hasPrefix("explain")
  }

  private func runSearch(
    memory: inout WorkingMemory,
    explicitContext: String,
    callbacks: PipelineCallbacks
  ) async throws -> RunResult {
    let query = memory.query
    debug("SEARCH MODE → \(query)")

    // === FULLY DETERMINISTIC SEARCH — NO LLM FOR QUERY EXPANSION ===
    // The user's actual words are the best search terms.
    // LLM query expansion is unreliable with a 3B model.

    // Step 1: Extract search terms from the query (deterministic, instant)
    let (identifiers, keywords) = Self.extractSearchTerms(query)
    let allTerms = identifiers + keywords
    debug("SEARCH terms: identifiers=\(identifiers) keywords=\(keywords)")

    // Step 1a: Handle counting queries deterministically
    if Self.isCountQuery(query) {
      let countResult = await executeCountQuery(query: query, terms: allTerms)
      if !countResult.isEmpty {
        let reflection = AgentReflection(
          taskSummary: "Search: \(query)",
          insight: countResult,
          improvement: "", succeeded: true
        )
        metrics.tasksCompleted += 1
        return RunResult(memory: memory, reflection: reflection)
      }
    }

    // Step 2: Multi-signal search (deterministic, 0 LLM calls)
    var hits: [SearchHit] = []

    // 2a: Symbol index — exact name matches (highest precision)
    for entry in projectIndex where !entry.filePath.hasPrefix("Sources/JuncoEval") {
      for term in identifiers {
        if entry.symbolName.caseInsensitiveCompare(term) == .orderedSame {
          // Exact symbol name match
          let declBoost: Double = entry.kind == .type || entry.kind == .function ? 3.0 : 0
          hits.append(SearchHit(
            file: entry.filePath, line: entry.lineNumber,
            snippet: entry.snippet, source: "index", score: 10.0 + declBoost
          ))
        } else if entry.symbolName.lowercased().contains(term.lowercased()) {
          hits.append(SearchHit(
            file: entry.filePath, line: entry.lineNumber,
            snippet: entry.snippet, source: "index", score: 5.0
          ))
        }
      }
    }

    // 2b: grep/rg — search for identifiers and significant keywords
    // Identifiers get searched individually (precise).
    // Keywords get searched only if they're 5+ chars (avoid noise from "test", "run", "main").
    let grepTerms = identifiers + keywords.filter { $0.count >= 5 }
    for term in Set(grepTerms).prefix(6) {
      let escaped = shellEscape(term)
      let cmd: String
      if Self.hasRg() {
        cmd = "rg --type swift -n --glob '!Sources/JuncoEval/**' \(escaped) Sources/ Tests/ Package.swift 2>/dev/null | head -10"
      } else {
        cmd = "grep -rn \(escaped) Sources/JuncoKit/ Tests/ Package.swift --include='*.swift' 2>/dev/null | head -10"
      }
      if let result = try? await shell.execute(cmd), result.exitCode == 0 {
        for line in result.stdout.components(separatedBy: "\n") where !line.isEmpty {
          if let hit = parseGrepLine(line, term: term) {
            hits.append(hit)
          }
        }
      }
    }

    // 2c: LSP workspace/symbol (if available, for identifiers only)
    if lspStarted {
      for term in identifiers.prefix(3) {
        let symbols = await lspClient.workspaceSymbol(query: term)
        for sym in symbols {
          hits.append(SearchHit(
            file: sym.file, line: sym.line,
            snippet: "\(sym.kind) \(sym.name)",
            source: "lsp", score: 8.0
          ))
        }
      }
    }

    // 2d: Embedding fallback — concept queries that keyword search missed.
    // "entry point" matches "CLI entry point" in Junco.swift's comment via NLEmbedding.
    var hasGoodHits = hits.contains { $0.score >= 5.0 }
    if !hasGoodHits {
      let embeddingHits = await embeddingIndex.score(query: query, topK: 5)
      for (idx, similarity) in embeddingHits where similarity > 0.4 && idx < projectIndex.count {
        let entry = projectIndex[idx]
        hits.append(SearchHit(
          file: entry.filePath, line: entry.lineNumber,
          snippet: entry.snippet, source: "embedding",
          score: similarity * 8.0
        ))
      }
      hasGoodHits = hits.contains { $0.score >= 3.0 }
      if hasGoodHits {
        debug("SEARCH embedding fallback found \(embeddingHits.count) hits")
      }
    }

    // 2e: LLM term expansion fallback — only when BOTH keyword AND embedding search failed.
    if !hasGoodHits && !allTerms.isEmpty {
      debug("SEARCH fallback: no hits from keyword or embedding, trying LLM term expansion")
      let fileList = files.listFiles().prefix(20).joined(separator: "\n")
      memory.trackCall(estimatedTokens: 600)
      if let expanded = try? await adapter.generateStructured(
        prompt: Prompts.searchQueryPrompt(query: query, fileHints: fileList),
        system: Prompts.searchQuerySystem,
        as: SearchQueries.self,
        options: GenerationProfile.queryExpansion().options()
      ) {
        debug("SEARCH LLM terms: \(expanded.queries)")
        for term in expanded.queries.prefix(5) {
          let escaped = shellEscape(term)
          let cmd = Self.hasRg()
            ? "rg --type swift -n --glob '!Sources/JuncoEval/**' \(escaped) Sources/ Tests/ Package.swift 2>/dev/null | head -8"
            : "grep -rn \(escaped) Sources/JuncoKit/ Tests/ Package.swift --include='*.swift' 2>/dev/null | head -8"
          if let result = try? await shell.execute(cmd), result.exitCode == 0 {
            for line in result.stdout.components(separatedBy: "\n") where !line.isEmpty {
              if let hit = parseGrepLine(line, term: term) {
                hits.append(hit)
              }
            }
          }
        }
      }
    }

    // Step 3: Score boosting (deterministic)

    // 3a: Declaration boost — lines containing declaration keywords score higher
    hits = hits.map { hit in
      let trimmed = hit.snippet.trimmingCharacters(in: .whitespaces)
      let declPatterns = ["enum ", "struct ", "class ", "func ", "protocol ", "actor "]
      if declPatterns.contains(where: { trimmed.hasPrefix($0) || trimmed.contains("public \($0)") || trimmed.contains("private \($0)") }) {
        return SearchHit(file: hit.file, line: hit.line, snippet: hit.snippet, source: hit.source, score: hit.score + 3.0)
      }
      return hit
    }

    // 3b: Multi-term intersection boost — hits in files that match multiple query terms
    let fileTermCounts = Dictionary(grouping: hits, by: \.file)
      .mapValues { fileHits in Set(fileHits.map { $0.snippet.lowercased() }).count }
    hits = hits.map { hit in
      let extraTerms = fileTermCounts[hit.file, default: 1] - 1
      if extraTerms > 0 {
        return SearchHit(file: hit.file, line: hit.line, snippet: hit.snippet, source: hit.source, score: hit.score + Double(extraTerms) * 2.0)
      }
      return hit
    }

    // Step 3c: Reference graph boost — files related to top hits score higher
    if referenceGraph.edgeCount > 0 {
      let preliminaryRanked = hits.sorted { $0.score > $1.score }
      let topFiles = Set(preliminaryRanked.prefix(3).map(\.file))
      let neighborhood = referenceGraph.neighborhood(of: topFiles)
      hits = hits.map { hit in
        if neighborhood.contains(hit.file) && !topFiles.contains(hit.file) {
          return SearchHit(file: hit.file, line: hit.line, snippet: hit.snippet,
                           source: hit.source, score: hit.score + 2.0)
        }
        return hit
      }
    }

    // Step 4: Rank, deduplicate, format
    let ranked = rankAndDeduplicate(hits)
    debug("SEARCH → \(ranked.count) hits from \(Set(hits.map(\.source)).sorted())")

    if ranked.isEmpty {
      // Fallback: read well-known files
      var fallback = "No code matches found. Project files:\n"
      for file in Self.wellKnownFiles(for: domain) {
        if files.exists(file) { fallback += "  \(file)\n" }
      }
      let reflection = AgentReflection(
        taskSummary: "Search: \(query)",
        insight: fallback,
        improvement: "", succeeded: false
      )
      metrics.tasksCompleted += 1
      return RunResult(memory: memory, reflection: reflection)
    }

    // Step 5: Format answer deterministically — results ARE the answer
    var insight = formatSearchResults(ranked.prefix(8), query: query)

    // Step 6: Optional one-sentence LLM summary for interpretive queries only
    // "Where is X?" → no summary needed (results are self-explanatory)
    // "How do tests run?" → brief summary helps connect the dots
    if Self.isInterpretiveQuery(query) && ranked.count > 1 {
      let summaryHits = ranked.prefix(3).map {
        "\($0.file):\($0.line) \($0.snippet.prefix(60))"
      }.joined(separator: "\n")
      memory.trackCall(estimatedTokens: 300)
      let summary = try await adapter.generate(
        prompt: "Q: \(query)\nResults:\n\(summaryHits)\nAnswer in one sentence.",
        system: Prompts.searchSynthesizeSystem
      )
      insight = summary + "\n\n" + insight
    }

    let reflection = AgentReflection(
      taskSummary: "Search: \(query)",
      insight: insight,
      improvement: "", succeeded: true
    )
    metrics.tasksCompleted += 1
    metrics.totalTokensUsed += memory.totalTokensUsed
    metrics.totalLLMCalls += memory.llmCalls
    return RunResult(memory: memory, reflection: reflection)
  }

  /// Execute a counting query deterministically via shell commands.
  private func executeCountQuery(query: String, terms: [String]) async -> String {
    let lower = query.lowercased()

    if lower.contains("file") {
      // Count Swift source files
      let cmd = "find Sources Tests -name '*.swift' 2>/dev/null | wc -l"
      if let result = try? await shell.execute(cmd), result.exitCode == 0 {
        let count = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return "There are \(count) Swift source files in Sources/ and Tests/."
      }
    }

    if lower.contains("test") {
      let cmd = "grep -r '@Test' Tests/ --include='*.swift' 2>/dev/null | wc -l"
      if let result = try? await shell.execute(cmd), result.exitCode == 0 {
        let count = result.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
        return "There are \(count) test cases (marked with @Test) in Tests/."
      }
    }

    if lower.contains("function") || lower.contains("method") {
      let funcCount = projectIndex.filter { $0.kind == .function }.count
      return "There are \(funcCount) functions/methods in the project index."
    }

    if lower.contains("type") || lower.contains("struct") || lower.contains("class") {
      let typeCount = projectIndex.filter { $0.kind == .type }.count
      return "There are \(typeCount) types (structs, classes, enums, actors, protocols) in the project index."
    }

    return ""  // Not a recognized counting query
  }

  /// Format search results deterministically — the answer IS the results.
  private func formatSearchResults(_ hits: some Collection<SearchHit>, query: String) -> String {
    var output = "Found in \(hits.count) location(s):\n"

    for hit in hits {
      output += "\n  \(hit.file)"
      if hit.line > 0 { output += ":\(hit.line)" }
      output += "\n"

      // Show relevant snippet lines (up to 4)
      let snippetLines = hit.snippet.components(separatedBy: "\n")
        .map { $0.trimmingCharacters(in: .init(charactersIn: "\r")) }
        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
      for line in snippetLines.prefix(4) {
        output += "    \(line)\n"
      }
    }

    return output
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

  /// Well-known project files that often contain structural information.
  private static func wellKnownFiles(for domain: DomainConfig) -> [String] {
    var files = ["Package.swift", "README.md"]
    if domain.kind == .swift {
      files += ["Sources", "Tests"]
    }
    return files
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

    // Always include project structure for grounding
    let fileList = files.listFiles()
    context += "Project files (\(fileList.count)):\n" +
      fileList.prefix(30).joined(separator: "\n") + "\n\n"

    if explicitContext.isEmpty {
      // Read key project files for context
      for file in ["Package.swift"] {
        if files.exists(file), let content = try? files.read(path: file, maxTokens: 400) {
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
      prompt: planPrompt, system: Prompts.planModeSystem, as: StructuredPlan.self,
      options: GenerationProfile.planning().options()
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
      as: ResearchQueries.self,
      options: GenerationProfile.queryExpansion().options()
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

    // Truncate research context to fit within context window
    // Reserve: system prompt (~100) + schema overhead (~150) + generation (~800) + safety (~200)
    let maxResearchTokens = await adapter.contextSize - 1250
    researchContext = TokenBudget.truncateSmart(researchContext, toTokens: maxResearchTokens)

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
      as: AgentResponse.self,
      options: GenerationProfile.synthesis(maxTokens: 800).options()
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
      "tell me about junco"
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
    "add": "add", "create": "add", "implement": "add", "write": "add", "build": "add",
    "refactor": "refactor", "clean": "refactor", "simplify": "refactor",
    "test": "test",
    "find": "explore", "search": "explore", "grep": "explore",
    "where": "explore", "list": "explore", "show": "explore",
    // Plan/review verbs → deterministic answer mode. Without these, "Plan a refactor"
    // hits the LLM classify tier and frequently mis-routes to build. (soft-classify-guard)
    "plan": "plan", "design": "plan", "outline": "plan",
    "review": "explain", "audit": "explain",
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
    "setsumei": "explain", "naoshite": "fix"
  ]

  /// First words that unambiguously imply build mode (file-modifying action).
  private static let buildModeKeywords: Set<String> = [
    "create", "add", "fix", "edit", "implement", "write", "build",
    "refactor", "test", "delete", "remove", "rename", "update",
    // Spanish
    "crea", "arregla", "corrige", "añade", "agrega",
    // French
    "ajoute", "crée", "répare",
    // German
    "erstelle", "füge", "behebe"
  ]

  /// Task types that imply build mode (post-classification guard).
  private static let buildTaskTypes: Set<String> = [
    "add", "fix", "refactor", "test"
  ]

  /// First words that unambiguously imply answer mode (plan/show/explain questions).
  /// When the first word is in this set, the `buildTaskTypes` post-classification guard
  /// is SKIPPED — prevents "Plan a refactor …" from flipping to build.
  /// Validated by meta-harness candidate `soft-classify-guard`: plan-refactor 0→100%.
  private static let answerModeFirstWords: Set<String> = [
    "plan", "show", "explain", "find", "search", "how", "what", "where",
    "why", "list", "describe", "summarize", "tell", "review"
  ]

  /// Classify the agent mode. Tries ML classifier first, falls back to LLM.
  private func classifyMode(query: String, memory: inout WorkingMemory) async -> AgentMode {
    let embResult = intentClassifier.classifyModeByEmbedding(query)
    if let embMode = embResult, embMode.confidence > 0.85 {
      debug("Embedding mode classifier: \(embMode.mode) (similarity: \(String(format: "%.2f", embMode.confidence)))")
      await TraceContext.emitDecision(stage: "classify", name: "modeClassifier.embedding",
        observedValue: embMode.confidence, effectiveThreshold: 0.85,
        pathTaken: "embedding", notes: "mode=\(embMode.mode)")
      return AgentMode(rawValue: embMode.mode.lowercased()) ?? .build
    }
    let mlResult = intentClassifier.classifyMode(query)
    if let mlMode = mlResult, mlMode.confidence > Config.mlClassifierConfidence {
      debug("ML mode classifier: \(mlMode.mode) (confidence: \(String(format: "%.2f", mlMode.confidence)))")
      let rejected = embResult.map { ["embedding(\(String(format: "%.2f", $0.confidence)))"] } ?? ["embedding(none)"]
      await TraceContext.emitDecision(stage: "classify", name: "modeClassifier.ml",
        observedValue: mlMode.confidence, effectiveThreshold: Config.mlClassifierConfidence,
        pathTaken: "ml", alternativesRejected: rejected, notes: "mode=\(mlMode.mode)")
      return AgentMode(rawValue: mlMode.mode.lowercased()) ?? .build
    }
    let embDesc = embResult.map { "embedding(\(String(format: "%.2f", $0.confidence)))" } ?? "embedding(none)"
    let mlDesc = mlResult.map { "ml(\(String(format: "%.2f", $0.confidence)))" } ?? "ml(none)"
    await TraceContext.emitDecision(stage: "classify", name: "modeClassifier.llm",
      pathTaken: "llmFallback", alternativesRejected: [embDesc, mlDesc])
    memory.trackCall(estimatedTokens: 200)
    do {
      let result = try await adapter.generateStructured(
        prompt: query,
        system: Prompts.modeClassifySystem,
        as: ModeClassification.self,
        options: GenerationProfile.classifier(maxTokens: 50).options()
      )
      return AgentMode(rawValue: result.mode.lowercased()) ?? .build
    } catch {
      debug("Mode classification failed, defaulting to build: \(error)")
      return .build
    }
  }

  /// Resolve target files from the query using basename, full-path, and regex matching.
  private func resolveTargets(query: String, explicitTargets: [String]) -> [String] {
    if !explicitTargets.isEmpty { return explicitTargets }
    let fileList = files.listFiles()
    // 1. Basename matching (existing files whose name appears in query)
    var matched = fileList.filter { path in
      query.lowercased().contains((path as NSString).lastPathComponent.lowercased())
    }
    // 2. Full-path matching (e.g. "Sources/PodcastApp/Models.swift")
    for file in fileList where query.contains(file) && !matched.contains(file) {
      matched.append(file)
    }
    // 3. Regex for .swift paths mentioned in query (may be new files to create)
    if let regex = try? NSRegularExpression(pattern: #"(?:Sources|Tests)/[\w/]+\.swift"#) {
      let range = NSRange(query.startIndex..., in: query)
      for match in regex.matches(in: query, range: range) {
        if let r = Range(match.range, in: query) {
          let path = String(query[r])
          if !matched.contains(path) { matched.append(path) }
        }
      }
    }
    return matched.isEmpty ? Array(fileList.prefix(3)) : matched
  }

  private func classify(
    query: String, memory: inout WorkingMemory, explicitTargets: [String] = []
  ) async throws -> AgentIntent {
    let firstWord = query.lowercased().split(separator: " ").first.map(String.init) ?? ""
    let keywordOverride = Self.intentKeywords[firstWord]

    // Tier 1: ML classifier with high confidence
    if let mlResult = intentClassifier.classifyWithConfidence(query), mlResult.confidence > Config.mlClassifierConfidence {
      let finalLabel = keywordOverride ?? mlResult.label
      if keywordOverride != nil && keywordOverride != mlResult.label {
        debug("ML classifier: \(mlResult.label) → overridden to \(finalLabel) (keyword: \(firstWord))")
      } else {
        debug("ML classifier: \(finalLabel) (confidence: \(String(format: "%.2f", mlResult.confidence)))")
      }
      metrics.mlClassifications += 1

      let targets = resolveTargets(query: query, explicitTargets: explicitTargets)

      // Determine mode: keyword short-circuit for unambiguous build verbs
      let detectedMode: AgentMode
      if Self.buildModeKeywords.contains(firstWord) {
        detectedMode = .build
        debug("Mode: build (keyword override: \(firstWord))")
      } else {
        detectedMode = await classifyMode(query: query, memory: &memory)
        debug("Mode classification: \(detectedMode.rawValue)")
      }

      // Post-classification guard: build-type task + answer mode → likely misclassification,
      // UNLESS the query starts with an answer-mode verb (plan/show/explain/…), in which case
      // we keep the detected answer mode. Prevents "Plan a refactor …" from flipping to build.
      let finalMode: AgentMode
      if Self.buildTaskTypes.contains(finalLabel) && detectedMode == .answer
         && !Self.answerModeFirstWords.contains(firstWord) {
        finalMode = .build
        debug("Mode override: answer → build (taskType \(finalLabel) implies build)")
      } else {
        finalMode = detectedMode
      }

      return AgentIntent(
        domain: domain.kind.rawValue, taskType: finalLabel,
        complexity: targets.count > 2 ? "moderate" : "simple",
        mode: finalMode.rawValue, targets: targets
      )
    }

    // Tier 2: Deterministic construction when keyword provides taskType
    // Saves ~800 tokens + 1.5s latency by avoiding the LLM classify call.
    if let taskType = keywordOverride {
      let mode: AgentMode = Self.buildTaskTypes.contains(taskType) ? .build : .answer
      let targets = resolveTargets(query: query, explicitTargets: explicitTargets)

      debug("Deterministic classify: \(taskType)/\(mode.rawValue) (keyword: \(firstWord))")
      metrics.deterministicClassifications += 1

      return AgentIntent(
        domain: domain.kind.rawValue, taskType: taskType,
        complexity: targets.count > 2 ? "moderate" : "simple",
        mode: mode.rawValue, targets: targets
      )
    }

    // Tier 3: Full LLM fallback for genuinely ambiguous queries
    debug("ML classifier: low confidence, no keyword match — falling back to LLM")

    let fileList = files.listFiles().prefix(25).joined(separator: "\n")
    let prompt = Prompts.classifyPrompt(
      query: query, fileHints: TokenBudget.truncate(fileList, toTokens: 150)
    )
    memory.trackCall(estimatedTokens: TokenBudget.classify.total)
    var intent = try await adapter.generateStructured(
      prompt: prompt, system: Prompts.classifySystem, as: AgentIntent.self,
      options: GenerationProfile.classifier(maxTokens: 300).options()
    )

    // Post-classification guards for LLM fallback — same answer-mode-verb exemption.
    if Self.buildTaskTypes.contains(intent.taskType) && intent.agentMode == .answer
       && !Self.answerModeFirstWords.contains(firstWord) {
      intent = AgentIntent(
        domain: intent.domain, taskType: intent.taskType,
        complexity: intent.complexity, mode: "build", targets: intent.targets
      )
      debug("Mode override: answer → build (taskType \(intent.taskType) implies build)")
    }

    return intent
  }

  private func plan(
    query: String, intent: AgentIntent,
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
        budget: TokenBudget.plan.context, preferredFiles: intent.targets
      )
    }
    let prompt = Prompts.planPrompt(
      query: query, intent: intent, fileContext: fileContext
    )
    memory.trackCall(estimatedTokens: TokenBudget.plan.total)
    return try await adapter.generateStructured(
      prompt: prompt, system: Prompts.planSystem, as: AgentPlan.self,
      options: GenerationProfile.planning().options()
    )
  }

  // MARK: - ConcreteTask Execution

  /// Execute a ConcreteTask — 1 LLM call per task with rich specification.
  private func executeConcreteTask(
    task: ConcreteTask, memory: inout WorkingMemory
  ) async -> StepObservation {
    switch task.action {
    case .create:
      return await executeCreateTask(task: task, memory: &memory)
    case .edit:
      return await executeEditTask(task: task, memory: &memory)
    case .bash:
      do {
        let result = try await shell.execute(task.specification)
        return StepObservation(
          tool: "bash", outcome: result.exitCode == 0 ? .ok : .error,
          keyFact: String(result.formatted(maxTokens: 120).prefix(120))
        )
      } catch {
        return StepObservation(tool: "bash", outcome: .error, keyFact: "\(error)")
      }
    case .explain:
      // Explain tasks return content via the reflection insight, not file operations
      return StepObservation(tool: "explain", outcome: .ok, keyFact: "Explanation generated")
    }
  }

  /// Execute a create task: generate file content with rich specification.
  private func executeCreateTask(
    task: ConcreteTask, memory: inout WorkingMemory
  ) async -> StepObservation {
    let target = task.target
    guard !target.isEmpty else {
      return StepObservation(tool: "create", outcome: .error, keyFact: "Empty target path")
    }

    // Check if file already exists — allow overwrite if it was touched in this session
    if files.exists(target) {
      if !memory.touchedFiles.contains(target) {
        return StepObservation(tool: "create", outcome: .error,
                               keyFact: "File already exists: \(target). Use edit to modify.")
      }
      debug("Overwriting \(target) from prior attempt in this session")
    }

    do {
      var content: String = ""

      // Route 0: Pre-rendered content (deterministic scaffold output).
      // If the specification IS the content (starts with import/@ — not a prompt), write directly.
      var usedTemplate = false
      let specTrimmed = task.specification.trimmingCharacters(in: .whitespacesAndNewlines)
      if specTrimmed.hasPrefix("import ") || specTrimmed.hasPrefix("@main") || specTrimmed.hasPrefix("// swift-tools") {
        debug("Pre-rendered content for \(target)")
        content = task.specification
        usedTemplate = true
      }

      // Route 1: Template (services, viewmodels, views, etc.)
      // On failure, retry template with stripped prompt before falling back to plain generation.
      if !usedTemplate && templateRenderer.shouldUseTemplate(filePath: target) {
        do {
          if let rendered = try await templateRenderer.resolveTemplate(
               filePath: target, prompt: task.specification, adapter: adapter,
               snapshot: projectSnapshot) {
            debug("Template route for \(target)")
            content = rendered
            usedTemplate = true
          }
        } catch {
          debug("Template failed for \(target): \(error)")
          // Retry with stripped prompt (avoids context overflow on retry)
          do {
            let strippedPrompt = "Create \(target). \(TokenBudget.truncate(memory.query, toTokens: 100))"
            if let retried = try await templateRenderer.resolveTemplate(
                 filePath: target, prompt: strippedPrompt, adapter: adapter,
                 snapshot: projectSnapshot) {
              debug("Template retry succeeded for \(target)")
              content = retried
              usedTemplate = true
            }
          } catch {
            debug("Template retry also failed for \(target): \(error) — falling through to Route 2")
            // usedTemplate remains false → Route 2 will handle it
          }
        }
      }
      // Route 2: Code generation
      if !usedTemplate {
        // Determine if two-phase is appropriate for this file.
        // Two-phase works well for complex files (views, viewmodels, services) but
        // produces near-empty skeletons for simple models/configs. Only use it for
        // complex roles or when the prompt is too large for single-pass.
        let fileRole = target.hasSuffix(".swift") ? MicroSkill.inferFileRole(target) : ""
        let usesTwoPhase = Config.twoPhaseDefault
          && target.hasSuffix(".swift")
          && ["view", "viewmodel", "service"].contains(fileRole)

        let system0 = Prompts.createSystem(domain: domain)
        if usesTwoPhase {
          debug("Two-phase generation for \(target) (role: \(fileRole))")
          let step = PlanStep(instruction: task.specification, tool: "create", target: target)
          content = try await generateTwoPhase(step: step, memory: &memory)
        } else if target.hasSuffix(".swift"),
                  await TokenGuard.willOverflow(system: system0, prompt: task.specification, adapter: adapter) {
          // Pre-flight overflow check: skip straight to two-phase if prompt is large
          debug("Pre-flight: prompt too large for single-pass — using two-phase for \(target)")
          let step = PlanStep(instruction: task.specification, tool: "create", target: target)
          content = try await generateTwoPhase(step: step, memory: &memory)
        } else {
          // Single-pass generation (default for models, configs, non-Swift, simple files)
          do {
            var system = system0
            if let taskDomain = task.domain {
              let cap = taskDomain.prefix(1).uppercased() + taskDomain.dropFirst()
              system += " Use domain-specific names: \(cap), \(cap)Service, \(cap)ViewModel — never generic names like Item or MyApp."
            }
            if target.hasSuffix(".swift") {
              if let hint = skillLoader.skillHints(
                domain: memory.intent?.domain ?? "swift",
                taskType: memory.intent?.taskType ?? "add",
                fileRole: fileRole, budget: 200) {
                system += " " + hint
              }
            }
            memory.trackCall(estimatedTokens: TokenBudget.execute.total)
            content = try await adapter.generate(prompt: task.specification, system: system)
            content = linter.cleanPlainTextOutput(content, filePath: target)
            // Strip type declarations that duplicate existing project types
            let existingNames = Set(
              (projectSnapshot.models + projectSnapshot.services + projectSnapshot.views).map(\.name)
            )
            content = linter.removeDuplicateTypes(content, existingTypeNames: existingNames)
          } catch let error as LLMError {
            if case .contextOverflow = error, target.hasSuffix(".swift") {
              debug("Context overflow on create — falling back to two-phase generation")
              let step = PlanStep(instruction: task.specification, tool: "create", target: target)
              content = try await generateTwoPhase(step: step, memory: &memory)
            } else {
              throw error
            }
          }
        }
      }

      let stepTrace = ProcessInfo.processInfo.environment["JUNCO_ORCH_TRACE"] == "1"
      func trace(_ m: String) {
        if stepTrace { FileHandle.standardError.write(Data("[ORCH-create] \(m)\n".utf8)) }
      }
      trace("start TreeSitterRepair")
      // TreeSitterRepair: deterministic structural fixes before compiler check
      if target.hasSuffix(".swift") && !content.isEmpty {
        let (repaired, repairFixes) = treeSitterRepair.repair(content)
        if !repairFixes.isEmpty {
          debug("TreeSitterRepair: \(repairFixes.joined(separator: ", "))")
          content = repaired
        }
      }
      trace("TreeSitterRepair done")

      // CVF + validation: skip Package.swift (PackageDescription unavailable to plain swiftc)
      let isManifest = target.lowercased().hasSuffix("package.swift")
      if target.hasSuffix(".swift") && !content.isEmpty && !isManifest {
        let fileName = (target as NSString).lastPathComponent.lowercased()
        let isViewFile = fileName.contains("view") || fileName.contains("screen")
        let cycles = isViewFile ? Config.maxCVFCyclesView : 2
        trace("compileVerifyFix cycles=\(cycles)")
        content = await compileVerifyFix(content: content, filePath: target, memory: &memory, maxCycles: cycles)
        trace("compileVerifyFix done")
      }
      trace("linter.format")
      content = linter.format(content: content, filePath: target)
      trace("linter.format done")
      if !isManifest {
        trace("validateAndFix")
        let validated = try await validateAndFix(content: content, filePath: target, memory: &memory)
        trace("validateAndFix done")
        content = validated.content
        if let error = validated.error {
          return StepObservation(tool: "create", outcome: .validationFailed, keyFact: error)
        }
      }

      // Permission check
      trace("askPermission")
      let decision = await askPermission(tool: "create", target: target, detail: "\(content.count) chars")
      guard decision != .deny else {
        return StepObservation(tool: "create", outcome: .denied, keyFact: "Permission denied")
      }

      // Write file
      trace("files.write")
      memory.touch(target)
      metrics.filesModified += 1
      try files.write(path: target, content: content)
      lastDiffs.append(diffPreview.diffWrite(filePath: target, existingContent: nil, newContent: content))
      trace("files.write done")

      // Update live index so subsequent steps see this file's types
      trace("TreeSitterExtractor")
      let newEntries = TreeSitterExtractor().extract(from: content, file: target)
      projectIndex = projectIndex.filter { $0.filePath != target } + newEntries
      trace("ProjectAnalyzer.updateSnapshot")
      projectSnapshot = projectAnalyzer.updateSnapshot(
        projectSnapshot, afterWriting: target, content: content,
        extractor: TreeSitterExtractor()
      )
      trace("updateSnapshot done")

      // Post-write verification
      let urls = Self.extractURLs(memory.query)
      for url in urls {
        if !content.contains(url) {
          memory.addError("URL not found in output: \(url)")
        }
      }
      if let missing = Self.verifyContent(content: content, query: memory.query) {
        debug("Content verification: \(missing)")
      }

      return StepObservation(tool: "create", outcome: .ok,
                             keyFact: "Created \(target) (\(content.count) chars)")
    } catch {
      return StepObservation(tool: "create", outcome: .error, keyFact: "\(error)")
    }
  }

  /// Execute an edit task: generate replacement with existing content.
  private func executeEditTask(
    task: ConcreteTask, memory: inout WorkingMemory
  ) async -> StepObservation {
    let target = task.target
    guard files.exists(target) else {
      return StepObservation(tool: "edit", outcome: .error,
                             keyFact: "File not found: \(target)")
    }

    do {
      let system = Prompts.editSystem(domain: domain)
      memory.trackCall(estimatedTokens: TokenBudget.execute.total)
      var newContent = try await adapter.generate(prompt: task.specification, system: system)
      newContent = linter.cleanPlainTextOutput(newContent, filePath: target)

      // Validate
      let validated = try await validateAndFix(content: newContent, filePath: target, memory: &memory)
      newContent = validated.content
      if let error = validated.error {
        return StepObservation(tool: "edit", outcome: .validationFailed, keyFact: error)
      }

      // Permission check
      let decision = await askPermission(tool: "write", target: target, detail: "\(newContent.count) chars")
      guard decision != .deny else {
        return StepObservation(tool: "edit", outcome: .denied, keyFact: "Permission denied")
      }

      // Write with diff
      let existing = try? files.read(path: target, maxTokens: 2000)
      memory.touch(target)
      metrics.filesModified += 1
      try files.write(path: target, content: newContent)
      let diff = diffPreview.diffWrite(filePath: target, existingContent: existing, newContent: newContent)
      lastDiffs.append(diff)

      // Update live index so subsequent steps see edited types
      let editEntries = TreeSitterExtractor().extract(from: newContent, file: target)
      projectIndex = projectIndex.filter { $0.filePath != target } + editEntries
      projectSnapshot = projectAnalyzer.updateSnapshot(
        projectSnapshot, afterWriting: target, content: newContent,
        extractor: TreeSitterExtractor()
      )

      return StepObservation(tool: "edit", outcome: .ok, keyFact: "Edited \(target)")
    } catch {
      return StepObservation(tool: "edit", outcome: .error, keyFact: "\(error)")
    }
  }

  // MARK: - Legacy PlanStep Execution

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
            options: GenerationProfile.codeGen(maxTokens: 2000).options()
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

    var toolPayload = TraceEvent.Payload()
    toolPayload.tool = action.toolLabel
    toolPayload.target = action.targetPath
    toolPayload.output = String(toolOutput.prefix(800))
    await TraceContext.emit(kind: .toolCall, stage: "execute", payload: toolPayload)

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

    let toolArgsOptions = GenerationProfile.toolArgs().options()

    switch tool {
    case .bash:
      let p = try await adapter.generateStructured(
        prompt: base,
        system: "Generate a bash command. Working directory: \(workingDirectory). Use relative paths.",
        as: BashParams.self,
        options: toolArgsOptions
      )
      return .bash(command: p.command)

    case .read:
      if !step.target.isEmpty, files.exists(step.target) {
        return .read(path: step.target)
      }
      let p = try await adapter.generateStructured(
        prompt: base, system: "Specify the file path to read.", as: ReadParams.self,
        options: toolArgsOptions
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
          filePath: createTarget, prompt: intentPrompt, adapter: adapter,
          snapshot: projectSnapshot
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
        let fileRole = MicroSkill.inferFileRole(step.target)
        let skillHint = skillLoader.skillHints(
          domain: memory.intent?.domain ?? "swift",
          taskType: memory.intent?.taskType ?? "add",
          fileRole: fileRole, budget: 200
        )
        if let hint = skillHint { createSystem += " " + hint }
      }

      let createPrompt = "Create \(createTarget).\nRequest: \(TokenBudget.truncate(memory.query, toTokens: 150))\(createURLHint)"

      // For Swift files: multi-sample compile-select using CandidateGenerator.
      // Generates N candidates, compiles each, returns the first that passes.
      // Falls back to single-shot for non-Swift files.
      var content: String
      if createTargetLower.hasSuffix(".swift") {
        content = try await generateWithCandidates(
          prompt: createPrompt, system: createSystem,
          filePath: createTarget, memory: &memory
        )
      } else {
        content = try await adapter.generate(prompt: createPrompt, system: createSystem)
      }
      content = linter.cleanPlainTextOutput(content, filePath: createTarget)
      return .create(path: createTarget, content: content)

    case .write:
      let writeURLs = Self.extractURLs(memory.query)
      let writeURLHint = writeURLs.isEmpty ? "" : "\nIMPORTANT: Use these exact URLs (do not substitute): \(writeURLs.joined(separator: ", "))"
      let p = try await adapter.generateStructured(
        prompt: "\(base)\nUser request: \(TokenBudget.truncate(memory.query, toTokens: 150))\(writeURLHint)\n\nExisting:\n\(codeContext)",
        system: "Generate file path and complete content to write. Follow the user's request precisely.",
        as: WriteParams.self,
        options: toolArgsOptions
      )
      let writePath = step.target.isEmpty ? p.filePath : step.target
      return .write(path: writePath, content: p.content)

    case .edit:
      let editSystem = "Specify exact text to find and its replacement. Find text must match the file exactly. Use a full line or block, not a single word."
      // Priority-weighted prompt: file content is most critical, then request, then hints
      let reflectionHint = reflectionStore.formatForPrompt(query: memory.query) ?? ""
      let skillHint = step.target.hasSuffix(".swift")
        ? (skillLoader.skillHints(domain: memory.intent?.domain ?? "swift", taskType: memory.intent?.taskType ?? "fix", fileRole: MicroSkill.inferFileRole(step.target), budget: 200) ?? "")
        : ""
      let editBudget = await adapter.contextSize - TokenBudget.estimate(editSystem) - 150 - 400
      let editPrompt = base + "\nRequest: " + TokenBudget.truncate(memory.query, toTokens: 100) + "\n\n"
        + TokenBudget.packSections([
          PromptSection(label: "File", content: codeContext, priority: 90),
          PromptSection(label: "Memory", content: memory.compactDescription(tokenBudget: 150), priority: 70),
          PromptSection(label: "Past experience", content: reflectionHint, priority: 30),
          PromptSection(label: "Hints", content: skillHint, priority: 20)
        ], budget: editBudget)
      let editInputEst = TokenBudget.estimate(editPrompt) + TokenBudget.estimate(editSystem) + 150
      let editMaxOutput = max(400, await adapter.contextSize - editInputEst - 100)
      let p = try await adapter.generateStructured(
        prompt: editPrompt,
        system: editSystem,
        as: EditParams.self,
        options: GenerationProfile.toolArgs(maxTokens: editMaxOutput).options()
      )
      let editPath = step.target.isEmpty ? p.filePath : step.target
      return .edit(path: editPath, find: p.find, replace: p.replace)

    case .patch:
      let p = try await adapter.generateStructured(
        prompt: "\(base)\n\nFile content:\n\(codeContext)",
        system: "Generate a unified diff patch for this file. Use +/- line prefixes and @@ hunk headers.",
        as: PatchParams.self,
        options: toolArgsOptions
      )
      return .patch(path: p.filePath, diff: p.patch)

    case .search:
      let p = try await adapter.generateStructured(
        prompt: base, system: "Specify a grep pattern.", as: SearchParams.self,
        options: toolArgsOptions
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
    // Extract URLs so they survive truncation and appear in the skeleton prompt
    let urls = Self.extractURLs(memory.query)
    let urlHint = urls.isEmpty ? "" : "\nURLs: \(urls.joined(separator: ", "))"
    memory.trackCall(estimatedTokens: 800)
    let skeleton = try await adapter.generateStructured(
      prompt: "Create the structure for: \(TokenBudget.truncate(step.instruction, toTokens: 200))\nUser request: \(query)\(urlHint)",
      system: "Generate the file skeleton: imports, type declaration, properties, and method signatures WITHOUT bodies. Include ALL methods the user needs — do not return empty methodSignatures.",
      as: CodeSkeleton.self,
      options: GenerationProfile.codeGen(maxTokens: 800).options()
    )

    // Assemble skeleton
    var lines: [String] = []
    lines.append(skeleton.imports)
    lines.append("")
    lines.append(skeleton.typeDeclaration)
    for prop in skeleton.storedProperties.components(separatedBy: "\n") where !prop.isEmpty {
      lines.append("    \(prop.trimmingCharacters(in: .whitespaces))")
    }
    lines.append("")

    // Phase 2: Fill each method body with focused context
    let propsSummary = TokenBudget.truncate(skeleton.storedProperties, toTokens: 80)
    let typeSigs = projectSnapshot.typeSignatureBlock(budget: 80, stepIndex: 0)
    for sig in skeleton.methodSignatures where !sig.isEmpty {
      let shortSig = String(sig.prefix(120))
      debug("  two-phase: filling method \(shortSig.prefix(50))")
      memory.trackCall(estimatedTokens: 400)
      var fillContext = "Properties: \(propsSummary)"
      if !typeSigs.isEmpty { fillContext += "\nProject types: \(typeSigs)" }
      let body = try await adapter.generateStructured(
        prompt: "\(shortSig)\nContext: \(fillContext)",
        system: "Implement this Swift method. Return only the method with body. Be concise.",
        as: MethodBody.self,
        options: GenerationProfile.codeGen(maxTokens: 400).options()
      )
      // Apply TreeSitterRepair to each individual fill before assembly
      var impl = body.implementation.trimmingCharacters(in: .whitespaces)
      let (repairedImpl, _) = treeSitterRepair.repair(impl)
      impl = repairedImpl
      lines.append("    \(impl)")
      lines.append("")
    }

    lines.append("}")
    var result = lines.joined(separator: "\n")

    // Apply TreeSitterRepair to the assembled file
    let (repairedResult, repairFixes) = treeSitterRepair.repair(result)
    if !repairFixes.isEmpty {
      debug("  two-phase assembly repair: \(repairFixes.joined(separator: ", "))")
      result = repairedResult
    }

    // Lint the assembled file
    let path = step.target
    result = linter.lint(content: result, filePath: path)

    return result
  }

  // MARK: - Multi-Sample Compile-Select

  /// Generate Swift code using multi-sample compile-select.
  /// Generates N candidates, compiles each, returns the first that passes.
  /// If none compile, enriches the fix prompt with correct API signatures from SignatureIndex.
  private func generateWithCandidates(
    prompt: String,
    system: String,
    filePath: String,
    memory: inout WorkingMemory
  ) async throws -> String {
    // Use CreateParams for structured generation to get both path and content
    memory.trackCall(estimatedTokens: 600 * Config.candidateCount)

    let structuredSystem = system + "\nRespond with a JSON object with filePath and content fields."
    do {
      let (value, result) = try await candidateGenerator.generate(
        prompt: prompt,
        system: structuredSystem,
        as: CreateParams.self,
        filePath: filePath,
        extract: { $0.content }
      )

      if result.compiled {
        debug("CANDIDATE: compiled on attempt (0 errors)")
        return value.content
      }

      // None compiled — try enriching with signature hints
      debug("CANDIDATE: best has \(result.errorCount) errors, trying signature-enriched fix")
      let (_, hints) = await candidateGenerator.evaluateAndSuggestFix(
        code: value.content, filePath: filePath, apiProvider: apiProvider
      )

      if !hints.isEmpty {
        let hintText = hints.joined(separator: "\n")
        let fixPrompt = "Fix this code.\nErrors:\n\(result.errors.prefix(3).joined(separator: "\n"))\n\n\(hintText)\n\nCode:\n\(value.content)"
        let fixSystem = "Fix ONLY the errors. Use the correct API signatures provided. Return the complete corrected file."
        let fixed = try await adapter.generate(prompt: fixPrompt, system: fixSystem)
        return linter.cleanPlainTextOutput(fixed, filePath: filePath)
      }

      // No signature hints available — return best candidate as-is
      return value.content

    } catch {
      // Fall back to single-shot plain text generation
      debug("CANDIDATE: multi-sample failed (\(error)), falling back to single-shot")
      return try await adapter.generate(prompt: prompt, system: system)
    }
  }

  // MARK: - Per-File Compile-Verify-Fix

  /// Compile-check a Swift file and fix errors using runtime API discovery.
  /// Each cycle: swiftc -typecheck → parse errors → lookup correct API → fix region → repeat.
  private func compileVerifyFix(
    content: String,
    filePath: String,
    memory: inout WorkingMemory,
    maxCycles: Int = 2
  ) async -> String {
    // Pre-pass: apply brace balancing and lint fixes before compilation
    var current = linter.lint(content: content, filePath: filePath)
    let tempDir = NSTemporaryDirectory()
    let fileName = (filePath as NSString).lastPathComponent
    let tempPath = (tempDir as NSString).appendingPathComponent("junco_cvf_\(fileName)")
    defer { try? FileManager.default.removeItem(atPath: tempPath) }

    for cycle in 0..<maxCycles {
      // Write and compile
      do { try current.write(toFile: tempPath, atomically: true, encoding: .utf8) } catch { break }
      let result = await candidateGenerator.evaluate(code: current, filePath: fileName)
      guard !result.compiled else {
        if cycle > 0 { debug("CVF cycle \(cycle + 1): clean compile") }
        return current
      }
      guard !result.errors.isEmpty else { break }

      debug("CVF cycle \(cycle + 1): \(result.errorCount) errors")

      // For each error, try structured fix first, then LLM fallback
      let fixBuilder = StructuredFixBuilder()
      var fixed = current
      for error in result.errors.prefix(2) {
        // Look up the correct API signature
        let hint = await apiProvider.lookupFix(compilerError: error)

        // Extract the error region
        let errors = errorExtractor.parseErrors(error)
        guard let firstError = errors.first else { continue }
        guard let region = errorExtractor.extractAST(content: fixed, errorLine: firstError.line)
                ?? errorExtractor.extract(content: fixed, errorLine: firstError.line) else { continue }

        // Try structured fix — exact fixes skip the LLM entirely
        let instruction = fixBuilder.buildFixInstruction(
          error: firstError, codeRegion: region, apiHint: hint, snapshot: projectSnapshot
        )
        if let instruction, instruction.confidence == .exact, let replacement = instruction.replacement {
          debug("  CVF exact fix: \(instruction.description.prefix(80))")
          let lineRegion = CodeRegion(text: replacement, startLine: firstError.line - 1, endLine: firstError.line - 1)
          fixed = errorExtractor.splice(original: fixed, region: lineRegion, fix: replacement)
          continue
        }

        // Build fix prompt, enriched with structured instruction if available
        var fixPrompt = "Fix this code.\nError: \(String(firstError.message.prefix(150)))"
        if let instruction { fixPrompt += "\nFix: \(instruction.description.prefix(200))" }
        if let hint, instruction == nil { fixPrompt += "\n\(hint)" }
        fixPrompt += "\n\nCode:\n\(region.text)"
        memory.trackCall(estimatedTokens: 400)
        do {
          let fixResult = try await adapter.generate(
            prompt: fixPrompt,
            system: "Fix ONLY the error. Return the corrected code region. No explanation."
          )
          let cleanFix = linter.cleanPlainTextOutput(fixResult, filePath: filePath)
          if !cleanFix.isEmpty {
            fixed = errorExtractor.splice(original: fixed, region: region, fix: cleanFix)
          }
        } catch {
          break
        }
      }
      current = fixed
    }
    return current
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
    let originalContent = content // preserve pre-retry content

    // Brief task context so retries know the original intent
    let taskHint = TokenBudget.truncate(memory.query, toTokens: 60)

    var retries = 0
    while retries < Config.maxValidationRetries {
      let feedback = swiftValidator.feedbackForLLM(code: content, filePath: filePath)
      guard let error = feedback else { break }
      retries += 1

      if let region = errorExtractor.extract(content: content, errorMessage: error) {
        debug("Targeted retry \(retries) for \(filePath) (lines \(region.startLine)-\(region.endLine)): \(error)")
        memory.trackCall(estimatedTokens: 500)
        let fixed = try await adapter.generateStructured(
          prompt: "Fix this code.\nTask: \(taskHint)\nError: \(String(error.prefix(200)))\n\nCode:\n\(region.text)",
          system: "Fix ONLY this code region. Return the corrected code.",
          as: CodeFragment.self,
          options: GenerationProfile.codeGen(maxTokens: 500).options()
        )
        content = errorExtractor.splice(original: content, region: region, fix: fixed.content)
      } else {
        debug("Full retry \(retries) for \(filePath): \(error)")
        memory.trackCall(estimatedTokens: 800)
        let truncatedCode = TokenBudget.truncate(content, toTokens: 800)
        let fixed = try await adapter.generateStructured(
          prompt: "Fix this code.\nTask: \(taskHint)\nError: \(String(error.prefix(200)))\n\nCode:\n\(truncatedCode)",
          system: "Fix the error. Return the complete corrected file.",
          as: CreateParams.self,
          options: GenerationProfile.codeGen(maxTokens: 1200).options()
        )
        content = fixed.content
      }
      content = linter.lint(content: content, filePath: filePath)
    }

    if let finalError = validatorRegistry.validate(code: content, filePath: filePath) {
      // If retries made it worse, fall back to the original if it validates
      if retries > 0,
         validatorRegistry.validate(code: originalContent, filePath: filePath) == nil {
        debug("Retries degraded content for \(filePath) — reverting to original")
        return (originalContent, nil)
      }
      debug("Validation failed after \(retries) retries for \(filePath): \(finalError)")
      return (content, "VALIDATION FAILED: \(finalError)")
    }

    return (content, nil)
  }

  // MARK: - Build-Fix Reflexion Loop

  /// After all execute steps, run a build and attempt to fix errors.
  /// Uses targeted retry: extract error region, fix just that part.
  ///
  /// Skipped when `$JUNCO_SKIP_BUILD_FIX=1` — needed during eval harness runs because
  /// `swift build` called here would deadlock on the SPM `.build/` lock held by the
  /// outer `swift run junco-eval` process (observed as an indefinite hang in create-hello).
  private func buildAndFix(memory: inout WorkingMemory, maxCycles: Int = 2) async {
    guard metrics.filesModified > 0 else { return }
    guard domain.buildCommand != nil else { return }
    if ProcessInfo.processInfo.environment["JUNCO_SKIP_BUILD_FIX"] == "1" {
      debug("buildAndFix skipped (JUNCO_SKIP_BUILD_FIX=1)")
      return
    }

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
            as: CodeFragment.self,
            options: GenerationProfile.codeGen(maxTokens: 500).options()
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

  /// Fully deterministic reflection — no LLM call.
  /// AFM's reflection was unreliable (always returned succeeded:true),
  /// so we build the summary from actual observations.
  private func reflect(memory: WorkingMemory) -> AgentReflection {
    let succeeded = memory.didSucceed
    let taskType = memory.intent?.taskType ?? "Task"

    let summary: String
    if succeeded {
      summary = "\(taskType) completed"
    } else {
      let lastError = memory.errors.last ?? "unknown error"
      summary = "\(taskType) failed: \(String(lastError.prefix(100)))"
    }

    let insight: String
    if succeeded && memory.errors.isEmpty {
      insight = "All \(memory.observations.count) steps succeeded."
    } else {
      let steps = memory.observations.map { "[\($0.tool)] \($0.outcome.rawValue): \($0.keyFact)" }
      insight = steps.joined(separator: "\n")
    }

    let improvement = memory.errors.isEmpty ? "" :
      "Errors: \(memory.errors.suffix(3).joined(separator: "; "))"

    return AgentReflection(
      taskSummary: summary, insight: insight,
      improvement: improvement, succeeded: succeeded
    )
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
        // Cascade: fuzzy → structural (AST) → patch
        try files.edit(path: path, find: find, replace: replace, fuzzy: true, structural: true)
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
      let cmd = "grep -rn \(shellEscape(pattern)) Sources/ Tests/ Package.swift --include='*.swift' 2>/dev/null | head -20"
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
  public var deterministicClassifications: Int = 0
}
