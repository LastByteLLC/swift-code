// GenerableTypes.swift — Structured output types for each pipeline stage
//
// Each type is @Generable (for AFM structured output) and Codable
// (for future JSON-based backends). The @Guide annotations tell AFM
// what each field means, acting as inline schema documentation.

import FoundationModels

// MARK: - Stage 1: Intent Classification

/// Classifies a user query into domain, task type, and complexity.
/// Budget: ~800 tokens total (prompt + generation).
@Generable
public struct AgentIntent: Codable, Sendable {
  @Guide(description: "Project domain: swift, javascript, or general")
  public var domain: String

  @Guide(description: "Task type: fix, add, refactor, explain, test, or explore")
  public var taskType: String

  @Guide(description: "Complexity: simple (1-2 files), moderate (3-5 files), or complex (6+ files)")
  public var complexity: String

  @Guide(description: "Key files or components likely involved, if identifiable from the query")
  public var targets: [String]
}

// MARK: - Stage 2: Strategy Selection (Self-Discovery)

/// Selects the reasoning strategy before planning.
/// Budget: ~800 tokens total.
@Generable
public struct AgentStrategy: Codable, Sendable {
  @Guide(description: "Primary approach: decompose, debug-trace, test-first, read-then-edit, or search-then-plan")
  public var approach: String

  @Guide(description: "First files or locations to examine")
  public var startingPoints: [String]

  @Guide(description: "Key risk or complication to watch for")
  public var risk: String
}

// MARK: - Stage 3: Planning

/// An ordered plan of steps to accomplish the task.
/// Budget: ~1500 tokens total.
@Generable
public struct AgentPlan: Codable, Sendable {
  @Guide(description: "Ordered steps to complete the task")
  public var steps: [PlanStep]
}

/// A single step within a plan.
@Generable
public struct PlanStep: Codable, Sendable {
  @Guide(description: "What to do in this step")
  public var instruction: String

  @Guide(description: "Tool to use: bash, read, create, write, edit, or search")
  public var tool: String

  @Guide(description: "Target file path or command, if known")
  public var target: String
}

// MARK: - Stage 4: Execution
//
// Split into per-tool types so the small on-device model only fills
// fields relevant to the chosen tool. Two-phase: pick tool, then params.

/// First phase: choose which tool to use.
@Generable
public struct ToolChoice: Codable, Sendable {
  @Guide(description: "Tool to use: bash, read, create, write, edit, or search")
  public var tool: String

  @Guide(description: "Brief reasoning for choosing this tool")
  public var reasoning: String
}

/// Bash tool parameters.
@Generable
public struct BashParams: Codable, Sendable {
  @Guide(description: "The shell command to run")
  public var command: String
}

/// Read tool parameters.
@Generable
public struct ReadParams: Codable, Sendable {
  @Guide(description: "File path to read")
  public var filePath: String
}

/// Create tool parameters (new file only).
@Generable
public struct CreateParams: Codable, Sendable {
  @Guide(description: "Path for the new file to create")
  public var filePath: String

  @Guide(description: "Complete content for the new file")
  public var content: String
}

/// Write tool parameters (overwrite existing file).
@Generable
public struct WriteParams: Codable, Sendable {
  @Guide(description: "File path to overwrite")
  public var filePath: String

  @Guide(description: "Complete file content to write")
  public var content: String
}

/// Edit tool parameters (find and replace).
@Generable
public struct EditParams: Codable, Sendable {
  @Guide(description: "File path to edit")
  public var filePath: String

  @Guide(description: "Exact text to find in the file")
  public var find: String

  @Guide(description: "Text to replace it with")
  public var replace: String
}

/// Search tool parameters.
@Generable
public struct SearchParams: Codable, Sendable {
  @Guide(description: "Search pattern or keyword to grep for")
  public var pattern: String
}

/// Patch tool parameters (unified diff to apply).
@Generable
public struct PatchParams: Codable, Sendable {
  @Guide(description: "File path to patch")
  public var filePath: String

  @Guide(description: "Unified diff content to apply (lines starting with + or - or space)")
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
}

// MARK: - Stage 5: Reflection

/// Post-task reflection for the reflexion loop.
/// Stored persistently and retrieved for future similar tasks.
@Generable
public struct AgentReflection: Codable, Sendable {
  @Guide(description: "One-line summary of what the task was")
  public var taskSummary: String

  @Guide(description: "What approach worked or what went wrong")
  public var insight: String

  @Guide(description: "What to do differently on similar tasks in the future")
  public var improvement: String

  @Guide(description: "Whether the task succeeded: true or false")
  public var succeeded: Bool
}

// MARK: - Step Completion Check

/// Quick check: is the current step done, or does it need another action?
@Generable
public struct StepCheck: Codable, Sendable {
  @Guide(description: "Whether the step is complete: true or false")
  public var complete: Bool

  @Guide(description: "If not complete, what remains to be done")
  public var remaining: String
}

// MARK: - Two-Phase Code Generation

/// Phase 1: Generate file skeleton — imports, type declaration, properties, method signatures.
/// Used when a file is too complex for single-shot generation within the 4K context window.
@Generable
public struct CodeSkeleton: Codable, Sendable {
  @Guide(description: "Import statements, one per line")
  public var imports: String

  @Guide(description: "Type declaration line: struct/class/actor/enum Name: Protocols {")
  public var typeDeclaration: String

  @Guide(description: "Property declarations, one per line, with types")
  public var properties: String

  @Guide(description: "Method signatures without bodies, one per line")
  public var methodSignatures: [String]
}

/// Phase 2: Generate a single method body.
@Generable
public struct MethodBody: Codable, Sendable {
  @Guide(description: "The complete method implementation including signature and body")
  public var implementation: String
}
