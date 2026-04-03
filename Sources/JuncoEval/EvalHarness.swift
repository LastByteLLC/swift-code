// EvalHarness.swift — Self-evaluation harness for Junco
//
// Runs real queries against the live codebase using the on-device model,
// captures the full action log and answer, and generates a structured
// markdown report for quality evaluation.
//
// Non-destructive tests (search, plan, explain) run directly.
// Destructive tests (create, edit) use git checkpointing to rewind.

import Foundation
import os
import JuncoKit

// MARK: - Test Case Definition

struct EvalCase: Sendable {
  let name: String
  let query: String
  let referencedFiles: [String]
  let expectedMode: AgentMode?
  let destructive: Bool
  let setup: String?           // Shell command to run before test (e.g., inject typo)
  let qualityCriteria: [String]
}

// MARK: - Captured Result

struct EvalResult: Sendable {
  let caseName: String
  let query: String
  let mode: AgentMode
  let answer: String
  let actionLog: [(tool: String, target: String, output: String)]
  let planSteps: [(instruction: String, tool: String, target: String)]
  let errors: [String]
  let succeeded: Bool
  let llmCalls: Int
  let tokensUsed: Int
  let filesModified: [String]
  let durationSeconds: Double
  let qualityCriteria: [String]
  let modeCorrect: Bool?       // nil if no expected mode
}

// MARK: - Harness

struct EvalHarness {
  let workingDirectory: String
  let verbose: Bool

  // MARK: - Test Cases

