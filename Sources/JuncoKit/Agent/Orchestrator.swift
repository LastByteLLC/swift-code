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
        tool: "bash", outcome: shellResult.exitCode == 0 ? "ok" : "error",
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

    // Phase 2: Resolve and execute (with two-phase fallback on context overflow)
    let action: ToolAction
    do {
      action = try await resolveToolAction(
        tool: choice.tool, step: step, codeContext: codeContext, memory: &memory
      )
    } catch let error as LLMError where choice.tool == "create" {
      // Context overflow on create → fall back to two-phase generation
      if case .contextOverflow = error, step.target.hasSuffix(".swift") {
        debug("  context overflow on create — falling back to two-phase generation")
        let twoPhaseContent = try await generateTwoPhase(step: step, memory: &memory)
        let linted = linter.lint(content: twoPhaseContent, filePath: step.target)
        let fallbackAction = ToolAction.create(path: step.target, content: linted)
        let toolOutput = await executeToolSafe(action: fallbackAction, memory: &memory)
        return compressObservation(tool: "create", output: toolOutput, step: step.instruction)
      }
      throw error
    }
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
      let createTarget = step.target.isEmpty ? "" : step.target
      let createTargetLower = createTarget.lowercased()

      // Route 1: Template-based generation for structured file formats
      // The model fills in simple intent fields; the template guarantees valid syntax.
      if templateRenderer.shouldUseTemplate(filePath: createTarget) {
        let intentPrompt = "\(base)\nUser request: \(TokenBudget.truncate(memory.query, toTokens: 200))"
        memory.trackCall(estimatedTokens: 600)

        if createTargetLower.hasSuffix(".entitlements") {
          let intent = try await adapter.generateStructured(
            prompt: intentPrompt,
            system: "Determine which entitlements this app needs based on the user's request.",
            as: EntitlementsIntent.self
          )
          return .create(path: createTarget, content: templateRenderer.renderEntitlements(intent))

        } else if createTargetLower.hasSuffix("package.swift") {
          let intent = try await adapter.generateStructured(
            prompt: intentPrompt,
            system: "Determine the SPM package configuration: name, targets, dependencies, platforms.",
            as: PackageIntent.self
          )
          return .create(path: createTarget, content: templateRenderer.renderPackage(intent))

        } else if createTargetLower.hasSuffix("info.plist") || createTargetLower.hasSuffix(".plist") {
          let intent = try await adapter.generateStructured(
            prompt: intentPrompt,
            system: "Determine the Info.plist configuration: display name, bundle ID, privacy permissions needed.",
            as: PlistIntent.self
          )
          return .create(path: createTarget, content: templateRenderer.renderPlist(intent))

        } else if createTargetLower.hasSuffix(".xcprivacy") {
          let intent = try await adapter.generateStructured(
            prompt: intentPrompt,
            system: "Determine the privacy manifest: accessed API types, reasons, tracking, collected data.",
            as: PrivacyManifestIntent.self
          )
          return .create(path: createTarget, content: templateRenderer.renderPrivacyManifest(intent))
        }
      }

      // Route 2: LLM-generated content for code and prose files
      let createURLs = Self.extractURLs(memory.query)
      let createURLHint = createURLs.isEmpty ? "" : "\nIMPORTANT: Use these exact URLs (do not substitute): \(createURLs.joined(separator: ", "))"

      var createSystem = "Generate file path and complete content for a new file. Follow the user's request precisely."
      // Inject domain skill hint for Swift files
      if createTargetLower.hasSuffix(".swift") {
        let skillHint = skillLoader.skillHints(
          domain: memory.intent?.domain ?? "swift",
          taskType: memory.intent?.taskType ?? "add",
          budget: 150
        )
        if let hint = skillHint { createSystem += " " + hint }
      }

      let p = try await adapter.generateStructured(
        prompt: "\(base)\nUser request: \(TokenBudget.truncate(memory.query, toTokens: 150))\(createURLHint)",
        system: createSystem,
        as: CreateParams.self
      )
      let path = createTarget.isEmpty ? p.filePath : createTarget
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
      var editSystem = "Specify exact text to find and its replacement. Find text must match the file exactly. Use a full line or block, not a single word."
      if step.target.hasSuffix(".swift") {
        let skillHint = skillLoader.skillHints(
          domain: memory.intent?.domain ?? "swift",
          taskType: memory.intent?.taskType ?? "fix",
          budget: 100
        )
        if let hint = skillHint { editSystem += " " + hint }
      }
      let p = try await adapter.generateStructured(
        prompt: "\(base)\nUser request: \(TokenBudget.truncate(memory.query, toTokens: 150))\n\nFile content:\n\(codeContext)",
        system: editSystem,
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

      // Step 1: Deterministic lint (instant, no LLM call)
      content = linter.lint(content: content, filePath: path)

      // Step 2: Syntax validation with TARGETED retry
      var retries = 0
      while retries < Config.maxValidationRetries {
        let feedback = jsValidator.feedbackForLLM(code: content, filePath: path)
          ?? swiftValidator.feedbackForLLM(code: content, filePath: path)
        guard let error = feedback else { break }
        retries += 1

        // Try targeted fix: extract the error region, fix just that part
        if let region = errorExtractor.extract(content: content, errorMessage: error) {
          debug("Targeted retry \(retries) for \(path) (lines \(region.startLine)-\(region.endLine)): \(error)")
          memory.trackCall(estimatedTokens: 500)
          let fixPrompt = "Fix this code.\nError: \(String(error.prefix(200)))\n\nCode:\n\(region.text)"
          let fixed = try await adapter.generateStructured(
            prompt: fixPrompt,
            system: "Fix ONLY this code region. Return the corrected code.",
            as: CodeFragment.self
          )
          content = errorExtractor.splice(original: content, region: region, fix: fixed.content)
        } else {
          // Can't isolate region — fall back to full-file retry (truncated)
          debug("Full retry \(retries) for \(path): \(error)")
          memory.trackCall(estimatedTokens: 800)
          let truncatedCode = TokenBudget.truncate(content, toTokens: 800)
          let fixed = try await adapter.generateStructured(
            prompt: "Fix this code.\nError: \(String(error.prefix(200)))\n\nCode:\n\(truncatedCode)",
            system: "Fix the error. Return the complete corrected file.",
            as: CreateParams.self
          )
          content = fixed.content
        }
        // Re-lint after every fix
        content = linter.lint(content: content, filePath: path)
      }

      // Final validation check
      if let finalError = validatorRegistry.validate(code: content, filePath: path) {
        debug("Validation failed after \(retries) retries for \(path): \(finalError)")
        return "VALIDATION FAILED: \(finalError)"
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
      let decision = await askPermission(tool: "write", target: path, detail: "\(content.count) chars")
      guard decision != .deny else { return "DENIED: write to \(path)" }

      // Lint → validate → targeted retry (same pipeline as create)
      content = linter.lint(content: content, filePath: path)

      var writeRetries = 0
      while writeRetries < Config.maxValidationRetries {
        let feedback = jsValidator.feedbackForLLM(code: content, filePath: path)
          ?? swiftValidator.feedbackForLLM(code: content, filePath: path)
        guard let error = feedback else { break }
        writeRetries += 1

        if let region = errorExtractor.extract(content: content, errorMessage: error) {
          debug("Targeted retry \(writeRetries) for \(path) (lines \(region.startLine)-\(region.endLine)): \(error)")
          memory.trackCall(estimatedTokens: 500)
          let fixed = try await adapter.generateStructured(
            prompt: "Fix this code.\nError: \(String(error.prefix(200)))\n\nCode:\n\(region.text)",
            system: "Fix ONLY this code region. Return the corrected code.",
            as: CodeFragment.self
          )
          content = errorExtractor.splice(original: content, region: region, fix: fixed.content)
        } else {
          debug("Full retry \(writeRetries) for \(path): \(error)")
          memory.trackCall(estimatedTokens: 800)
          let truncatedCode = TokenBudget.truncate(content, toTokens: 800)
          let fixed = try await adapter.generateStructured(
            prompt: "Fix this code.\nError: \(String(error.prefix(200)))\n\nCode:\n\(truncatedCode)",
            system: "Fix the error. Return the complete corrected file.",
            as: WriteParams.self
          )
          content = fixed.content
        }
        content = linter.lint(content: content, filePath: path)
      }
      if let finalError = validatorRegistry.validate(code: content, filePath: path) {
        debug("Validation failed after \(writeRetries) retries for \(path): \(finalError)")
        return "VALIDATION FAILED: \(finalError)"
      }

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
