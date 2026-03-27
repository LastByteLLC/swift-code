// SessionPersistence.swift — Save and restore sessions across process restarts
//
// Serializes conversation turns to .junco/session.json so users can resume.
// Each session has an ID, a list of turns, and metadata.

import Foundation

/// A persisted session that can survive process restart.
public struct PersistedSession: Codable, Sendable {
  public let id: String
  public var turns: [PersistedTurn]
  public let startedAt: Date
  public var lastActiveAt: Date
  public let workingDirectory: String
  public let domain: String

  public init(workingDirectory: String, domain: String) {
    self.id = UUID().uuidString.prefix(8).lowercased().description
    self.turns = []
    self.startedAt = Date()
    self.lastActiveAt = Date()
    self.workingDirectory = workingDirectory
    self.domain = domain
  }
}

/// A single turn in a persisted session.
public struct PersistedTurn: Codable, Sendable {
  public let query: String
  public let taskType: String
  public let response: String
  public let succeeded: Bool
  public let llmCalls: Int
  public let tokens: Int
  public let filesModified: [String]
  public let timestamp: Date

  public init(
    query: String, taskType: String, response: String,
    succeeded: Bool, llmCalls: Int, tokens: Int,
    filesModified: [String]
  ) {
    self.query = query
    self.taskType = taskType
    self.response = response
    self.succeeded = succeeded
    self.llmCalls = llmCalls
    self.tokens = tokens
    self.filesModified = filesModified
    self.timestamp = Date()
  }
}

/// Manages session persistence.
public struct SessionPersistence: Sendable {
  private let sessionPath: String

  public init(workingDirectory: String) {
    let dir = (workingDirectory as NSString).appendingPathComponent(Config.projectDirName)
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    self.sessionPath = (dir as NSString).appendingPathComponent("session.json")
  }

  /// Load the last session, if any.
  public func load() -> PersistedSession? {
    guard let data = FileManager.default.contents(atPath: sessionPath) else { return nil }
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    return try? decoder.decode(PersistedSession.self, from: data)
  }

  /// Save a session.
  public func save(_ session: PersistedSession) {
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    guard let data = try? encoder.encode(session) else { return }
    try? data.write(to: URL(fileURLWithPath: sessionPath))
  }

  /// Add a turn to the current session (or create a new one).
  public func addTurn(
    _ turn: PersistedTurn,
    to existing: inout PersistedSession
  ) {
    existing.turns.append(turn)
    existing.lastActiveAt = Date()

    // Keep last 20 turns to prevent unbounded growth
    if existing.turns.count > 20 {
      existing.turns = Array(existing.turns.suffix(20))
    }

    save(existing)
  }

  /// Clear the current session.
  public func clear() {
    try? FileManager.default.removeItem(atPath: sessionPath)
  }

  /// Format session history for prompt context (~200 tokens).
  public func contextForPrompt(_ session: PersistedSession, budget: Int = 200) -> String? {
    guard !session.turns.isEmpty else { return nil }

    let lines = session.turns.suffix(3).map { turn in
      "[\(turn.taskType)] \(turn.query) → \(turn.succeeded ? "ok" : "error")"
    }
    let text = "Session history:\n" + lines.joined(separator: "\n")
    return TokenBudget.truncate(text, toTokens: budget)
  }
}
