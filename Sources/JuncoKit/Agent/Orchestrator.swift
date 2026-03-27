// Orchestrator.swift — Main agent pipeline
//
// classify → strategy → plan → execute (2-phase) → reflect
// All features wired: permissions, build verification, diff preview,
// micro-skills, scratchpad, web search, notifications.

import Foundation

public actor Orchestrator {

  private let adapter: AFMAdapter
  private let shell: SafeShell
  private let files: FileTools
  private let jsValidator: JSCValidator
  private let swiftValidator: SwiftValidator
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
    self.jsValidator = JSCValidator()
    self.swiftValidator = SwiftValidator()
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

    // Pre-read @-referenced files
    var explicitContext = ""
    for path in referencedFiles {
      if let content = try? files.read(path: path, maxTokens: Config.fileReadMaxTokens) {
        explicitContext += "--- @\(path) ---\n\(content)\n\n"
        memory.touch(path)
        debug("PRE-READ @\(path): \(TokenBudget.estimate(content)) tokens")
      }
    }
    if let urlCtx = urlContext {
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
    debug("CLASSIFY → domain:\(intent.domain) type:\(intent.taskType) complexity:\(intent.complexity) targets:\(intent.targets)")

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
        taskSummary: "Explained \(referencedFiles.joined(separator: ", "))",
        insight: response, improvement: "", succeeded: true
      )
      debug("EXPLAIN → \(TokenBudget.estimate(response)) tokens")
      try? reflectionStore.save(query: query, reflection: reflection)
      metrics.tasksCompleted += 1
      metrics.totalTokensUsed += memory.totalTokensUsed
      metrics.totalLLMCalls += memory.llmCalls
      return RunResult(memory: memory, reflection: reflection, wasStreamed: true)
    }

    // Fast path: simple file creation — bypass strategy/plan/execute
    // Direct-AFM testing showed 90% quality from a single well-crafted prompt
    // vs 11% through the full pipeline. For simple creates, 1 call is better than 10.
    if intent.taskType == "add" && intent.complexity == "simple" {
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
            let feedback = jsValidator.feedbackForLLM(code: content, filePath: path)
              ?? swiftValidator.feedbackForLLM(code: content, filePath: path)
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
          if let finalError = jsValidator.feedbackForLLM(code: content, filePath: path)
              ?? swiftValidator.feedbackForLLM(code: content, filePath: path) {
            memory.addObservation(StepObservation(tool: "create", outcome: "error", keyFact: finalError))
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
          memory.addObservation(StepObservation(tool: "create", outcome: "ok", keyFact: "Created \(path) (\(content.count) chars)"))

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
        if prev.allSatisfy({ $0.tool == step.tool && $0.target == step.target }) {
          debug("LOOP detected at step \(index + 1) — breaking")
          memory.addError("Loop detected: repeated \(step.tool) on \(step.target)")
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
          debug("EXEC[\(index + 1)] → [\(observation.outcome)] \(observation.tool): \(observation.keyFact)")

          // Check if the step itself reported an error in output
          if observation.outcome == "error", let handler = callbacks.onStepError, attempt < maxRetries {
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

        } catch {
          memory.addError("Step \(index + 1): \(error)")
          memory.addObservation(StepObservation(
            tool: step.tool, outcome: "error", keyFact: "\(error)"
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
              // Use a labeled break to exit both while and for
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
           lastObs.tool == "create" && lastObs.outcome == "ok" {
          debug("EARLY EXIT: simple create succeeded on step 1, skipping \(cappedSteps.count - 1) remaining steps")
          break
        }
      }
    }

    // Build verification + LSP diagnostics after modifications
    if filesWereModified {
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

    let reflection = try await reflect(memory: &memory)
    debug("REFLECT → succeeded:\(reflection.succeeded) insight:\(reflection.insight)")

    try? reflectionStore.save(query: query, reflection: reflection)

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
      "what is junco", "what can you do", "help me",
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

      return AgentIntent(
        domain: domain.kind.rawValue, taskType: finalLabel,
        complexity: targets.count > 2 ? "moderate" : "simple", targets: targets
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
    let prompt = Prompts.strategyPrompt(query: query, intent: intent)
    memory.trackCall(estimatedTokens: TokenBudget.strategy.total)
    return try await adapter.generateStructured(
      prompt: prompt, system: Prompts.strategySystem, as: AgentStrategy.self
    )
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
    let memoryStr = memory.compactDescription(tokenBudget: 200)
    let reflectionHint = reflectionStore.formatForPrompt(query: memory.query)

    // Inject micro-skill hints + scratchpad
    let skillHint = skillLoader.skillHints(
      domain: memory.intent?.domain ?? domain.kind.rawValue,
      taskType: memory.intent?.taskType ?? "fix"
    )
    let scratchpadCtx = scratchpad.promptContext(budget: 50)

    let prompt = Prompts.executePrompt(
      step: step, memory: memoryStr, codeContext: codeContext, reflection: reflectionHint
    )

    // Build system prompt with all injected context
    var systemPrompt = Prompts.executeSystem(domainHint: domain.promptHint)
    if let hint = skillHint { systemPrompt += " " + hint }
    if let notes = scratchpadCtx { systemPrompt += " " + notes }

    // Phase 1: Choose tool
    memory.trackCall(estimatedTokens: 600)
    let choice = try await adapter.generateStructured(
      prompt: prompt, system: systemPrompt, as: ToolChoice.self
    )
    debug("  tool choice: \(choice.tool) — \(choice.reasoning)")

    // Phase 2: Resolve and execute
    let action = try await resolveToolAction(
      tool: choice.tool, step: step, codeContext: codeContext, memory: &memory
    )
    debug("  action: \(action)")

    let toolOutput = await executeToolSafe(action: action, memory: &memory)

    return compressObservation(tool: choice.tool, output: toolOutput, step: step.instruction)
  }

  private func resolveToolAction(
    tool: String, step: PlanStep, codeContext: String,
    memory: inout WorkingMemory
  ) async throws -> ToolAction {
    let base = "Step: \(step.instruction)\nTarget: \(step.target)\nProject root: \(workingDirectory)"
    memory.trackCall(estimatedTokens: 600)

    switch tool.lowercased() {
    case "bash":
      let p = try await adapter.generateStructured(
        prompt: base,
        system: "Generate a bash command. Working directory: \(workingDirectory). Use relative paths.",
        as: BashParams.self
      )
      return .bash(command: p.command)

    case "read":
      if !step.target.isEmpty, files.exists(step.target) {
        return .read(path: step.target)
      }
      let p = try await adapter.generateStructured(
        prompt: base, system: "Specify the file path to read.", as: ReadParams.self
      )
      return .read(path: p.filePath)

    case "create":
      let createURLs = Self.extractURLs(memory.query)
      let createURLHint = createURLs.isEmpty ? "" : "\nIMPORTANT: Use these exact URLs (do not substitute): \(createURLs.joined(separator: ", "))"
      let p = try await adapter.generateStructured(
        prompt: "\(base)\nUser request: \(TokenBudget.truncate(memory.query, toTokens: 150))\(createURLHint)",
        system: "Generate file path and complete content for a new file. Follow the user's request precisely.",
        as: CreateParams.self
      )
      let path = step.target.isEmpty ? p.filePath : step.target
      return .create(path: path, content: p.content)

    case "write":
      let writeURLs = Self.extractURLs(memory.query)
      let writeURLHint = writeURLs.isEmpty ? "" : "\nIMPORTANT: Use these exact URLs (do not substitute): \(writeURLs.joined(separator: ", "))"
      let p = try await adapter.generateStructured(
        prompt: "\(base)\nUser request: \(TokenBudget.truncate(memory.query, toTokens: 150))\(writeURLHint)\n\nExisting:\n\(codeContext)",
        system: "Generate file path and complete content to write. Follow the user's request precisely.",
        as: WriteParams.self
      )
      let writePath = step.target.isEmpty ? p.filePath : step.target
      return .write(path: writePath, content: p.content)

    case "edit":
      let p = try await adapter.generateStructured(
        prompt: "\(base)\nUser request: \(TokenBudget.truncate(memory.query, toTokens: 150))\n\nFile content:\n\(codeContext)",
        system: "Specify exact text to find and its replacement. Find text must match the file exactly.",
        as: EditParams.self
      )
      let editPath = step.target.isEmpty ? p.filePath : step.target
      return .edit(path: editPath, find: p.find, replace: p.replace)

    case "patch":
      let p = try await adapter.generateStructured(
        prompt: "\(base)\n\nFile content:\n\(codeContext)",
        system: "Generate a unified diff patch for this file. Use +/- line prefixes and @@ hunk headers.",
        as: PatchParams.self
      )
      return .patch(path: p.filePath, diff: p.patch)

    case "search":
      let p = try await adapter.generateStructured(
        prompt: base, system: "Specify a grep pattern.", as: SearchParams.self
      )
      return .search(pattern: p.pattern)

    default:
      return .bash(command: "echo 'Unknown tool: \(tool)'")
    }
  }

  private func reflect(memory: inout WorkingMemory) async throws -> AgentReflection {
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
      let createDecision = await askPermission(tool: "create", target: path, detail: "\(content.count) chars")
      guard createDecision != .deny else { return "DENIED: create \(path)" }

      // Syntax validation with retry (JS via JSC, Swift via swiftc -parse)
      var retries = 0
      while retries < Config.maxValidationRetries {
        let feedback = jsValidator.feedbackForLLM(code: content, filePath: path)
          ?? swiftValidator.feedbackForLLM(code: content, filePath: path)
        guard let error = feedback else { break }
        retries += 1
        debug("Validation retry \(retries) for \(path): \(error)")
        memory.trackCall(estimatedTokens: 800)
        let fixed = try await adapter.generateStructured(
          prompt: "Fix this code.\nError: \(error)\n\nCode:\n\(content)",
          system: "Fix the error. Return the complete corrected file.",
          as: CreateParams.self
        )
        content = fixed.content
      }
      // Final validation check after retries exhausted
      if let finalError = jsValidator.feedbackForLLM(code: content, filePath: path)
          ?? swiftValidator.feedbackForLLM(code: content, filePath: path) {
        debug("Validation failed after \(retries) retries for \(path): \(finalError)")
        return "VALIDATION FAILED: \(finalError)"
      }

      memory.touch(path)
      metrics.filesModified += 1
      try files.write(path: path, content: content)

      // Per-tool verification: confirm file was actually created
      guard files.exists(path) else {
        return "ERROR: File not created despite write succeeding: \(path)"
      }

      let createDiff = diffPreview.diffWrite(filePath: path, existingContent: nil, newContent: content)
      lastDiffs.append(createDiff)
      return "Created \(path) (\(content.count) chars)"

    case .write(let path, var content):
      // Permission check via callback (CLI handles terminal I/O)
      let decision = await askPermission(tool: "write", target: path, detail: "\(content.count) chars")
      guard decision != .deny else { return "DENIED: write to \(path)" }

      // Syntax validation with retry (JS via JSC, Swift via swiftc -parse)
      var writeRetries = 0
      while writeRetries < Config.maxValidationRetries {
        let feedback = jsValidator.feedbackForLLM(code: content, filePath: path)
          ?? swiftValidator.feedbackForLLM(code: content, filePath: path)
        guard let error = feedback else { break }
        writeRetries += 1
        debug("Validation retry \(writeRetries) for \(path): \(error)")
        memory.trackCall(estimatedTokens: 800)
        let fixed = try await adapter.generateStructured(
          prompt: "Fix this code.\nError: \(error)\n\nCode:\n\(content)",
          system: "Fix the error. Return the complete corrected file.",
          as: WriteParams.self
        )
        content = fixed.content
      }
      if let finalError = jsValidator.feedbackForLLM(code: content, filePath: path)
          ?? swiftValidator.feedbackForLLM(code: content, filePath: path) {
        debug("Validation failed after \(writeRetries) retries for \(path): \(finalError)")
        return "VALIDATION FAILED: \(finalError)"
      }

      // Capture diff
      let existing = try? files.read(path: path, maxTokens: 2000)
      memory.touch(path)
      metrics.filesModified += 1
      try files.write(path: path, content: content)

      let diff = diffPreview.diffWrite(filePath: path, existingContent: existing, newContent: content)
      lastDiffs.append(diff)
      return "Written \(path) (\(content.count) chars)"

    case .edit(let path, let find, let replace):
      let decision = await askPermission(tool: "edit", target: path, detail: "replacing \(find.count) chars")
      guard decision != .deny else { return "DENIED: edit \(path)" }

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
      let decision = await askPermission(tool: "patch", target: path, detail: "apply unified diff")
      guard decision != .deny else { return "DENIED: patch \(path)" }

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
      let cmd = "grep -rn \(shellEscape(pattern)) . --include='*.swift' --include='*.js' --include='*.ts' --include='*.css' --include='*.html' | head -20"
      let result = try await shell.execute(cmd)
      return result.formatted(maxTokens: Config.toolOutputMaxTokens)
    }
  }

  private func compressObservation(tool: String, output: String, step: String) -> StepObservation {
    let lines = output.split(separator: "\n", omittingEmptySubsequences: true)
    let outcome = (output.contains("ERROR") || output.contains("DENIED") || output.contains("FAILED")) ? "error" : "ok"
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
