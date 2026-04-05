// KVLineParser.swift — Parse key-value line format from LLM output
//
// Replaces @Generable structured output with plain text generation + parsing.
// The model outputs "key: value" lines, one per line. This parser extracts them
// into a dictionary that can construct intent structs for template rendering.
//
// Benefits over @Generable:
// - No field-count cliff (linear output, no bracket matching)
// - 3x more generation budget (2500 vs 800 tokens)
// - No schema overhead (0 vs 150 tokens)
// - No @Guide literalism (model sees natural language prompts)

import Foundation

public struct KVLineParser: Sendable {

  /// Parse "key: value\nkey: value\n..." into a dictionary.
  /// Handles:
  /// - Leading/trailing whitespace
  /// - Lines without `:` (skipped)
  /// - Empty values (stored as "")
  /// - Multi-word values (everything after first `:`)
  /// - Markdown fences (stripped)
  public static func parse(_ text: String) -> [String: String] {
    var result: [String: String] = [:]
    let cleaned = text
      .replacingOccurrences(of: "```yaml", with: "")
      .replacingOccurrences(of: "```", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)

    for line in cleaned.components(separatedBy: "\n") {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      guard !trimmed.isEmpty, !trimmed.hasPrefix("#"), !trimmed.hasPrefix("//") else { continue }

      guard let colonIndex = trimmed.firstIndex(of: ":") else { continue }
      let key = trimmed[trimmed.startIndex..<colonIndex].trimmingCharacters(in: .whitespaces)
      let value = trimmed[trimmed.index(after: colonIndex)...].trimmingCharacters(in: .whitespaces)

      guard !key.isEmpty else { continue }
      // Strip surrounding quotes if present
      let cleaned = value.hasPrefix("\"") && value.hasSuffix("\"") && value.count >= 2
        ? String(value.dropFirst().dropLast())
        : value
      result[key] = cleaned
    }
    return result
  }

  /// Try parsing as JSON first (model might output JSON from training).
  /// Returns nil if not valid JSON.
  public static func parseJSON(_ text: String) -> [String: String]? {
    let cleaned = text
      .replacingOccurrences(of: "```json", with: "")
      .replacingOccurrences(of: "```", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines)

    guard let data = cleaned.data(using: .utf8),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return nil
    }
    var result: [String: String] = [:]
    for (key, value) in json {
      if let str = value as? String { result[key] = str }
      else { result[key] = "\(value)" }
    }
    return result
  }

  /// Build a prompt header that instructs the model to output KV-line format.
  /// Each field becomes a line: "key: (hint)"
  public static func promptHeader(fields: [(key: String, hint: String)]) -> String {
    var lines = ["Respond with one value per line:"]
    for (key, hint) in fields {
      lines.append("\(key): (\(hint))")
    }
    return lines.joined(separator: "\n")
  }

  /// Parse text as KV-lines, falling back to JSON if KV parsing yields too few fields.
  public static func parseWithFallback(_ text: String, expectedFields: Int) -> [String: String] {
    let kv = parse(text)
    if kv.count >= max(1, expectedFields - 1) { return kv }
    // Try JSON fallback
    if let json = parseJSON(text), json.count >= max(1, expectedFields - 1) { return json }
    return kv // Return whatever we got
  }
}
