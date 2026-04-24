// NonDestructiveChecks.swift — E10: SubChecks keyed by case name for the
// non-destructive eval suite. Avoids cluttering every EvalCase entry with an
// inline `checks:` arg by routing lookups through a dictionary at merge-time.
//
// Cases not in this map contribute 0 sub-checks to the aggregate, so the
// subCheckPassRate metric only reflects cases we've authored checks for.

import Foundation

enum NonDestructiveChecks {

  /// Case-name → sub-check list. Kept pragmatic: 2-4 checks each, spanning
  /// structural (mode), content (mentions, cites), and efficiency (calls, duration)
  /// dimensions. Every answer is expected to route to `.answer` mode.
  static let byCase: [String: [SubCheck]] = [
    // === Canary (fast gate) ===
    "search-mode-enum": [
      SubCheck(kind: "modeIs", expectedMode: "answer"),
      SubCheck(kind: "answerContains", text: "AgentMode"),
      SubCheck(kind: "answerCitesPath"),
      SubCheck(kind: "llmCallsUnder", maxLlmCalls: 3)
    ],
    "search-file-count": [
      SubCheck(kind: "modeIs", expectedMode: "answer"),
      SubCheck(kind: "answerMatches", pattern: #"\b\d{2,}\b"#),   // any 2+ digit number
      SubCheck(kind: "answerContains", text: "Sources")
    ],
    "search-identifier-orchestrator": [
      SubCheck(kind: "modeIs", expectedMode: "answer"),
      SubCheck(kind: "answerContains", text: "Orchestrator.swift"),
      SubCheck(kind: "answerCitesPath")
    ],
    "explain-pipeline": [
      SubCheck(kind: "answerContains", text: "Orchestrator"),
      SubCheck(kind: "answerMentionsAny", anyOf: ["classify", "plan", "execute"]),
      SubCheck(kind: "answerLengthOver", minLength: 120)
    ],

    // === Search / identifier ===
    "search-build-target": [
      SubCheck(kind: "modeIs", expectedMode: "answer"),
      SubCheck(kind: "answerContains", text: "Package.swift"),
      SubCheck(kind: "answerMentionsAny", anyOf: ["junco", "JuncoKit", "JuncoEval", "executableTarget", ".target("])
    ],
    "search-entry-point": [
      SubCheck(kind: "modeIs", expectedMode: "answer"),
      SubCheck(kind: "answerMentionsAny", anyOf: ["@main", "Junco"])
    ],
    "search-how-tests": [
      SubCheck(kind: "modeIs", expectedMode: "answer"),
      SubCheck(kind: "answerContains", text: "swift test"),
      SubCheck(kind: "answerMentionsAny", anyOf: ["Tests/JuncoTests", "@Test", "Swift Testing"])
    ],
    "search-concept-entry-point": [
      SubCheck(kind: "modeIs", expectedMode: "answer"),
      SubCheck(kind: "answerMentionsAny", anyOf: ["@main", "AsyncParsableCommand", "Junco.swift"])
    ],

    // === Plan ===
    "plan-add-feature": [
      SubCheck(kind: "modeIs", expectedMode: "answer"),
      SubCheck(kind: "answerLengthOver", minLength: 200),
      SubCheck(kind: "answerMentionsAny", anyOf: ["Junco.swift", "command", "history"])
    ],
    "plan-refactor": [
      SubCheck(kind: "modeIs", expectedMode: "answer"),
      SubCheck(kind: "answerContains", text: "Orchestrator"),
      SubCheck(kind: "answerLengthOver", minLength: 200),
      SubCheck(kind: "llmCallsUnder", maxLlmCalls: 10)    // catches the historical 24-call blowout
    ],
    "plan-new-mode": [
      SubCheck(kind: "modeIs", expectedMode: "answer"),
      SubCheck(kind: "answerLengthOver", minLength: 150)
    ],

    // === Explain ===
    "explain-spinner-file": [
      SubCheck(kind: "modeIs", expectedMode: "answer"),
      SubCheck(kind: "answerContains", text: "spinner"),
      SubCheck(kind: "answerLengthOver", minLength: 80)
    ],

    // === Identifier / structural search ===
    "search-identifier-tokenbudget": [
      SubCheck(kind: "modeIs", expectedMode: "answer"),
      SubCheck(kind: "answerContains", text: "TokenBudget")
    ],
    "search-identifier-safeshell": [
      SubCheck(kind: "modeIs", expectedMode: "answer"),
      SubCheck(kind: "answerContains", text: "SafeShell")
    ],
    "search-func-signature": [
      SubCheck(kind: "modeIs", expectedMode: "answer"),
      SubCheck(kind: "answerCitesPath")
    ],
    "search-imports": [
      SubCheck(kind: "modeIs", expectedMode: "answer"),
      SubCheck(kind: "answerContains", text: "import")
    ],
    "search-project-layers": [
      SubCheck(kind: "modeIs", expectedMode: "answer"),
      SubCheck(kind: "answerMentionsAny", anyOf: ["JuncoKit", "JuncoEval", "junco"])
    ],
    "search-protocol-conformance": [
      SubCheck(kind: "modeIs", expectedMode: "answer"),
      SubCheck(kind: "answerCitesPath")
    ],
    "search-config-value": [
      SubCheck(kind: "modeIs", expectedMode: "answer"),
      SubCheck(kind: "answerContains", text: "Config")
    ],
    "search-error-types": [
      SubCheck(kind: "modeIs", expectedMode: "answer"),
      SubCheck(kind: "answerMentionsAny", anyOf: ["Error", "LLMError"])
    ],
    "search-test-suites": [
      SubCheck(kind: "modeIs", expectedMode: "answer"),
      SubCheck(kind: "answerMentionsAny", anyOf: ["@Suite", "Tests/"])
    ],
    "search-count-tests": [
      SubCheck(kind: "modeIs", expectedMode: "answer"),
      SubCheck(kind: "answerMatches", pattern: #"\b\d+\b"#)    // any number
    ],
    "search-count-types": [
      SubCheck(kind: "modeIs", expectedMode: "answer"),
      SubCheck(kind: "answerMatches", pattern: #"\b\d+\b"#)
    ],
    "search-enum-cases": [
      SubCheck(kind: "modeIs", expectedMode: "answer"),
      SubCheck(kind: "answerContains", text: "case")
    ],
    "search-init-declarations": [
      SubCheck(kind: "modeIs", expectedMode: "answer"),
      SubCheck(kind: "answerContains", text: "init")
    ],
    "search-typealias": [
      SubCheck(kind: "modeIs", expectedMode: "answer"),
      SubCheck(kind: "llmCallsUnder", maxLlmCalls: 2)   // catches the pre-Phase H 6.9s build misroute
    ],
    "search-extension-conformance": [
      SubCheck(kind: "modeIs", expectedMode: "answer"),
      SubCheck(kind: "answerContains", text: "extension")
    ],
    "search-nested-type": [
      SubCheck(kind: "modeIs", expectedMode: "answer"),
      SubCheck(kind: "answerCitesPath")
    ],
    "search-multi-concept": [
      SubCheck(kind: "modeIs", expectedMode: "answer"),
      SubCheck(kind: "answerLengthOver", minLength: 80)
    ],
    "search-adversarial-build": [
      SubCheck(kind: "modeIs", expectedMode: "answer"),
      SubCheck(kind: "answerDoesNotContain", text: "I'll create")     // guard against mode misroute
    ],
    "search-adversarial-fix": [
      SubCheck(kind: "modeIs", expectedMode: "answer")
    ],

    // === Reference-graph queries ===
    "search-depends-on-config": [
      SubCheck(kind: "modeIs", expectedMode: "answer"),
      SubCheck(kind: "answerContains", text: "Config")
    ],
    "search-depends-on-safeshell": [
      SubCheck(kind: "modeIs", expectedMode: "answer"),
      SubCheck(kind: "answerContains", text: "SafeShell")
    ],
    "search-cross-file-usage": [
      SubCheck(kind: "modeIs", expectedMode: "answer"),
      SubCheck(kind: "answerCitesPath")
    ],
    "search-symbol-index-users": [
      SubCheck(kind: "modeIs", expectedMode: "answer"),
      SubCheck(kind: "answerCitesPath")
    ],
    "search-afm-adapter-callers": [
      SubCheck(kind: "modeIs", expectedMode: "answer"),
      SubCheck(kind: "answerMentionsAny", anyOf: ["AFMAdapter", "Orchestrator"])
    ],
    "search-pipeline-callbacks": [
      SubCheck(kind: "modeIs", expectedMode: "answer"),
      SubCheck(kind: "answerContains", text: "PipelineCallbacks")
    ],
    "search-tree-sitter-integration": [
      SubCheck(kind: "modeIs", expectedMode: "answer"),
      SubCheck(kind: "answerMentionsAny", anyOf: ["TreeSitter", "tree-sitter"])
    ],
    "search-reference-graph-build": [
      SubCheck(kind: "modeIs", expectedMode: "answer"),
      SubCheck(kind: "answerContains", text: "ReferenceGraph")
    ],
    "search-property-lookup": [
      SubCheck(kind: "modeIs", expectedMode: "answer"),
      SubCheck(kind: "answerCitesPath")
    ],
    "search-static-property": [
      SubCheck(kind: "modeIs", expectedMode: "answer"),
      SubCheck(kind: "answerContains", text: "static")
    ]
  ]
}
