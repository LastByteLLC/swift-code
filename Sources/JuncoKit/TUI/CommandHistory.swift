// CommandHistory.swift — Persistent command history with up/down arrow recall
//
// Stores history in ~/.junco/history (global, not per-project).
// Supports up/down navigation and prefix search.

import Foundation

/// Manages persistent command history.
public struct CommandHistory: Sendable {
  private let path: String
  private let maxEntries: Int

  /// - Parameters:
  ///   - maxEntries: Maximum history entries to keep.
  ///   - path: Custom file path (for testing). Defaults to ~/.junco/history.
  public init(maxEntries: Int = 500, path: String? = nil) {
    self.maxEntries = maxEntries
    if let path {
      self.path = path
    } else {
      let dir = Config.globalDir
      try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
      self.path = (dir as NSString).appendingPathComponent("history")
    }
  }

  /// Load all history entries (most recent last).
  public func load() -> [String] {
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return [] }
    return content.components(separatedBy: "\n").filter { !$0.isEmpty }
  }

  /// Append an entry. Deduplicates consecutive identical entries.
  public func append(_ entry: String) {
    let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }

    var entries = load()
    // Don't duplicate if same as last entry
    if entries.last == trimmed { return }

    entries.append(trimmed)
    // Keep only last maxEntries
    if entries.count > maxEntries {
      entries = Array(entries.suffix(maxEntries))
    }

    let content = entries.joined(separator: "\n") + "\n"
    try? content.write(toFile: path, atomically: true, encoding: .utf8)
  }

  /// Get the number of history entries.
  public var count: Int { load().count }

  /// Whether the history is empty.
  public var isEmpty: Bool { load().isEmpty }
}

/// Navigable history for the line editor.
/// Tracks position in the history stack during a single editing session.
public struct HistoryNavigator: Sendable {
  private let entries: [String]
  private var position: Int  // entries.count = "current input" (past end)
  private var savedInput: String = ""

  public init(history: CommandHistory) {
    self.entries = history.load()
    self.position = entries.count
  }

  /// Navigate up (older). Returns the entry to display, or nil if at top.
  public mutating func up(currentInput: String) -> String? {
    if position == entries.count {
      savedInput = currentInput  // Save what the user was typing
    }
    guard position > 0 else { return nil }
    position -= 1
    return entries[position]
  }

  /// Navigate down (newer). Returns the entry or the saved input.
  public mutating func down() -> String? {
    guard position < entries.count else { return nil }
    position += 1
    if position == entries.count {
      return savedInput  // Restore what the user was typing
    }
    return entries[position]
  }

  /// Reset position to current (after submitting).
  public mutating func reset() {
    position = entries.count
    savedInput = ""
  }
}
