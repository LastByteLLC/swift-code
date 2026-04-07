// GenerableTypes.swift — Structured output types for each pipeline stage
//
// Each type is @Generable (for AFM structured output) and Codable.
// Per TN3193: keep types small, use short property names, @Guide only where needed.
// The schema is serialized as JSON and passed in-prompt — every description costs tokens.

import FoundationModels

// MARK: - Shared Enums

/// Tool names used in plan steps and tool dispatch. Exhaustive — no unknown tools.
public enum ToolName: String, Sendable, Codable, CaseIterable {
  case bash, read, create, write, edit, patch, search
}

/// Agent operating mode — determines which pipeline variant runs.
/// Build modifies files; answer reads + responds (search, explain, plan, research).
public enum AgentMode: String, Sendable, Codable, CaseIterable {
  case build     // Create, fix, refactor, test code
  case answer    // Explain, search, plan, research — reads + responds

  public var icon: String {
    switch self {
    case .build:  return "⏵⏵"
    case .answer: return "⌕"
    }
  }
}

/// Outcome of a single tool execution step.
public enum StepOutcome: String, Sendable, Codable {
  case ok
  case error
  case denied
  case validationFailed
}

// MARK: - Domain Extraction

@Generable
public struct DomainExtraction: Codable, Sendable {
  @Guide(description: "The singular domain noun, e.g. podcast, expense, weather")
  public var domain: String
}

// MARK: - Mode Classification (dedicated small LLM call)

@Generable
public struct ModeClassification: Codable, Sendable {
  @Guide(description: "build or answer")
  public var mode: String
}

// MARK: - Stage 1: Intent Classification

@Generable
public struct AgentIntent: Codable, Sendable {
  @Guide(description: "swift or general")
  public var domain: String

  @Guide(description: "fix, add, refactor, explain, test, or explore")
  public var taskType: String

  @Guide(description: "simple, moderate, or complex")
  public var complexity: String

  @Guide(description: "build or answer")
  public var mode: String

  public var targets: [String]
}

extension AgentIntent {
  /// Typed mode with fallback to .build for unknown values.
  /// Maps legacy mode strings (search, plan, research) to .answer.
  public var agentMode: AgentMode {
    let m = mode.lowercased()
    if let direct = AgentMode(rawValue: m) { return direct }
    // Legacy mapping: old 4-mode values → new 2-mode values
    if ["search", "plan", "research"].contains(m) { return .answer }
    return .build
  }
}

// MARK: - Stage 2: Planning

@Generable
public struct AgentPlan: Codable, Sendable {
  public var steps: [PlanStep]
}

@Generable
public struct PlanStep: Codable, Sendable {
  public var instruction: String

  @Guide(description: "bash, read, create, write, edit, patch, or search")
  public var tool: String

  public var target: String
}

extension PlanStep {
  /// Typed tool name, with fallback to .bash for unknown values.
  public var toolName: ToolName {
    ToolName(rawValue: tool.lowercased()) ?? .bash
  }
}

// MARK: - Stage 4: Execution (Tool Parameters)

@Generable
public struct BashParams: Codable, Sendable {
  public var command: String
}

@Generable
public struct ReadParams: Codable, Sendable {
  public var filePath: String
}

/// Still used as fallback when plan target is empty.
@Generable
public struct CreateParams: Codable, Sendable {
  public var filePath: String
  public var content: String
}

@Generable
public struct WriteParams: Codable, Sendable {
  public var filePath: String
  public var content: String
}

@Generable
public struct EditParams: Codable, Sendable {
  public var filePath: String

  @Guide(description: "Exact text to find — use a full line, not a single word")
  public var find: String

  public var replace: String
}

@Generable
public struct SearchParams: Codable, Sendable {
  public var pattern: String
}

@Generable
public struct PatchParams: Codable, Sendable {
  public var filePath: String
  public var patch: String
}

/// Unified action result for internal use (not @Generable).
public enum ToolAction: Sendable {
  case bash(command: String)
  case read(path: String)
  case create(path: String, content: String)
  case write(path: String, content: String)
  case edit(path: String, find: String, replace: String)
  case patch(path: String, diff: String)
  case search(pattern: String)

  /// Whether this action modifies files and requires user permission.
  public var requiresPermission: Bool {
    switch self {
    case .create, .write, .edit, .patch: return true
    case .bash, .read, .search: return false
    }
  }

  /// The file path targeted by this action, for permission display.
  public var targetPath: String? {
    switch self {
    case .create(let path, _), .write(let path, _),
         .edit(let path, _, _), .patch(let path, _):
      return path
    case .bash, .read, .search:
      return nil
    }
  }