  static let nonDestructiveCases: [EvalCase] = [
    EvalCase(
      name: "search-build-target",
      query: "Where is the build target defined?",
      referencedFiles: [],
      expectedMode: .search,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should mention Package.swift",
        "Should list target names (junco, JuncoKit, JuncoEval)",
        "Should reference specific lines or the targets array",
      ]
    ),
    EvalCase(
      name: "search-entry-point",
      query: "What is the main entry point of this app?",
      referencedFiles: [],
      expectedMode: .search,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should find Sources/junco/Junco.swift",
        "Should mention @main or the Junco struct",
      ]
    ),
    EvalCase(
      name: "search-mode-enum",
      query: "Where is AgentMode defined?",
      referencedFiles: [],
      expectedMode: .search,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should find GenerableTypes.swift",
        "Should list cases: build, search, plan, research",
      ]
    ),
    EvalCase(
      name: "search-how-tests",
      query: "How do tests run in this project?",
      referencedFiles: [],
      expectedMode: .search,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should mention swift test",
        "Should reference Tests/JuncoTests/",
        "Should mention Swift Testing framework or @Test",
      ]
    ),
    EvalCase(
      name: "plan-add-feature",
      query: "Plan how to add a /history command that shows past queries",
      referencedFiles: [],
      expectedMode: .plan,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should produce a multi-phase plan",
        "Should identify files to modify (Junco.swift, CommandHistory.swift)",
        "Should describe what the command does",
      ]
    ),
    EvalCase(
      name: "plan-refactor",
      query: "Plan a refactor of the Orchestrator to reduce its size",
      referencedFiles: [],
      expectedMode: .plan,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should identify large sections that can be extracted",
        "Should suggest new files or types",
        "Should mention risks of the refactor",
      ]
    ),
    EvalCase(
      name: "explain-pipeline",
      query: "Explain how a user query flows through the agent pipeline",
      referencedFiles: [],
      expectedMode: nil,  // Could be search or build
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should describe classify → strategy → plan → execute → reflect",
        "Should mention modes (build, search, plan, research)",
        "Should reference the Orchestrator",
      ]
    ),
    EvalCase(
      name: "search-file-count",
      query: "How many Swift source files are in this project?",
      referencedFiles: [],
      expectedMode: .search,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should give a concrete number",
        "Should mention Sources/ directory",
      ]
    ),

    // --- Identifier queries (deterministic search should nail these) ---

    EvalCase(
      name: "search-identifier-orchestrator",
      query: "Where is the Orchestrator class defined?",
      referencedFiles: [],
      expectedMode: .search,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should find Sources/JuncoKit/Agent/Orchestrator.swift",
        "Should show the actor declaration",
      ]
    ),
    EvalCase(
      name: "search-identifier-tokenbudget",
      query: "Where is TokenBudget defined?",
      referencedFiles: [],
      expectedMode: .search,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should find Sources/JuncoKit/Models/TokenBudget.swift",
        "Should show the enum declaration",
      ]
    ),
    EvalCase(
      name: "search-identifier-safeshell",
      query: "Find SafeShell",
      referencedFiles: [],
      expectedMode: .search,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should find Sources/JuncoKit/Tools/SafeShell.swift",
      ]
    ),

    // --- Concept queries (need LLM fallback) ---

    EvalCase(
      name: "search-concept-entry-point",
      query: "What is the main entry point of this app?",
      referencedFiles: [],
      expectedMode: .search,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should find Sources/junco/Junco.swift",
        "Should mention @main or the Junco struct",
      ]
    ),
    EvalCase(
      name: "search-concept-dependencies",
      query: "What external dependencies does this project use?",
      referencedFiles: [],
      expectedMode: .search,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should mention swift-argument-parser",
        "Should reference Package.swift",
      ]
    ),

    // --- Adversarial mode detection ---

    EvalCase(
      name: "search-adversarial-build",
      query: "Where is the build verification logic?",
      referencedFiles: [],
      expectedMode: .search,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should be classified as search, not build",
        "Should find BuildRunner.swift",
      ]
    ),
    EvalCase(
      name: "search-adversarial-fix",
      query: "Where are validation errors fixed in the pipeline?",
      referencedFiles: [],
      expectedMode: .search,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should be classified as search, not build",
        "Should find validateAndFix or validation retry logic",
      ]
    ),

    // --- Counting ---

    EvalCase(
      name: "search-count-tests",
      query: "How many test cases are there?",
      referencedFiles: [],
      expectedMode: .search,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should give a concrete number",
        "Should mention @Test or Tests/ directory",
      ]
    ),

    // --- Function signature / parameter queries ---

    EvalCase(
      name: "search-func-signature",
      query: "What parameters does the compress function in ProgressiveCompressor take?",
      referencedFiles: [],
      expectedMode: .search,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should find ProgressiveCompressor.swift",
        "Should show func compress(code: String, target: Int)",
      ]
    ),

    // --- Relationship / reference queries ---

    EvalCase(
      name: "search-imports",
      query: "What files import FoundationModels?",
      referencedFiles: [],
      expectedMode: .search,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should find AFMAdapter.swift",
        "Should find TokenBudget.swift",
        "Should find GenerableTypes.swift",
      ]
    ),

    // --- Project structure ---

    EvalCase(
      name: "search-project-layers",
      query: "What directories make up the project structure?",
      referencedFiles: [],
      expectedMode: .search,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should mention Sources/JuncoKit/Agent, Models, LLM, Tools, RAG, TUI",
        "Should mention Tests/JuncoTests",
      ]
    ),

    // --- Protocol / conformance ---

    EvalCase(
      name: "search-protocol-conformance",
      query: "What types conform to CompletionProvider?",
      referencedFiles: [],
      expectedMode: .search,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should find FileCompleter",
        "Should find CommandCompleter",
      ]
    ),

    // --- Config value lookup ---

    EvalCase(
      name: "search-config-value",
      query: "What is the default bash timeout?",
      referencedFiles: [],
      expectedMode: .search,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should find Config.swift",
        "Should show bashTimeout = 30",
      ]
    ),

    // --- Error handling / concept ---

    EvalCase(
      name: "search-error-types",
      query: "What error types does the pipeline use?",
      referencedFiles: [],
      expectedMode: .search,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should find PipelineError enum",
        "Should find LLMError enum",
        "Should list cases like contextOverflow, deserializationFailed",
      ]
    ),

    // --- Test suite discovery ---

    EvalCase(
      name: "search-test-suites",
      query: "What test suites exist in this project?",
      referencedFiles: [],
      expectedMode: .search,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should list multiple @Suite names",
        "Should mention TokenBudget, LineEditor, ProgressiveCompressor etc.",
      ]
    ),

    // --- Explain with @-file (build mode with explicit context) ---

    EvalCase(
      name: "explain-spinner-file",
      query: "Explain how this spinner works",
      referencedFiles: ["Sources/JuncoKit/TUI/Spinner.swift"],
      expectedMode: nil,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should describe the actor-based animation loop",
        "Should mention phrase rotation and mode icons",
        "Should reference ThinkingPhrases",
      ]
    ),

    // --- Complex plan ---

    EvalCase(
      name: "plan-new-mode",
      query: "Plan adding a Debug mode that shows token usage per LLM call in real time",
      referencedFiles: [],
      expectedMode: .plan,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should reference AgentMode enum in GenerableTypes.swift",
        "Should mention Orchestrator.swift for mode dispatch",
        "Should suggest adding a case to AgentMode",
        "Should mention Spinner or ActionLog for real-time display",
      ]
    ),

    // --- Count variant ---

    EvalCase(
      name: "search-count-types",
      query: "How many structs and enums are defined in this project?",
      referencedFiles: [],
      expectedMode: .search,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should give concrete numbers",
        "Should distinguish structs from enums",
      ]
    ),

    // --- Multi-concept search ---

    EvalCase(
      name: "search-multi-concept",
      query: "What connects the Spinner to the Orchestrator?",
      referencedFiles: [],
      expectedMode: .search,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should mention PipelineCallbacks or the onProgress callback",
        "Should reference Junco.swift where they're wired together",
      ]
    ),
  ]

  static let destructiveCases: [EvalCase] = [
    EvalCase(
      name: "create-hello",
      query: "Create a hello world Swift file at Sources/Hello.swift",
      referencedFiles: [],
      expectedMode: .build,
      destructive: true,
      setup: nil,
      qualityCriteria: [
        "Should create Sources/Hello.swift",
        "Should contain valid Swift with print(\"Hello\")",
        "File should be syntactically valid",
      ]
    ),
    EvalCase(
      name: "edit-readme",
      query: "Add a 'Contributing' section to README.md with basic guidelines",
      referencedFiles: ["README.md"],
      expectedMode: .build,
      destructive: true,
      setup: nil,
      qualityCriteria: [
        "Should add a ## Contributing section",
        "Should preserve existing README content",
        "New section should have useful content",
      ]
    ),
    EvalCase(
      name: "fix-injected-typo",
      query: "Fix the typo in Sources/JuncoKit/TUI/Terminal.swift",
      referencedFiles: ["Sources/JuncoKit/TUI/Terminal.swift"],
      expectedMode: .build,
      destructive: true,
      setup: "sed -i '' 's/terminal/termnial/g' Sources/JuncoKit/TUI/Terminal.swift",
      qualityCriteria: [
        "Should find and fix 'termnial' → 'terminal'",
        "Should not make other changes",
      ]
    ),
  ]

  // MARK: - Run

  func run(
    caseFilter: String? = nil,
    includeDestructive: Bool = false,
    reportPath: String? = nil
  ) async -> String {
    let adapter = AFMAdapter()
    var cases = Self.nonDestructiveCases
    if includeDestructive {
      cases += Self.destructiveCases
    }

    if let filter = caseFilter {
      cases = cases.filter { $0.name.contains(filter) }
    }

    print("Junco Self-Evaluation: \(cases.count) case(s)\n")

    var results: [EvalResult] = []

    for (i, evalCase) in cases.enumerated() {
      print("[\(i + 1)/\(cases.count)] \(evalCase.name)...", terminator: "")
      fflush(stdout)

      let result: EvalResult
      if evalCase.destructive {
        result = await runDestructive(evalCase, adapter: adapter)
      } else {
        result = await runCase(evalCase, adapter: adapter)
      }

      results.append(result)

      let icon = result.succeeded ? "✓" : "✗"
      let modeIcon = result.mode.icon
      let modeMatch = result.modeCorrect.map { $0 ? "" : " [mode mismatch]" } ?? ""
      print(" \(icon) \(modeIcon) \(String(format: "%.1fs", result.durationSeconds)) \(result.llmCalls) calls\(modeMatch)")
    }

    let report = generateReport(results: results)

    // Write report
    let outputPath = reportPath ?? (workingDirectory as NSString)
      .appendingPathComponent(".junco/eval-report.md")
    let dir = (outputPath as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try? report.write(toFile: outputPath, atomically: true, encoding: .utf8)
    print("\nReport written to \(outputPath)")

    return report
  }

  // MARK: - Run Single Case

  private func runCase(_ evalCase: EvalCase, adapter: AFMAdapter) async -> EvalResult {
    let orchestrator = Orchestrator(adapter: adapter, workingDirectory: workingDirectory)
    if verbose { await orchestrator.setVerbose(true) }

    let parser = InputParser(workingDirectory: workingDirectory)
    let parsed = parser.parse(evalCase.query)
    let refs = evalCase.referencedFiles.isEmpty ? parsed.referencedFiles : evalCase.referencedFiles

    // Thread-safe capturing via locks
    let logLock = OSAllocatedUnfairLock(initialState: [(tool: String, target: String, output: String)]())
    let modeLock = OSAllocatedUnfairLock(initialState: AgentMode.build)

    let callbacks = PipelineCallbacks(
      onMode: { [modeLock] mode in
        modeLock.withLock { $0 = mode }
      },
      onToolResult: { [logLock] tool, target, output in
        logLock.withLock { $0.append((tool, target, String(output.prefix(500)))) }
      }
    )

    let start = Date()
    do {
      let result = try await orchestrator.run(
        query: parsed.query,
        referencedFiles: refs,
        callbacks: callbacks
      )
      let duration = Date().timeIntervalSince(start)
      let capturedMode = modeLock.withLock { $0 }
      let capturedLog = logLock.withLock { $0 }
      let planSteps = result.memory.plan?.steps.map {
        (instruction: $0.instruction, tool: $0.tool, target: $0.target)
      } ?? []

      return EvalResult(
        caseName: evalCase.name,
        query: evalCase.query,
        mode: capturedMode,
        answer: result.reflection.insight,
        actionLog: capturedLog,
        planSteps: planSteps,
        errors: result.memory.errors,
        succeeded: result.reflection.succeeded,
        llmCalls: result.memory.llmCalls,
        tokensUsed: result.memory.totalTokensUsed,
        filesModified: Array(result.memory.touchedFiles),
        durationSeconds: duration,
        qualityCriteria: evalCase.qualityCriteria,
        modeCorrect: evalCase.expectedMode.map { $0 == capturedMode }
      )
    } catch {
      let capturedMode = modeLock.withLock { $0 }
      let capturedLog = logLock.withLock { $0 }
      return EvalResult(
        caseName: evalCase.name, query: evalCase.query,
        mode: capturedMode, answer: "ERROR: \(error)",
        actionLog: capturedLog, planSteps: [], errors: ["\(error)"],
        succeeded: false, llmCalls: 0, tokensUsed: 0,
        filesModified: [], durationSeconds: Date().timeIntervalSince(start),
        qualityCriteria: evalCase.qualityCriteria,
        modeCorrect: evalCase.expectedMode.map { $0 == capturedMode }
      )
    }
  }

  // MARK: - Destructive Test (Git Checkpoint + Rewind)

  private func runDestructive(_ evalCase: EvalCase, adapter: AFMAdapter) async -> EvalResult {
    let shell = SafeShell(workingDirectory: workingDirectory)

    // Checkpoint: stash any existing changes
    let stashResult = try? await shell.execute(
      "git stash push -m 'junco-eval-checkpoint' --include-untracked 2>/dev/null"
    )
    let hadStash = stashResult?.stdout.contains("Saved") ?? false

    // Run setup command if any (e.g., inject typo)
    if let setup = evalCase.setup {
      _ = try? await shell.execute(setup)
    }

    // Run the test
    let result = await runCase(evalCase, adapter: adapter)

    // Rewind: discard all changes
    _ = try? await shell.execute("git checkout -- . 2>/dev/null")
    _ = try? await shell.execute("git clean -fd 2>/dev/null")

    // Restore stash if we had one
    if hadStash {
      _ = try? await shell.execute("git stash pop --quiet 2>/dev/null")
    }

    return result
  }

  // MARK: - Report Generation

  private func generateReport(results: [EvalResult]) -> String {
    let timestamp = ISO8601DateFormatter().string(from: Date())
    let ft = FileTools(workingDirectory: workingDirectory)
    let fileCount = ft.listFiles().count

    var report = """
    # Junco Self-Evaluation Report
    Generated: \(timestamp)
    Model: Apple Foundation Models (Neural Engine)
    Project: \(workingDirectory.split(separator: "/").last ?? "unknown") (\(fileCount) files, Swift)

    ## Summary
    | # | Case | Mode | Result | Calls | Tokens | Time |
    |---|------|------|--------|-------|--------|------|

    """

    for (i, r) in results.enumerated() {
      let icon = r.succeeded ? "✓" : "✗"
      let modeMatch = r.modeCorrect == false ? " ⚠" : ""
      report += "| \(i + 1) | \(r.caseName) | \(r.mode.icon) \(r.mode.rawValue)\(modeMatch) | \(icon) | \(r.llmCalls) | ~\(r.tokensUsed) | \(String(format: "%.1fs", r.durationSeconds)) |\n"
    }

    let passCount = results.filter(\.succeeded).count
    let modeCorrect = results.compactMap(\.modeCorrect).filter { $0 }.count
    let modeTotal = results.compactMap(\.modeCorrect).count
    report += "\n**\(passCount)/\(results.count) succeeded** | Mode accuracy: \(modeCorrect)/\(modeTotal)\n"

    report += "\n---\n\n## Detailed Results\n"

    for (i, r) in results.enumerated() {
      let icon = r.succeeded ? "✓" : "✗"
      report += """

      ### \(i + 1). \(r.caseName)
      **Query:** \(r.query)
      **Mode:** \(r.mode.icon) \(r.mode.rawValue)\(r.modeCorrect == false ? " ⚠ (expected \(results[i].caseName))" : "")
      **Status:** \(icon) \(r.succeeded ? "succeeded" : "failed")


      """

      if !r.qualityCriteria.isEmpty {
        report += "**Quality criteria:**\n"
        for criterion in r.qualityCriteria {
          report += "- [ ] \(criterion)\n"
        }
        report += "\n"
      }

      if !r.planSteps.isEmpty {
        report += "**Plan (\(r.planSteps.count) steps):**\n"
        for step in r.planSteps {
          report += "- [\(step.tool)] \(step.instruction) → \(step.target)\n"
        }
        report += "\n"
      }

      if !r.actionLog.isEmpty {
        report += "**Action log:**\n```\n"
        for entry in r.actionLog {
          let target = entry.target.isEmpty ? "" : " \(entry.target)"
          report += "⏺ \(entry.tool)\(target)\n"
          if !entry.output.isEmpty {
            let lines = entry.output.components(separatedBy: "\n").prefix(4)
            for line in lines {
              report += "  ⎿ \(line)\n"
            }
            let remaining = entry.output.components(separatedBy: "\n").count - 4
            if remaining > 0 {
              report += "  ⎿ … +\(remaining) lines\n"
            }
          }
        }
        report += "```\n\n"
      }

      report += "**Answer:**\n\(r.answer)\n\n"
      report += "**Metrics:** \(r.llmCalls) calls | ~\(r.tokensUsed) tokens | \(String(format: "%.1fs", r.durationSeconds)) | \(r.filesModified.count) files modified\n"

      if !r.errors.isEmpty {
        report += "**Errors:** \(r.errors.joined(separator: "; "))\n"
      }

      report += "\n---\n"
    }

    return report
  }
}
