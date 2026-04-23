// TracingLLMAdapter.swift — Decorator that emits TraceEvents around every LLM call.
//
// Wrap any LLMAdapter before passing to Orchestrator; TraceContext.sink must be bound
// via TraceContext.$sink.withValue(...) for events to be recorded.

import Foundation

public actor TracingLLMAdapter: LLMAdapter {
  private let wrapped: any LLMAdapter

  public init(wrapping wrapped: any LLMAdapter) {
    self.wrapped = wrapped
  }

  nonisolated public var backendName: String { wrapped.backendName }
  nonisolated public var isAFM: Bool { wrapped.isAFM }

  public var contextSize: Int {
    get async { await wrapped.contextSize }
  }

  public func countTokens(_ text: String) async -> Int {
    await wrapped.countTokens(text)
  }

  public func generate(prompt: String, system: String?) async throws -> String {
    let start = DispatchTime.now().uptimeNanoseconds
    do {
      let result = try await wrapped.generate(prompt: prompt, system: system)
      await emitLLMEvent(start: start, system: system, prompt: prompt, response: result, type: nil, options: nil, error: nil)
      return result
    } catch {
      await emitLLMEvent(start: start, system: system, prompt: prompt, response: nil, type: nil, options: nil, error: error)
      throw error
    }
  }

  public func generateStreaming(
    prompt: String,
    system: String?,
    onChunk: @escaping @Sendable (String) async -> Void
  ) async throws -> String {
    let start = DispatchTime.now().uptimeNanoseconds
    do {
      let result = try await wrapped.generateStreaming(prompt: prompt, system: system, onChunk: onChunk)
      await emitLLMEvent(start: start, system: system, prompt: prompt, response: result, type: nil, options: nil, error: nil)
      return result
    } catch {
      await emitLLMEvent(start: start, system: system, prompt: prompt, response: nil, type: nil, options: nil, error: error)
      throw error
    }
  }

  public func generateStructured<T: GenerableContent>(
    prompt: String,
    system: String?,
    as type: T.Type,
    options: LLMGenerationOptions?
  ) async throws -> T {
    let start = DispatchTime.now().uptimeNanoseconds
    do {
      let result = try await wrapped.generateStructured(prompt: prompt, system: system, as: type, options: options)
      let responseStr = (try? JSONEncoder().encode(result)).flatMap { String(data: $0, encoding: .utf8) }
      await emitLLMEvent(start: start, system: system, prompt: prompt, response: responseStr, type: String(describing: type), options: options, error: nil)
      return result
    } catch {
      await emitLLMEvent(start: start, system: system, prompt: prompt, response: nil, type: String(describing: type), options: options, error: error)
      throw error
    }
  }

  private func emitLLMEvent(
    start: UInt64,
    system: String?,
    prompt: String,
    response: String?,
    type: String?,
    options: LLMGenerationOptions?,
    error: Error?
  ) async {
    let end = DispatchTime.now().uptimeNanoseconds
    let durationMs = Double(end - start) / 1_000_000.0

    var payload = TraceEvent.Payload()
    payload.systemPrompt = system
    payload.userPrompt = prompt
    payload.response = response
    payload.structuredType = type
    payload.temperature = options?.temperature
    if let error { payload.errorMessage = String(describing: error) }

    await TraceContext.emit(kind: .llmCall, durationMs: durationMs, payload: payload)
  }
}
