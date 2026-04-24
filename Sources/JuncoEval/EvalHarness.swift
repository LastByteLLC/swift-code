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
  /// Cosine similarity (0…1) between answer and canonical reference, or nil if no reference defined.
  let referenceSimilarity: Double?
  /// True when every .swift file the case generated or modified compiles under
  /// `swiftc -typecheck`. Nil when the case produced no .swift files.
  let generatedCodeCompiles: Bool?
  /// First compiler error message captured from any generated .swift file (or nil).
  let generatedCodeError: String?
}

// MARK: - Splits

/// Eval-set membership for each case. Default is "search" (the primary iteration set).
/// Unlisted cases fall into the default. Overrides live in EvalHarness.splits.
enum EvalSplit: String {
  case canary
  case search
  case holdout
  case holdoutFinal = "holdout-final"
}

// MARK: - Harness

struct EvalHarness {
  let workingDirectory: String
  let verbose: Bool

  /// Canonical-answer scorer, populated once from fixtures/reference_answers.json.
  var referenceScorer: ReferenceScorer { ReferenceScorer(workingDirectory: workingDirectory) }

  // MARK: - Splits

  /// Cases explicitly tagged to a non-default split. Others default to `.search`.
  /// Canary: ~4 fast/trivial gates that must pass every iteration.
  /// Holdout: reserved for candidate promotion; not used during iteration.
  /// Holdout-final: scored once at end-of-experiment, never during iteration.
  static let splits: [String: EvalSplit] = [
    // Canary (4) — fast gate
    "search-mode-enum": .canary,
    "search-file-count": .canary,
    "search-identifier-orchestrator": .canary,
    "explain-pipeline": .canary,

    // Holdout (10) — promotion check
    "plan-add-feature": .holdout,
    "search-static-property": .holdout,
    "search-init-declarations": .holdout,
    "search-enum-cases": .holdout,
    "search-depends-on-config": .holdout,
    "search-depends-on-safeshell": .holdout,
    "search-cross-file-usage": .holdout,
    "search-adversarial-build": .holdout,
    "search-adversarial-fix": .holdout,
    "search-test-suites": .holdout,

    // Holdout-final (9) — reserved, scored once
    "search-entry-point": .holdoutFinal,
    "search-error-types": .holdoutFinal,
    "search-typealias": .holdoutFinal,
    "search-tree-sitter-integration": .holdoutFinal,
    "search-extension-conformance": .holdoutFinal,
    "search-symbol-index-users": .holdoutFinal,
    "search-afm-adapter-callers": .holdoutFinal,
    "search-pipeline-callbacks": .holdoutFinal,
    "fix-injected-typo": .holdoutFinal
  ]

  static func split(for name: String) -> EvalSplit {
    splits[name] ?? .search
  }

  // MARK: - Test Cases

