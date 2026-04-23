// TraceSink.swift — Structured pipeline traces for the meta-harness
//
// Emits JSON events at stage boundaries, LLM calls, tool calls, and decision points.
// Consumed by .junco/meta/ to let a proposer reason causally over prior runs.

import Foundation

/// Structured pipeline event.
public struct TraceEvent: Sendable, Codable {
  public enum Kind: String, Sendable, Codable {
    case stageStart
    case stageEnd
    case llmCall
    case toolCall
    case decision
    case runStart
    case runEnd
  }

  public struct Payload: Sendable, Codable {
    public var name: String?
    public var systemPrompt: String?
    public var userPrompt: String?
    public var response: String?
    public var tokensIn: Int?
    public var tokensOut: Int?
    public var structuredType: String?
    public var temperature: Double?
    public var tool: String?
    public var target: String?
    public var output: String?
    public var observedValue: Double?
    public var effectiveThreshold: Double?
    public var pathTaken: String?
    public var alternativesRejected: [String]?
    public var errorMessage: String?
    public var notes: String?

    public init() {}
  }

  public let timestampNs: UInt64
  public let stage: String
  public let kind: Kind
  public let durationMs: Double?
  public let payload: Payload

  public init(
    timestampNs: UInt64 = DispatchTime.now().uptimeNanoseconds,
    stage: String,
    kind: Kind,
    durationMs: Double? = nil,
    payload: Payload = Payload()
  ) {
    self.timestampNs = timestampNs
    self.stage = stage
    self.kind = kind
    self.durationMs = durationMs
    self.payload = payload
  }
}

/// A destination that persists trace events.
public protocol TraceSink: Sendable {
  func emit(_ event: TraceEvent) async
}

/// TaskLocal stage + sink context. The sink and stage flow through structured concurrency
/// without threading parameters through every call site.
public enum TraceContext {
  @TaskLocal public static var currentStage: String = "root"
  @TaskLocal public static var sink: (any TraceSink)?

  /// Emit an event using the currently-bound sink. Pass an explicit `stage` to override the TaskLocal.
  public static func emit(
    kind: TraceEvent.Kind,
    stage: String? = nil,
    durationMs: Double? = nil,
    payload: TraceEvent.Payload = TraceEvent.Payload()
  ) async {
    guard let sink = TraceContext.sink else { return }
    let event = TraceEvent(
      stage: stage ?? TraceContext.currentStage,
      kind: kind,
      durationMs: durationMs,
      payload: payload
    )
    await sink.emit(event)
  }

  /// Emit a stageEnd with a `notes` string.
  public static func emitStageEnd(_ stage: String, durationMs: Double, notes: String? = nil, error: Error? = nil) async {
    var p = TraceEvent.Payload()
    p.notes = notes
    if let error { p.errorMessage = String(describing: error) }
    await emit(kind: .stageEnd, stage: stage, durationMs: durationMs, payload: p)
  }

  /// Emit a decision event with named fields.
  public static func emitDecision(
    stage: String, name: String, observedValue: Double? = nil,
    effectiveThreshold: Double? = nil, pathTaken: String,
    alternativesRejected: [String]? = nil, notes: String? = nil
  ) async {
    var p = TraceEvent.Payload()
    p.name = name
    p.observedValue = observedValue
    p.effectiveThreshold = effectiveThreshold
    p.pathTaken = pathTaken
    p.alternativesRejected = alternativesRejected
    p.notes = notes
    await emit(kind: .decision, stage: stage, payload: p)
  }
}

/// Appends one JSON line per event to a file. Creates the file and parent directory if missing.
public actor JSONLTraceSink: TraceSink {
  private let url: URL
  private let encoder: JSONEncoder

  public init(url: URL) throws {
    self.url = url
    self.encoder = JSONEncoder()
    self.encoder.outputFormatting = [.sortedKeys]
    let dir = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    if !FileManager.default.fileExists(atPath: url.path) {
      FileManager.default.createFile(atPath: url.path, contents: nil)
    }
  }

  public func emit(_ event: TraceEvent) async {
    guard let data = try? encoder.encode(event),
          let line = String(data: data, encoding: .utf8) else { return }
    guard let handle = try? FileHandle(forWritingTo: url) else { return }
    defer { try? handle.close() }
    _ = try? handle.seekToEnd()
    if let payload = (line + "\n").data(using: .utf8) {
      try? handle.write(contentsOf: payload)
    }
  }
}

/// Buffers events in memory (for tests and short-lived runs). Thread-safe.
public actor MemoryTraceSink: TraceSink {
  public private(set) var events: [TraceEvent] = []
  public init() {}
  public func emit(_ event: TraceEvent) async {
    events.append(event)
  }
}
