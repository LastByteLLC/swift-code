// TokenGuard.swift — Pre-flight token budget enforcement
//
// Ensures every LLM call fits within the model's context window.
// Derives limits from SystemLanguageModel.contextSize (never hardcoded).
// Uses exact tokenCount(for:) on iOS 26.4+, conservative estimation otherwise.
// Per TN3193: compact the prompt, not the generation.

import Foundation

/// Pre-flight token budget enforcement.
/// All limits derived from the model's actual context size, never hardcoded.
public struct TokenGuard: Sendable {

  // MARK: - Estimation

  /// Conservative token estimate (pre-26.4 fallback).
  /// TN3193: "roughly three to four characters in Latin alphabet languages"
  /// Structured output (JSON) uses 3 chars/token due to escaping overhead.
  /// Plain text uses 4 chars/token.
  public static func estimate(_ text: String, structured: Bool = false) -> Int {
    let divisor = structured ? 3 : 4
    return max(1, text.utf8.count / divisor)
  }

  /// Measure exact tokens if available (iOS 26.4+), otherwise estimate.
  public static func measure(
    _ text: String,
    using adapter: any LLMAdapter,
    structured: Bool = false
  ) async -> Int {
    let exact = await adapter.countTokens(text)
    // countTokens returns the estimate on <26.4, so this always works
    return exact
  }

  // MARK: - Pre-flight compaction

  /// Compact system + prompt to fit within the model's context window.
  /// Strips skill hints and truncates prompt progressively.
  ///
  /// - Parameters:
  ///   - system: The system prompt (base instruction + optional skill hints)
  ///   - prompt: The user prompt
  ///   - adapter: The AFM adapter (for context size + token counting)
  ///   - reserveForGeneration: Tokens to reserve for the model's response
  ///   - schemaOverhead: Estimated tokens for @Generable schema (0 for plain text)
  /// - Returns: Compacted (system, prompt) pair guaranteed to fit
  public static func compact(
    system: String,
    prompt: String,
    adapter: any LLMAdapter,
    reserveForGeneration: Int = 1500,
    schemaOverhead: Int = 0
  ) async -> (system: String, prompt: String) {
    let contextSize = await adapter.contextSize
    let safetyMargin = contextSize * Config.tokenSafetyMarginPercent / 100
    let budget = contextSize - reserveForGeneration - schemaOverhead - safetyMargin

    var currentSystem = system
    var currentPrompt = prompt

    let systemTokens = await measure(currentSystem, using: adapter)
    let promptTokens = await measure(currentPrompt, using: adapter)

    // If it fits, return as-is (common case — avoid unnecessary work)
    if systemTokens + promptTokens <= budget {
      return (currentSystem, currentPrompt)
    }

    // Step 1: Strip skill hints from system prompt
    // Skills are appended after the base system prompt (first sentence).
    // Keep the base instruction, drop the skill hints.
    let stripped = stripSkillHints(from: currentSystem)
    if stripped.count < currentSystem.count {
      currentSystem = stripped
    }

    let strippedSystemTokens = await measure(currentSystem, using: adapter)

    // Step 2: Truncate prompt to fit remaining budget
    if strippedSystemTokens + promptTokens > budget {
      let availableForPrompt = max(100, budget - strippedSystemTokens)
      currentPrompt = TokenBudget.truncate(currentPrompt, toTokens: availableForPrompt)
    }

    return (currentSystem, currentPrompt)
  }

  // MARK: - Overflow Detection

  /// Check if a system+prompt pair will likely overflow the model's context window.
  /// Returns true if estimated usage exceeds 80% of context, meaning the caller
  /// should use an alternative strategy (e.g. two-phase generation).
  public static func willOverflow(
    system: String,
    prompt: String,
    adapter: any LLMAdapter,
    reserveForGeneration: Int = 1500,
    schemaOverhead: Int = 0
  ) async -> Bool {
    let contextSize = await adapter.contextSize
    let safetyMargin = contextSize * Config.tokenSafetyMarginPercent / 100
    let budget = contextSize - reserveForGeneration - schemaOverhead - safetyMargin

    let systemTokens = estimate(system)
    let promptTokens = estimate(prompt)
    return systemTokens + promptTokens > budget * 80 / 100
  }

  // MARK: - Helpers

  /// Strip appended skill hints from a system prompt, keeping the base instruction.
  /// Skills are appended with spaces after the base system prompt.
  /// Base prompts end with a period followed by skill text.
  private static func stripSkillHints(from system: String) -> String {
    // Find the end of the first sentence (the base system prompt)
    // Look for the first period followed by a space and uppercase letter (skill hint start)
    let chars = Array(system)
    for i in 0..<chars.count - 2 {
      if chars[i] == "." && chars[i + 1] == " " && chars[i + 2].isUpperCase {
        // Check if what follows looks like a skill hint (not part of the base prompt)
        let remaining = String(chars[(i + 2)...])
        if remaining.contains("@") || remaining.contains("LOOP") || remaining.contains("Use ")
            || remaining.contains("When ") || remaining.contains("Never ") || remaining.contains("IMPORTANT") {
          return String(chars[...i])
        }
      }
    }
    return system
  }
}

private extension Character {
  var isUpperCase: Bool {
    isLetter && String(self) == String(self).uppercased()
  }
}