  static let nonDestructiveCases: [EvalCase] = [
    EvalCase(
      name: "search-build-target",
      query: "Where is the build target defined?",
      referencedFiles: [],
      expectedMode: .answer,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should mention Package.swift",
        "Should list target names (junco, JuncoKit, JuncoEval)",
        "Should reference specific lines or the targets array"
      ]
    ),
    EvalCase(
      name: "search-entry-point",
      query: "What is the main entry point of this app?",
      referencedFiles: [],
      expectedMode: .answer,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should find Sources/junco/Junco.swift",
        "Should mention @main or the Junco struct"
      ]
    ),
    EvalCase(
      name: "search-mode-enum",
      query: "Where is AgentMode defined?",
      referencedFiles: [],
      expectedMode: .answer,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should find GenerableTypes.swift",
        "Should list cases: build, answer"
      ]
    ),
    EvalCase(
      name: "search-how-tests",
      query: "How do tests run in this project?",
      referencedFiles: [],
      expectedMode: .answer,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should mention swift test",
        "Should reference Tests/JuncoTests/",
        "Should mention Swift Testing framework or @Test"
      ]
    ),
    EvalCase(
      name: "plan-add-feature",
      query: "Plan how to add a /history command that shows past queries",
      referencedFiles: [],
      expectedMode: .answer,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should produce a multi-phase plan",
        "Should identify files to modify (Junco.swift, CommandHistory.swift)",
        "Should describe what the command does"
      ]
    ),
    EvalCase(
      name: "plan-refactor",
      query: "Plan a refactor of the Orchestrator to reduce its size",
      referencedFiles: [],
      expectedMode: .answer,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should identify large sections that can be extracted",
        "Should suggest new files or types",
        "Should mention risks of the refactor"
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
        "Should reference the Orchestrator"
      ]
    ),
    EvalCase(
      name: "search-file-count",
      query: "How many Swift source files are in this project?",
      referencedFiles: [],
      expectedMode: .answer,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should give a concrete number",
        "Should mention Sources/ directory"
      ]
    ),

    // --- Identifier queries (deterministic search should nail these) ---

    EvalCase(
      name: "search-identifier-orchestrator",
      query: "Where is the Orchestrator class defined?",
      referencedFiles: [],
      expectedMode: .answer,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should find Sources/JuncoKit/Agent/Orchestrator.swift",
        "Should show the actor declaration"
      ]
    ),
    EvalCase(
      name: "search-identifier-tokenbudget",
      query: "Where is TokenBudget defined?",
      referencedFiles: [],
      expectedMode: .answer,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should find Sources/JuncoKit/Models/TokenBudget.swift",
        "Should show the enum declaration"
      ]
    ),
    EvalCase(
      name: "search-identifier-safeshell",
      query: "Find SafeShell",
      referencedFiles: [],
      expectedMode: .answer,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should find Sources/JuncoKit/Tools/SafeShell.swift"
      ]
    ),

    // --- Concept queries (need LLM fallback) ---

    EvalCase(
      name: "search-concept-entry-point",
      query: "What is the main entry point of this app?",
      referencedFiles: [],
      expectedMode: .answer,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should find Sources/junco/Junco.swift",
        "Should mention @main or the Junco struct"
      ]
    ),
    EvalCase(
      name: "search-concept-dependencies",
      query: "What external dependencies does this project use?",
      referencedFiles: [],
      expectedMode: .answer,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should mention swift-argument-parser",
        "Should reference Package.swift"
      ]
    ),

    // --- Adversarial mode detection ---

    EvalCase(
      name: "search-adversarial-build",
      query: "Where is the build verification logic?",
      referencedFiles: [],
      expectedMode: .answer,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should be classified as search, not build",
        "Should find BuildRunner.swift"
      ]
    ),
    EvalCase(
      name: "search-adversarial-fix",
      query: "Where are validation errors fixed in the pipeline?",
      referencedFiles: [],
      expectedMode: .answer,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should be classified as search, not build",
        "Should find validateAndFix or validation retry logic"
      ]
    ),

    // --- Counting ---

    EvalCase(
      name: "search-count-tests",
      query: "How many test cases are there?",
      referencedFiles: [],
      expectedMode: .answer,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should give a concrete number",
        "Should mention @Test or Tests/ directory"
      ]
    ),

    // --- Function signature / parameter queries ---

    EvalCase(
      name: "search-func-signature",
      query: "What parameters does the compress function in ProgressiveCompressor take?",
      referencedFiles: [],
      expectedMode: .answer,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should find ProgressiveCompressor.swift",
        "Should show func compress(code: String, target: Int)"
      ]
    ),

    // --- Relationship / reference queries ---

    EvalCase(
      name: "search-imports",
      query: "What files import FoundationModels?",
      referencedFiles: [],
      expectedMode: .answer,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should find AFMAdapter.swift",
        "Should find TokenBudget.swift",
        "Should find GenerableTypes.swift"
      ]
    ),

    // --- Project structure ---

    EvalCase(
      name: "search-project-layers",
      query: "What directories make up the project structure?",
      referencedFiles: [],
      expectedMode: .answer,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should mention Sources/JuncoKit/Agent, Models, LLM, Tools, RAG, TUI",
        "Should mention Tests/JuncoTests"
      ]
    ),

    // --- Protocol / conformance ---

    EvalCase(
      name: "search-protocol-conformance",
      query: "What types conform to CompletionProvider?",
      referencedFiles: [],
      expectedMode: .answer,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should find FileCompleter",
        "Should find CommandCompleter"
      ]
    ),

    // --- Config value lookup ---

    EvalCase(
      name: "search-config-value",
      query: "What is the default bash timeout?",
      referencedFiles: [],
      expectedMode: .answer,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should find Config.swift",
        "Should show bashTimeout = 30"
      ]
    ),

    // --- Error handling / concept ---

    EvalCase(
      name: "search-error-types",
      query: "What error types does the pipeline use?",
      referencedFiles: [],
      expectedMode: .answer,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should find PipelineError enum",
        "Should find LLMError enum",
        "Should list cases like contextOverflow, deserializationFailed"
      ]
    ),

    // --- Test suite discovery ---

    EvalCase(
      name: "search-test-suites",
      query: "What test suites exist in this project?",
      referencedFiles: [],
      expectedMode: .answer,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should list multiple @Suite names",
        "Should mention TokenBudget, LineEditor, ProgressiveCompressor etc."
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
        "Should reference ThinkingPhrases"
      ]
    ),

    // --- Complex plan ---

    EvalCase(
      name: "plan-new-mode",
      query: "Plan adding a Debug mode that shows token usage per LLM call in real time",
      referencedFiles: [],
      expectedMode: .answer,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should reference AgentMode enum in GenerableTypes.swift",
        "Should mention Orchestrator.swift for mode dispatch",
        "Should suggest adding a case to AgentMode",
        "Should mention Spinner or ActionLog for real-time display"
      ]
    ),

    // --- Count variant ---

    EvalCase(
      name: "search-count-types",
      query: "How many structs and enums are defined in this project?",
      referencedFiles: [],
      expectedMode: .answer,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should give concrete numbers",
        "Should distinguish structs from enums"
      ]
    ),

    // --- Multi-concept search ---

    EvalCase(
      name: "search-multi-concept",
      query: "What connects the Spinner to the Orchestrator?",
      referencedFiles: [],
      expectedMode: .answer,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should mention PipelineCallbacks or the onProgress callback",
        "Should reference Junco.swift where they're wired together"
      ]
    ),

    // --- Tree-sitter symbol extraction validation ---

    EvalCase(
      name: "search-nested-type",
      query: "Where is SymbolKind defined?",
      referencedFiles: [],
      expectedMode: .answer,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should find FileIndexer.swift (nested enum inside IndexEntry)",
        "Should list cases: function, type, property, import, file"
      ]
    ),
    EvalCase(
      name: "search-extension-conformance",
      query: "What extensions add Codable conformance?",
      referencedFiles: [],
      expectedMode: .answer,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should find extensions with Codable in the symbol name",
        "Should reference GenerableTypes.swift or other files with Codable extensions"
      ]
    ),
    EvalCase(
      name: "search-init-declarations",
      query: "Where is the Orchestrator initializer defined?",
      referencedFiles: [],
      expectedMode: .answer,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should find Orchestrator.swift",
        "Should show init parameters (adapter, workingDirectory)"
      ]
    ),
    EvalCase(
      name: "search-enum-cases",
      query: "What are the cases of PipelineError?",
      referencedFiles: [],
      expectedMode: .answer,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should find GenerableTypes.swift",
        "Should list cases like contextOverflow, deserializationFailed, toolFailed"
      ]
    ),
    EvalCase(
      name: "search-typealias",
      query: "Are there any typealiases in this project?",
      referencedFiles: [],
      expectedMode: .answer,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should find any typealias declarations extracted by tree-sitter",
        "Should give concrete names and locations"
      ]
    ),

    // --- Reference graph / cross-file dependency queries ---

    EvalCase(
      name: "search-depends-on-config",
      query: "What files use Config?",
      referencedFiles: [],
      expectedMode: .answer,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should find multiple files that reference Config",
        "Should include Orchestrator.swift or FileIndexer.swift",
        "Reference graph boost should surface related files"
      ]
    ),
    EvalCase(
      name: "search-depends-on-safeshell",
      query: "What files depend on SafeShell?",
      referencedFiles: [],
      expectedMode: .answer,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should find SafeShell.swift definition",
        "Should find files that use SafeShell (Orchestrator, BuildRunner, etc.)"
      ]
    ),
    EvalCase(
      name: "search-cross-file-usage",
      query: "Where is IndexEntry used outside of FileIndexer?",
      referencedFiles: [],
      expectedMode: .answer,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should find SymbolIndex.swift, ContextPacker.swift, or Orchestrator.swift",
        "Should show how IndexEntry is consumed, not just defined"
      ]
    ),
    EvalCase(
      name: "search-symbol-index-users",
      query: "What files use SymbolIndex?",
      referencedFiles: [],
      expectedMode: .answer,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should find Orchestrator.swift",
        "Should find ReferenceGraph.swift",
        "Should distinguish definition from usage"
      ]
    ),

    // --- Queries that benefit from combined tree-sitter + reference graph ---

    EvalCase(
      name: "search-afm-adapter-callers",
      query: "What code calls AFMAdapter?",
      referencedFiles: [],
      expectedMode: .answer,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should find Orchestrator.swift as primary consumer",
        "Should find EvalHarness.swift or Junco.swift where it's instantiated"
      ]
    ),
    EvalCase(
      name: "search-pipeline-callbacks",
      query: "Where are PipelineCallbacks created and consumed?",
      referencedFiles: [],
      expectedMode: .answer,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should find PipelineCallbacks.swift (definition)",
        "Should find Junco.swift or EvalHarness.swift (creation)",
        "Should find Orchestrator.swift (consumption via run())"
      ]
    ),
    EvalCase(
      name: "search-tree-sitter-integration",
      query: "How does tree-sitter integrate with the indexing pipeline?",
      referencedFiles: [],
      expectedMode: .answer,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should find TreeSitterExtractor.swift",
        "Should find FileIndexer.swift where tree-sitter is called",
        "Should mention the fallback to regex extraction"
      ]
    ),
    EvalCase(
      name: "search-reference-graph-build",
      query: "How is the reference graph built?",
      referencedFiles: [],
      expectedMode: .answer,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should find ReferenceGraph.swift",
        "Should mention SymbolIndex and TreeSitterExtractor as inputs",
        "Should describe the build() method"
      ]
    ),

    // --- Property-level queries (tree-sitter depth handling) ---

    EvalCase(
      name: "search-property-lookup",
      query: "Where is bashTimeout defined?",
      referencedFiles: [],
      expectedMode: .answer,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should find Config.swift",
        "Should show the property declaration with its value"
      ]
    ),
    EvalCase(
      name: "search-static-property",
      query: "Where is the empty reference graph defined?",
      referencedFiles: [],
      expectedMode: .answer,
      destructive: false,
      setup: nil,
      qualityCriteria: [
        "Should find ReferenceGraph.swift",
        "Should show static let empty = ReferenceGraph(...)"
      ]
    )
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
        "File should be syntactically valid"
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
        "New section should have useful content"
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
        "Should not make other changes"
      ]
    )
  ]

  // MARK: - Run

  func run(
    caseFilter: String? = nil,
    includeDestructive: Bool = false,
    reportPath: String? = nil,
    splitFilter: EvalSplit? = nil
  ) async -> String {
    // EvalHarness runs under `swift run junco-eval`, which holds the SPM .build/ lock.
    // Any buildAndFix call inside the Orchestrator would deadlock on it. Signal the
    // Orchestrator to skip that stage.
    setenv("JUNCO_SKIP_BUILD_FIX", "1", 1)
    let adapter = AFMAdapter()

    var cases = Self.nonDestructiveCases
    if includeDestructive {
      cases += Self.destructiveCases
    }

    if let filter = caseFilter {
      cases = cases.filter { $0.name.contains(filter) }
    }
    if let split = splitFilter {
      cases = cases.filter { Self.split(for: $0.name) == split }
    }

    print("Junco Self-Evaluation: \(cases.count) case(s)\n")

    let traceDir = ProcessInfo.processInfo.environment["JUNCO_TRACE_DIR"]
    let effectiveAdapter: any LLMAdapter = traceDir != nil ? TracingLLMAdapter(wrapping: adapter) : adapter
    if let traceDir {
      try? FileManager.default.createDirectory(atPath: traceDir, withIntermediateDirectories: true)
      print("Trace dir: \(traceDir)")
    }

    // Build ONE Orchestrator up-front and reuse it across cases. Every case previously
    // paid the full cost of FileIndexer + ReferenceGraph + ProjectAnalyzer (~3-5s on this
    // repo), which dominated `--split search` wall-clock on deterministic cases with 0 LLM
    // calls. Orchestrator.run() already creates a fresh WorkingMemory per call, so the
    // cross-case state is limited to the project index / snapshot / reference graph —
    // all of which are project-wide and SHOULD be shared.
    let orchestrator = Orchestrator(adapter: effectiveAdapter, workingDirectory: workingDirectory)
    if verbose { await orchestrator.setVerbose(true) }

    var results: [EvalResult] = []

    for (i, evalCase) in cases.enumerated() {
      print("[\(i + 1)/\(cases.count)] \(evalCase.name)...", terminator: "")
      fflush(stdout)

      let sink: JSONLTraceSink? = traceDir.flatMap {
        try? JSONLTraceSink(url: URL(fileURLWithPath: $0).appendingPathComponent("\(evalCase.name).trace.jsonl"))
      }

      let result: EvalResult = await TraceContext.$sink.withValue(sink) {
        if evalCase.destructive {
          return await runDestructive(evalCase, orchestrator: orchestrator)
        } else {
          return await runCase(evalCase, orchestrator: orchestrator)
        }
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

    // Emit structured summary JSON for meta-harness consumption
    if let summaryPath = ProcessInfo.processInfo.environment["JUNCO_SUMMARY_JSON"] {
      writeSummaryJSON(results: results, path: summaryPath, splitFilter: splitFilter)
    }

    return report
  }

  /// Emit per-case + aggregate JSON for programmatic consumption (e.g. junco-meta).
  private func writeSummaryJSON(results: [EvalResult], path: String, splitFilter: EvalSplit?) {
    struct CaseSummary: Encodable {
      let name: String
      let split: String
      let mode: String
      let modeCorrect: Bool?
      let succeeded: Bool
      let llmCalls: Int
      let tokensUsed: Int
      let durationSeconds: Double
      let filesModified: [String]
      let answerPreview: String
      let errors: [String]
      let referenceSimilarity: Double?
      let generatedCodeCompiles: Bool?
      let generatedCodeError: String?
    }
    struct Summary: Encodable {
      let splitFilter: String?
      let caseCount: Int
      let succeeded: Int
      let failed: Int
      let successRate: Double
      let modeCorrectCount: Int
      let modeExpectedCount: Int
      let totalLlmCalls: Int
      let totalTokens: Int
      let totalDurationSec: Double
      let meanDurationSec: Double
      let medianDurationSec: Double
      let p90DurationSec: Double
      let referenceScoredCount: Int
      let meanReferenceSimilarity: Double?
      let minReferenceSimilarity: Double?
      let codeGenCaseCount: Int
      let codeGenCompileRate: Double?
      let cases: [CaseSummary]
    }
    let perCase = results.map {
      CaseSummary(
        name: $0.caseName,
        split: Self.split(for: $0.caseName).rawValue,
        mode: $0.mode.rawValue,
        modeCorrect: $0.modeCorrect,
        succeeded: $0.succeeded,
        llmCalls: $0.llmCalls,
        tokensUsed: $0.tokensUsed,
        durationSeconds: $0.durationSeconds,
        filesModified: $0.filesModified,
        answerPreview: String($0.answer.prefix(400)),
        errors: $0.errors,
        referenceSimilarity: $0.referenceSimilarity,
        generatedCodeCompiles: $0.generatedCodeCompiles,
        generatedCodeError: $0.generatedCodeError
      )
    }
    let durations = results.map { $0.durationSeconds }
    let sorted = durations.sorted()
    let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
    let p90 = sorted.isEmpty ? 0 : sorted[min(sorted.count - 1, Int(Double(sorted.count) * 0.9))]
    let expected = results.filter { $0.modeCorrect != nil }
    let refSims = results.compactMap { $0.referenceSimilarity }
    let meanRef = refSims.isEmpty ? nil : refSims.reduce(0, +) / Double(refSims.count)
    let minRef = refSims.min()
    let codeGenResults = results.compactMap { $0.generatedCodeCompiles }
    let codeGenRate: Double? = codeGenResults.isEmpty
      ? nil
      : Double(codeGenResults.filter { $0 }.count) / Double(codeGenResults.count)
    let summary = Summary(
      splitFilter: splitFilter?.rawValue,
      caseCount: results.count,
      succeeded: results.filter { $0.succeeded }.count,
      failed: results.filter { !$0.succeeded }.count,
      successRate: results.isEmpty ? 0 : Double(results.filter { $0.succeeded }.count) / Double(results.count),
      modeCorrectCount: expected.filter { $0.modeCorrect == true }.count,
      modeExpectedCount: expected.count,
      totalLlmCalls: results.map(\.llmCalls).reduce(0, +),
      totalTokens: results.map(\.tokensUsed).reduce(0, +),
      totalDurationSec: durations.reduce(0, +),
      meanDurationSec: durations.isEmpty ? 0 : durations.reduce(0, +) / Double(durations.count),
      medianDurationSec: median,
      p90DurationSec: p90,
      referenceScoredCount: refSims.count,
      meanReferenceSimilarity: meanRef,
      minReferenceSimilarity: minRef,
      codeGenCaseCount: codeGenResults.count,
      codeGenCompileRate: codeGenRate,
      cases: perCase
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(summary) else { return }
    let dirPath = (path as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dirPath, withIntermediateDirectories: true)
    try? data.write(to: URL(fileURLWithPath: path))
    print("Summary JSON: \(path)")
  }

  // MARK: - Run Single Case

  private func runCase(_ evalCase: EvalCase, orchestrator: Orchestrator) async -> EvalResult {
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

      let similarity = referenceScorer.score(caseName: evalCase.name, answer: result.reflection.insight)
      let modified = Array(result.memory.touchedFiles)
      let (codeCompiles, codeError) = validateGeneratedSwift(paths: modified)
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
        filesModified: modified,
        durationSeconds: duration,
        qualityCriteria: evalCase.qualityCriteria,
        modeCorrect: evalCase.expectedMode.map { $0 == capturedMode },
        referenceSimilarity: similarity,
        generatedCodeCompiles: codeCompiles,
        generatedCodeError: codeError
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
        modeCorrect: evalCase.expectedMode.map { $0 == capturedMode },
        referenceSimilarity: nil,
        generatedCodeCompiles: nil,
        generatedCodeError: nil
      )
    }
  }

  /// Validate every .swift file in `paths` with SwiftValidator. Returns:
  /// - (nil, nil) if no .swift files modified
  /// - (true, nil) if every Swift file compiles cleanly
  /// - (false, firstError) if at least one Swift file fails
  private func validateGeneratedSwift(paths: [String]) -> (Bool?, String?) {
    let swiftFiles = paths.filter { $0.hasSuffix(".swift") }
    guard !swiftFiles.isEmpty else { return (nil, nil) }
    let registry = ValidatorRegistry.default()
    var firstError: String?
    for relPath in swiftFiles {
      let absPath = relPath.hasPrefix("/")
        ? relPath
        : (workingDirectory as NSString).appendingPathComponent(relPath)
      guard let content = try? String(contentsOfFile: absPath, encoding: .utf8) else { continue }
      if let error = registry.validate(code: content, filePath: absPath) {
        firstError = firstError ?? "\(relPath): \(String(error.prefix(200)))"
      }
    }
    return (firstError == nil, firstError)
  }

  // MARK: - Destructive Test (Git Checkpoint + Rewind)

  private func runDestructive(_ evalCase: EvalCase, orchestrator: Orchestrator) async -> EvalResult {
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
    let result = await runCase(evalCase, orchestrator: orchestrator)

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
