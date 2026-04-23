import Foundation

/// Project-scoped persistent notepad.
public struct Scratchpad: Sendable {
  private let path: String

  public init(projectDirectory: String) {
    let dir = (projectDirectory as NSString).appendingPathComponent("Config.projectDirName")
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    self.path = (dir as NSString).appendingPathComponent("scratchpad.json")
  }

  /// Read all notes.
  public func readAll() -> [String: String] {
    guard let data = FileManager.default.contents(atPath: path),
          let notes = try? JSONDecoder().decode([String: String].self, from: data)
    else { return [:] }
    return notes
  }

  /// Write a note.
  public func write(key: String, value: String) {
    var notes = readAll()
    notes[key] = value
    try? JSONEncoder().encode(notes).write(to: URL(fileURLWithPath: path))
  }

  /// Format for prompt injection (~100 tokens).
  public func promptContext(budget: Int = 100) -> String? {
    let notes = readAll()
    guard !notes.isEmpty else { return nil }

    let formatted = notes.map { "- \($0.key): \($0.value)" }.joined(separator: "\n")
    let truncated = TokenBudget.truncate(formatted, toTokens: budget)
    return "Project notes:\n\(truncated)"
  }

  public var count: Int { readAll().count }
}

/// Local helper kept distinct from the module-level `TokenBudget` enum in Models/TokenBudget.swift.
/// Renamed from `TokenBudget` to avoid an ambiguous-type-lookup compile error.
public enum ScratchpadTokenBudget {
  public static func truncate(_ text: String, toTokens tokens: Int) -> String {
    let tokenCount = text.count
    guard tokenCount > tokens else { return text }
    let firstToken = text.prefix(tokens)
    let remaining = text.dropFirst(tokens)
    return "\(firstToken)\(remaining)"
  }
}
