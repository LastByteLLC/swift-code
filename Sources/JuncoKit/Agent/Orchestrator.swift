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

  public private(set) var verbose: Bool = false
  public func setVerbose(_ value: Bool) { verbose = value }

  public private(set) var metrics: SessionMetrics

  public private(set) var lastDiffs: [String] = []
  public private(set) var lastBuildResult: String?

  public init(adapter: AFMAdapter, workingDirectory: String) {
    self.adapter = adapter
    self.workingDirectory = workingDirectory
    self.shell = SafeShell(workingDirectory: workingDirectory)
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
    urlContext: String? = nil
  ) async throws -> RunResult {
    var memory = WorkingMemory(query: query)
    lastDiffs = []
    lastBuildResult = nil

    // Conversational short-circuit
    if let directResponse = handleConversational(query) {
      return RunResult(
        memory: memory,
        reflection: AgentReflection(
          taskSummary: "Conversational query", insight: directResponse,
          improvement: "", succeeded: true
        )
      )
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

    // Explain/explore shortcut with @-files
    if (intent.taskType == "explain" || intent.taskType == "explore") && !explicitContext.isEmpty {
      debug("SHORTCUT: explain/explore with @-referenced files, skipping plan")
      let explainPrompt = "Task: \(query)\n\nContent:\n\(TokenBudget.truncate(explicitContext, toTokens: 2500))"
      memory.trackCall(estimatedTokens: TokenBudget.execute.total)
      let response = try await adapter.generate(
        prompt: explainPrompt,
        system: "You are a coding assistant. Explain the provided code or documentation clearly and concisely. \(domain.promptHint)"
      )
      let reflection = AgentReflection(
        taskSummary: "Explained \(referencedFiles.joined(separator: ", "))",
        insight: response, improvement: "", succeeded: true
      )
      debug("EXPLAIN → \(TokenBudget.estimate(response)) tokens")
      try? reflectionStore.save(query: query, reflection: reflection)
      metrics.tasksCompleted += 1
      metrics.totalTokensUsed += memory.totalTokensUsed
      metrics.totalLLMCalls += memory.llmCalls
      return RunResult(memory: memory, reflection: reflection)
    }

    let strategy = try await discoverStrategy(query: query, intent: intent, memory: &memory)
    memory.strategy = strategy
    debug("STRATEGY → approach:\(strategy.approach) start:\(strategy.startingPoints) risk:\(strategy.risk)")

    let plan = try await plan(
      query: query, intent: intent, strategy: strategy,
      memory: &memory, explicitContext: explicitContext
    )

    let maxSteps = 8
    let cappedSteps = Array(plan.steps.prefix(maxSteps))
    if plan.steps.count > maxSteps {
      debug("PLAN capped from \(plan.steps.count) to \(maxSteps) steps")
    }
    memory.plan = AgentPlan(steps: cappedSteps)
    debug("PLAN → \(cappedSteps.count) steps:")
    for (i, step) in cappedSteps.enumerated() {
      debug("  [\(i + 1)] \(step.tool): \(step.instruction) → \(step.target)")
    }

    // Execute with loop detection
    var lastActions: [(tool: String, target: String)] = []
    var filesWereModified = false

    for (index, step) in cappedSteps.enumerated() {
      memory.currentStepIndex = index

      if lastActions.count >= 2 {
        let prev = lastActions.suffix(2)
        if prev.allSatisfy({ $0.tool == step.tool && $0.target == step.target }) {
          debug("LOOP detected at step \(index + 1) — breaking")
          memory.addError("Loop detected: repeated \(step.tool) on \(step.target)")
          break
        }
      }

      do {
        let observation = try await executeStep(step: step, memory: &memory)
        memory.addObservation(observation)
        lastActions.append((tool: observation.tool, target: step.target))
        if observation.tool == "write" || observation.tool == "edit" {
          filesWereModified = true
        }
        debug("EXEC[\(index + 1)] → [\(observation.outcome)] \(observation.tool): \(observation.keyFact)")
      } catch {
        memory.addError("Step \(index + 1): \(error)")
        memory.addObservation(StepObservation(
          tool: step.tool, outcome: "error", keyFact: "\(error)"
        ))
        lastActions.append((tool: step.tool, target: step.target))
        debug("EXEC[\(index + 1)] → [ERROR] \(error)")
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
    "explain": "explain", "describe": "explain", "what": "explain",
    "how": "explain", "why": "explain", "summarize": "explain",
    "fix": "fix", "debug": "fix", "repair": "fix",
    "add": "add", "create": "add", "implement": "add", "write": "add",
    "refactor": "refactor", "clean": "refactor", "simplify": "refactor",
    "test": "test",
    "find": "explore", "search": "explore", "grep": "explore",
    "where": "explore", "list": "explore", "show": "explore",
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
    let base = "Step: \(step.instruction)\nTarget: \(step.target)"
    memory.trackCall(estimatedTokens: 600)

    switch tool.lowercased() {
    case "bash":
      let p = try await adapter.generateStructured(
        prompt: base,
        system: "Generate a bash command. Working directory is the project root.",
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

    case "write":
      let p = try await adapter.generateStructured(
        prompt: "\(base)\n\nExisting:\n\(codeContext)",
        system: "Generate file path and complete content to write.",
        as: WriteParams.self
      )
      return .write(path: p.filePath, content: p.content)

    case "edit":
      let p = try await adapter.generateStructured(
        prompt: "\(base)\n\nFile content:\n\(codeContext)",
        system: "Specify exact text to find and its replacement. Find text must match the file exactly.",
        as: EditParams.self
      )
      return .edit(path: p.filePath, find: p.find, replace: p.replace)

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
    return try await adapter.generateStructured(
      prompt: prompt, system: Prompts.reflectSystem, as: AgentReflection.self
    )
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

    case .write(let path, let content):
      // Permission check
      let decision = permissionService.ask(tool: "write", target: path, detail: "\(content.count) chars")
      guard decision != .deny else { return "DENIED: write to \(path)" }

      // Capture diff
      let existing = try? files.read(path: path, maxTokens: 2000)
      memory.touch(path)
      metrics.filesModified += 1
      try files.write(path: path, content: content)

      let diff = diffPreview.diffWrite(filePath: path, existingContent: existing, newContent: content)
      lastDiffs.append(diff)
      return "Written \(path) (\(content.count) chars)"

    case .edit(let path, let find, let replace):
      let decision = permissionService.ask(tool: "edit", target: path, detail: "replacing \(find.count) chars")
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

      // Capture after + generate diff
      if let before, let _ = try? files.read(path: path, maxTokens: 2000) {
        if let d = diffPreview.diff(filePath: path, originalContent: before, find: find, replace: replace) {
          lastDiffs.append(d)
        }
      }
      return "Edited \(path)"

    case .patch(let path, let diff):
      let decision = permissionService.ask(tool: "edit", target: path, detail: "apply patch")
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
    let outcome = (output.contains("ERROR") || output.contains("DENIED") || output.contains("failed")) ? "error" : "ok"
    let keyFact = lines.first.map(String.init) ?? "no output"
    return StepObservation(tool: tool, outcome: outcome, keyFact: String(keyFact.prefix(120)))
  }

  private func shellEscape(_ s: String) -> String {
    "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
  }

  private func debug(_ message: String) {
    guard verbose else { return }
    FileHandle.standardError.write("[debug] \(message)\n".data(using: .utf8) ?? Data())
  }
}

// MARK: - Types

public struct RunResult: Sendable {
  public let memory: WorkingMemory
  public let reflection: AgentReflection
}

public enum OrchestratorError: Error, Sendable {
  case editFailed(String)
  case toolFailed(String)
}

/// Thread-safe flag for cross-actor communication (FileWatcher → Orchestrator).
public final class ReindexFlag: @unchecked Sendable {
  private let lock = NSLock()
  private var value = false

  func set() { lock.withLock { value = true } }
  func consume() -> Bool { lock.withLock { let v = value; value = false; return v } }
}

public struct SessionMetrics: Sendable {
  public var tasksCompleted: Int = 0
  public var totalTokensUsed: Int = 0
  public var totalLLMCalls: Int = 0
  public var filesModified: Int = 0
  public var bashCommandsRun: Int = 0
  public var mlClassifications: Int = 0
}
