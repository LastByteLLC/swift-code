// ReplayAdapter.swift — Record and replay LLM responses as HAR files
//
// Wraps any LLMAdapter. In .record mode, forwards calls and saves responses.
// In .replay mode, returns saved responses deterministically.
// HAR (HTTP Archive) format stores entries sequentially — replay uses FIFO ordering.

import Foundation

/// A single recorded LLM interaction in HAR-compatible format.
public struct HAREntry: Codable, Sendable {
  public struct Request: Codable, Sendable {
    public var prompt: String
    public var system: String?
    public var typeName: String
    public var options: RecordedOptions?
  }

  public struct Response: Codable, Sendable {
    public var json: String
    public var error: String?
    public var timeMs: Int
  }

  public struct RecordedOptions: Codable, Sendable {
    public var maximumResponseTokens: Int?
    public var temperature: Double?
  }

  public var request: Request
  public var response: Response
}

/// HAR log container — compatible with HAR 1.2 structure.
public struct HARLog: Codable, Sendable {
  public struct Creator: Codable, Sendable {
    public var name: String
    public var version: String
  }

  public var version: String
  public var creator: Creator
  public var entries: [HAREntry]

  public init(entries: [HAREntry] = []) {
    self.version = "1.2"
    self.creator = Creator(name: "junco-replay", version: "1.0")
    self.entries = entries
  }
}

public struct HARFile: Codable, Sendable {
  public var log: HARLog

  public init(log: HARLog = HARLog()) {
    self.log = log
  }
}

/// Operating mode for ReplayAdapter.
public enum ReplayMode: Sendable {
  /// Forward calls to wrapped adapter, record responses to HAR file.
  case record(adapter: any LLMAdapter, outputPath: String)
  /// Replay responses from a HAR file in order.
  case replay(inputPath: String)
}

/// Adapter that records LLM interactions to HAR files or replays them deterministically.
public actor ReplayAdapter: LLMAdapter {
  private let mode: ReplayMode
  private var entries: [HAREntry] = []
  private var replayIndex: Int = 0
  private var harFile: HARFile

  public nonisolated var backendName: String { "Replay" }
  public nonisolated var isAFM: Bool { false }
  public nonisolated var contextSize: Int { 4096 }

  /// Create a replay adapter.
  /// - Parameter mode: `.record(adapter:outputPath:)` to record, `.replay(inputPath:)` to replay.
  public init(mode: ReplayMode) throws {
    self.mode = mode
    switch mode {
    case .record:
      self.harFile = HARFile()
    case .replay(let path):
      let data = try Data(contentsOf: URL(fileURLWithPath: path))
      self.harFile = try JSONDecoder().decode(HARFile.self, from: data)
    }
  }

  // MARK: - LLMAdapter

  public func generate(prompt: String, system: String?) async throws -> String {
    switch mode {
    case .record(let adapter, _):
      let start = ContinuousClock.now
      let result = try await adapter.generate(prompt: prompt, system: system)
      let elapsed = start.duration(to: .now)
      let entry = HAREntry(
        request: .init(prompt: prompt, system: system, typeName: "String"),
        response: .init(json: result, timeMs: elapsed.milliseconds)
      )
      harFile.log.entries.append(entry)
      return result

    case .replay:
      return try nextResponse()
    }
  }

  public func generateStreaming(
    prompt: String,
    system: String?,
    onChunk: @escaping @Sendable (String) async -> Void
  ) async throws -> String {
    // Replay doesn't stream — return full response as single chunk.
    let result = try await generate(prompt: prompt, system: system)
    await onChunk(result)
    return result
  }

  public func generateStructured<T: GenerableContent>(
    prompt: String,
    system: String?,
    as type: T.Type,
    options: LLMGenerationOptions? = nil
  ) async throws -> T {
    switch mode {
    case .record(let adapter, _):
      let start = ContinuousClock.now
      let result = try await adapter.generateStructured(
        prompt: prompt, system: system, as: type, options: options
      )
      let elapsed = start.duration(to: .now)

      // Encode result to JSON for storage
      let jsonData = try JSONEncoder().encode(result)
      let json = String(data: jsonData, encoding: .utf8) ?? "{}"

      let entry = HAREntry(
        request: .init(
          prompt: prompt,
          system: system,
          typeName: String(describing: T.self),
          options: options.map {
            .init(maximumResponseTokens: $0.maximumResponseTokens, temperature: $0.temperature)
          }
        ),
        response: .init(json: json, timeMs: elapsed.milliseconds)
      )
      harFile.log.entries.append(entry)
      return result

    case .replay:
      let json = try nextResponse()
      guard let data = json.data(using: .utf8) else {
        throw LLMError.generationFailed("Replay: invalid UTF-8 in recorded response")
      }
      return try JSONDecoder().decode(T.self, from: data)
    }
  }

  public func countTokens(_ text: String) async -> Int {
    TokenBudget.estimate(text)
  }

  // MARK: - HAR File I/O

  /// Flush recorded entries to disk. Call after recording session completes.
  public func save() throws {
    guard case .record(_, let path) = mode else { return }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    let data = try encoder.encode(harFile)
    try data.write(to: URL(fileURLWithPath: path))
  }

  /// Number of recorded entries.
  public var entryCount: Int { harFile.log.entries.count }

  /// Number of entries remaining for replay.
  public var remainingEntries: Int {
    max(0, harFile.log.entries.count - replayIndex)
  }

  /// Reset replay index to beginning.
  public func reset() {
    replayIndex = 0
  }

  // MARK: - Private

  private func nextResponse() throws -> String {
    guard replayIndex < harFile.log.entries.count else {
      throw LLMError.generationFailed(
        "Replay: exhausted all \(harFile.log.entries.count) recorded entries"
      )
    }
    let entry = harFile.log.entries[replayIndex]
    replayIndex += 1

    if let error = entry.response.error {
      throw LLMError.generationFailed("Replay (recorded error): \(error)")
    }
    return entry.response.json
  }
}

// MARK: - Duration Helpers

private extension Duration {
  var milliseconds: Int {
    Int(components.seconds * 1000 + components.attoseconds / 1_000_000_000_000_000)
  }
}
