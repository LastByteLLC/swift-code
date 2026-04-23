// TraceSinkTests.swift — Verify TraceEvent encoding and sink behavior

import Testing
import Foundation
@testable import JuncoKit

@Suite("TraceSink")
struct TraceSinkTests {

  @Test("TraceEvent encodes to JSON with expected fields")
  func traceEventEncoding() throws {
    var payload = TraceEvent.Payload()
    payload.systemPrompt = "sys"
    payload.userPrompt = "prompt"
    payload.response = "resp"
    payload.structuredType = "AgentIntent"
    payload.temperature = 0.7
    let event = TraceEvent(
      timestampNs: 12345,
      stage: "classify",
      kind: .llmCall,
      durationMs: 1.5,
      payload: payload
    )
    let data = try JSONEncoder().encode(event)
    let json = String(data: data, encoding: .utf8) ?? ""
    #expect(json.contains("\"stage\":\"classify\""))
    #expect(json.contains("\"kind\":\"llmCall\""))
    #expect(json.contains("\"structuredType\":\"AgentIntent\""))
  }

  @Test("MemoryTraceSink collects emitted events in order")
  func memorySinkCaptures() async {
    let sink = MemoryTraceSink()
    await sink.emit(TraceEvent(stage: "root", kind: .runStart))
    await sink.emit(TraceEvent(stage: "classify", kind: .stageStart))
    await sink.emit(TraceEvent(stage: "classify", kind: .stageEnd, durationMs: 10))
    let events = await sink.events
    #expect(events.count == 3)
    #expect(events[0].kind == .runStart)
    #expect(events[1].stage == "classify" && events[1].kind == .stageStart)
    #expect(events[2].durationMs == 10)
  }

  @Test("TraceContext.emit is a no-op when no sink is bound")
  func emitNoopWithoutSink() async {
    // Outside any withValue block — currentStage defaults to "root" and sink is nil.
    await TraceContext.emit(kind: .runStart)  // should not throw, not crash
    #expect(TraceContext.sink == nil)
  }

  @Test("TraceContext.$sink.withValue binds a sink for the block")
  func sinkScopedBinding() async {
    let sink = MemoryTraceSink()
    await TraceContext.$sink.withValue(sink) {
      await TraceContext.emit(kind: .stageStart, stage: "plan")
    }
    let events = await sink.events
    #expect(events.count == 1)
    #expect(events[0].stage == "plan")
  }

  @Test("TraceContext.emitDecision writes structured decision fields")
  func decisionEventShape() async {
    let sink = MemoryTraceSink()
    await TraceContext.$sink.withValue(sink) {
      await TraceContext.emitDecision(
        stage: "classify",
        name: "modeClassifier.ml",
        observedValue: 0.82,
        effectiveThreshold: 0.7,
        pathTaken: "ml",
        alternativesRejected: ["embedding(0.40)"],
        notes: "mode=answer"
      )
    }
    let events = await sink.events
    #expect(events.count == 1)
    let e = events[0]
    #expect(e.kind == .decision)
    #expect(e.payload.name == "modeClassifier.ml")
    #expect(e.payload.observedValue == 0.82)
    #expect(e.payload.effectiveThreshold == 0.7)
    #expect(e.payload.pathTaken == "ml")
    #expect(e.payload.alternativesRejected == ["embedding(0.40)"])
  }

  @Test("JSONLTraceSink writes newline-delimited JSON to file")
  func jsonlWritesToFile() async throws {
    let tmp = FileManager.default.temporaryDirectory.appendingPathComponent("junco-trace-\(UUID()).jsonl")
    let sink = try JSONLTraceSink(url: tmp)
    await sink.emit(TraceEvent(stage: "a", kind: .runStart))
    await sink.emit(TraceEvent(stage: "a", kind: .runEnd, durationMs: 5))

    let data = try Data(contentsOf: tmp)
    let text = String(data: data, encoding: .utf8) ?? ""
    let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
    #expect(lines.count == 2)
    #expect(lines[0].contains("\"kind\":\"runStart\""))
    #expect(lines[1].contains("\"kind\":\"runEnd\""))

    try FileManager.default.removeItem(at: tmp)
  }
}