  /// Human-readable detail for permission prompts.
  public var permissionDetail: String {
    switch self {
    case .create(_, let content): return "\(content.count) chars"
    case .write(_, let content): return "\(content.count) chars"
    case .edit(_, let find, _): return "replacing \(find.count) chars"
    case .patch: return "apply unified diff"
    case .bash, .read, .search: return ""
    }
  }

  /// The tool name string for this action.
  public var toolLabel: String {
    switch self {
    case .bash: return "bash"
    case .read: return "read"
    case .create: return "create"
    case .write: return "write"
    case .edit: return "edit"
    case .patch: return "patch"
    case .search: return "search"
    }
  }
}

// MARK: - Stage 5: Reflection

@Generable
public struct AgentReflection: Codable, Sendable {
  public var taskSummary: String
  public var insight: String
  public var improvement: String
  public var succeeded: Bool
}

// MARK: - Step Completion Check

@Generable
public struct StepCheck: Codable, Sendable {
  public var complete: Bool
  public var remaining: String
}

// MARK: - Two-Phase Code Generation

@Generable
public struct CodeSkeleton: Codable, Sendable {
  public var imports: String
  public var typeDeclaration: String
  public var storedProperties: String
  public var methodSignatures: [String]
}

@Generable
public struct MethodBody: Codable, Sendable {
  public var implementation: String
}

// MARK: - Mode-Specific Types

/// Shared output type for non-build modes (Search, Plan, Research).
/// Generic enough to carry any structured answer without narrow lock-in.
@Generable
public struct AgentResponse: Codable, Sendable {
  /// Direct answer or main content.
  public var answer: String
  /// Supporting points, findings, file locations, or phase descriptions.
  public var details: [String]
  /// Suggested next steps or follow-up questions.
  public var followUp: [String]
}

/// Search Mode: LLM-generated search queries for rg/grep + RAG.
@Generable
public struct SearchQueries: Codable, Sendable {
  /// Terms to grep/rg for (e.g., "targets", "executableTarget", ".target(").
  public var queries: [String]
  /// Specific files or glob patterns to check (e.g., "Package.swift").
  public var fileHints: [String]
  /// What kind of search: definition, reference, count, structural, or text.
  @Guide(description: "definition, reference, count, structural, or text")
  public var queryType: String
}

/// Plan Mode: structured plan with generic sections.
@Generable
public struct StructuredPlan: Codable, Sendable {
  public var summary: String
  public var sections: [PlanSection]
  /// Clarifications / ambiguities the user should resolve.
  public var questions: [String]
  /// Risks, dependencies, caveats.
  public var concerns: [String]
}

@Generable
public struct PlanSection: Codable, Sendable {
  public var heading: String
  /// Steps, notes, or details within this section.
  public var items: [String]
  /// Relevant files (if any).
  public var files: [String]
}

/// Research Mode: LLM-generated queries for web search + URL fetch.
@Generable
public struct ResearchQueries: Codable, Sendable {
  /// DuckDuckGo search queries to run.
  public var webSearches: [String]
  /// Specific URLs to fetch (documentation, references).
  public var urls: [String]
}

// MARK: - Search Mode Internal Types (not @Generable)

/// A single search result from grep, RAG, or file read.
public struct SearchHit: Sendable {
  public let file: String
  public let line: Int
  public let snippet: String
  public let source: String  // "grep", "rag", "file"
  public let score: Double

  public init(file: String, line: Int, snippet: String, source: String, score: Double) {
    self.file = file
    self.line = line
    self.snippet = snippet
    self.source = source
    self.score = score
  }
}

// MARK: - Pipeline Errors

/// Typed errors for the agent pipeline, enabling error-specific recovery.
public enum PipelineError: Error, Sendable {
  /// AFM returned output that couldn't be deserialized as the requested @Generable type.
  /// Retryable: AFM's non-determinism may produce valid output on the next attempt.
  case deserializationFailed(stage: String, type: String)

  /// Input exceeded AFM's context window.
  /// Retryable with truncated context.
  case contextOverflow(stage: String)

  /// Generated code failed validation (syntax, linting).
  /// Retryable with fix prompt.
  case validationFailed(file: String, error: String)

  /// Build failed after code generation.
  case buildFailed(output: String)

  /// User denied permission for a tool action.
  case permissionDenied(tool: String, target: String)

  /// Repeated identical actions detected.
  case loopDetected(tool: String, target: String)

  /// User aborted the pipeline.
  case aborted(step: Int)

  /// Whether this error type is worth retrying.
  public var isRetryable: Bool {
    switch self {
    case .deserializationFailed, .contextOverflow, .validationFailed:
      return true
    case .buildFailed, .permissionDenied, .loopDetected, .aborted:
      return false
    }
  }
}
