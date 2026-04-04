// TokenBudget.swift — Token estimation and budget management
//
// Per TN3193: "roughly three to four characters in Latin alphabet languages"
// Context window size derived from the active LLMAdapter at runtime.

import Foundation

/// Token budget constants for each pipeline stage.
public enum TokenBudget {

  /// Default context window size for backends that don't report their own.
  public static let defaultContextWindow = 4096

  // MARK: - Per-stage budgets

  public static let classify = StageBudget(system: 100, context: 200, prompt: 100, generation: 400)
  public static let plan = StageBudget(system: 150, context: 500, prompt: 150, generation: 800)
  public static let execute = StageBudget(system: 150, context: 800, prompt: 200, generation: 1500)
  public static let observe = StageBudget(system: 80, context: 600, prompt: 80, generation: 300)

  // MARK: - Estimation

  /// Estimate token count from a string.
  /// TN3193: "roughly three to four characters" — use 4 for plain text, 3 for JSON.
  public static func estimate(_ text: String) -> Int {
    max(1, text.utf8.count / 4)
  }

  /// Estimate for structured output (JSON escaping inflates ~33%).
  public static func estimateStructured(_ text: String) -> Int {
    max(1, text.utf8.count / 3)
  }

  /// Estimate token count from multiple strings.
  public static func estimate(_ texts: [String]) -> Int {
    texts.reduce(0) { $0 + estimate($1) }
  }

  /// Truncate text to fit within a token budget.
  /// Legacy character-offset version. Prefer `truncateSmart` for code.
  public static func truncate(_ text: String, toTokens limit: Int) -> String {
    let currentTokens = estimate(text)
    guard currentTokens > limit else { return text }

    let charLimit = limit * 4
    guard charLimit > 40 else { return String(text.prefix(charLimit)) }

    let keepStart = Int(Double(charLimit) * 0.6)
    let keepEnd = Int(Double(charLimit) * 0.3)
    let marker = "\n... [truncated] ...\n"

    let startIdx = text.index(text.startIndex, offsetBy: min(keepStart, text.count))
    let endIdx = text.index(text.endIndex, offsetBy: -min(keepEnd, text.count))

    return String(text[..<startIdx]) + marker + String(text[endIdx...])
  }

  /// Line-aware truncation that never breaks mid-line or mid-declaration.
  /// Keeps complete lines from the start (60%) and end (30%) of the text.
  public static func truncateSmart(_ text: String, toTokens limit: Int) -> String {
    let currentTokens = estimate(text)
    guard currentTokens > limit else { return text }

    let lines = text.components(separatedBy: "\n")
    guard lines.count > 2 else { return truncate(text, toTokens: limit) }

    let headBudget = Int(Double(limit) * 0.6)
    let tailBudget = Int(Double(limit) * 0.3)

    // Collect lines from the start
    var headLines: [String] = []
    var headTokens = 0
    for line in lines {
      let lineTokens = estimate(line) + 1  // +1 for newline
      if headTokens + lineTokens > headBudget { break }
      headLines.append(line)
      headTokens += lineTokens
    }

    // Collect lines from the end (in reverse)
    var tailLines: [String] = []
    var tailTokens = 0
    for line in lines.reversed() {
      let lineTokens = estimate(line) + 1
      if tailTokens + lineTokens > tailBudget { break }
      tailLines.insert(line, at: 0)
      tailTokens += lineTokens
    }

    let omitted = lines.count - headLines.count - tailLines.count
    if omitted <= 0 { return text }  // Everything fits

    let marker = "[... \(omitted) lines omitted ...]"
    return (headLines + [marker] + tailLines).joined(separator: "\n")
  }
}

/// Budget allocation for a single pipeline stage.
public struct StageBudget: Sendable {
  public let system: Int
  public let context: Int
  public let prompt: Int
  public let generation: Int

  public var total: Int { system + context + prompt + generation }
  public var availableContext: Int { context }

  public init(system: Int, context: Int, prompt: Int, generation: Int) {
    self.system = system
    self.context = context
    self.prompt = prompt
    self.generation = generation
  }
}

// MARK: - Priority-Weighted Prompt Packing

/// A labeled section of prompt content with a priority for budget allocation.
/// Higher priority sections are included first when packing into a token budget.
public struct PromptSection: Sendable {
  public let label: String
  public let content: String
  /// Higher = included first. Typical range: 0-100.
  public let priority: Int

  public init(label: String, content: String, priority: Int) {
    self.label = label
    self.content = content
    self.priority = priority
  }
}

extension TokenBudget {
  /// Pack prompt sections into a budget, prioritizing higher-priority sections.
  /// Sections are included in full if possible; the last section that exceeds
  /// the remaining budget is truncated rather than omitted entirely.
  public static func packSections(_ sections: [PromptSection], budget: Int) -> String {
    guard !sections.isEmpty else { return "" }

    let sorted = sections
      .filter { !$0.content.isEmpty }
      .sorted { $0.priority > $1.priority }

    var packed = ""
    var used = 0

    for section in sorted {
      let tokens = estimate(section.content)
      if used + tokens <= budget {
        packed += "\(section.label):\n\(section.content)\n\n"
        used += tokens
      } else {
        let remaining = budget - used
        if remaining > 50 {
          packed += "\(section.label):\n\(truncate(section.content, toTokens: remaining))\n\n"
        }
        break  // Budget exhausted
      }
    }

    return packed
  }
}
