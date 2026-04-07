// Prompts.swift — Ultra-compact prompt templates for each pipeline stage
//
// Every prompt is designed to fit within its stage's token budget.
// Tool list is consistent across plan + execute stages.

/// Central tool description used in both plan and execute prompts.
private let toolList = """
  bash (run shell command), read (read file), create (create new file), \
  write (overwrite existing file), edit (find-replace in file), \
  patch (apply unified diff), search (grep pattern)
  """

/// Prompt templates for each pipeline stage.
public enum Prompts {

  // MARK: - Mode Classification

  public static let modeClassifySystem = """
    Classify this query into exactly one mode: \
    build (CREATE, FIX, MODIFY, or TEST code — an imperative action that changes files), \
    answer (EXPLAIN, FIND, SEARCH, PLAN, or RESEARCH — any query that reads code or provides information). \
    If the query asks a question, wants an explanation, requests a search, or needs external info, use answer. \
    Only use build if the user wants to create, modify, or delete files.
    """

  // MARK: - Classify

  public static let classifySystem = """
    You classify coding tasks. Respond with the structured fields only. \
    mode: build (create/fix/modify/test code) or answer (explain/find/plan/research).
    """

  public static func classifyPrompt(query: String, fileHints: String) -> String {
    """
    Query: \(query)
    Project files: \(fileHints)
    """
  }

  // MARK: - Plan

  public static let planSystem = """
    You plan coding tasks as ordered steps. Each step uses exactly one tool. \
    Tools: \(toolList). \
    IMPORTANT: Only plan actions the user explicitly asked for. \
    If the user asks to read or explain, do NOT plan edits or writes. \
    If the user asks to fix existing code, read the file first, then edit. \
    If the user asks to create a new file, use create (not write, not edit). \
    Use the fewest steps possible. For creating one file, plan one create step.
    """

  public static func planPrompt(
    query: String,
    intent: AgentIntent,
    fileContext: String
  ) -> String {
    """
    Task: \(query)
    Domain: \(intent.domain) | Type: \(intent.taskType)
    Targets: \(intent.targets.joined(separator: ", "))
    \(fileContext)
    """
  }

  // MARK: - Search Mode

  public static let searchQuerySystem = """
    Generate grep terms for a Swift project. Output code identifiers, not English. \
    Map concepts: "build target" → .target(, executableTarget; \
    "entry point" → @main, AsyncParsableCommand; "tests" → @Test, testTarget. \
    If the user names a specific symbol, include it exactly. \
    queryType: definition/reference/count/structural/text.
    """

  public static func searchQueryPrompt(query: String, fileHints: String) -> String {
    "Question: \(query)\nProject files:\n\(fileHints)"
  }

  public static let searchSynthesizeSystem = """
    Write ONE sentence answering the question. Cite file:line from the results. \
    Do not invent information.
    """

  public static func searchSynthesizePrompt(query: String, hits: String) -> String {
    "Q: \(query)\nResults:\n\(hits)"
  }

  // MARK: - Plan Mode

  public static let planModeSystem = """
    You create structured implementation plans for Swift/Apple projects. \
    Break the task into phases with concrete steps. \
    Reference actual file paths from the project context — do not guess paths. \
    Each step should name the specific file to modify and what to change. \
    List open questions and flag risks. Be specific and actionable.
    """

  public static func planModePrompt(query: String, context: String) -> String {
    "Task: \(query)\n\nProject context:\n\(context)"
  }

  // MARK: - Research Mode

  public static let researchQuerySystem = """
    Generate web search queries and documentation URLs for a Swift/Apple development question. \
    Prefer official Apple docs (developer.apple.com), Swift.org, and recent WWDC references. \
    Generate 2-3 focused search queries. Include specific doc URLs if you know them.
    """

  public static func researchQueryPrompt(query: String) -> String {
    "Research topic: \(query)"
  }

  public static let researchSynthesizeSystem = """
    Synthesize findings from web research into a clear, actionable answer. \
    Include relevant API signatures, usage patterns, and caveats. \
    Cite sources. Be accurate — if unsure, say so.
    """

  public static func researchSynthesizePrompt(query: String, context: String) -> String {
    "Question: \(query)\n\nResearch findings:\n\(context)"
  }

  // MARK: - Observe

  // MARK: - Domain-Aware Create/Edit Prompts

  /// System prompt for file creation, tailored to the project domain.
  public static func createSystem(domain: DomainConfig) -> String {
    let base = "Output only the file content. No markdown fences, no explanation."
    switch domain.kind {
    case .swift:
      return "\(base) Write complete, compilable Swift. Use proper imports. Follow Swift naming conventions. Swift version: \(TemplateRenderer.swiftToolsVersion). \(domain.promptHint)"
    case .general:
      return "\(base) \(domain.promptHint)"
    }
  }

  /// System prompt for file editing, tailored to the project domain.
  public static func editSystem(domain: DomainConfig) -> String {
    "Output the complete modified file. No markdown fences, no explanation. " +
    "Apply ONLY the requested changes — do not add or modify anything else. " +
    domain.promptHint
  }

  public static let observeSystem = """
    Summarize this tool output concisely. Extract key facts relevant to the task.
    """

  public static func observePrompt(
    tool: String,
    output: String,
    step: String
  ) -> String {
    """
    Tool: \(tool)
    Step: \(step)
    Output:
    \(output)
    """
  }

}
