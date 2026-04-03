// MockAdapter.swift — Deterministic adapter for testing

import Foundation
import FoundationModels
import os

/// A mock LLM adapter that returns preconfigured responses.
/// Tracks call history for assertion in tests.
public actor MockAdapter: LLMAdapter {
  public typealias Responder = @Sendable (String, String?) -> String

  private let responder: Responder
  private var _history: [(prompt: String, system: String?)] = []

  public var history: [(prompt: String, system: String?)] {
    _history
  }

  public var callCount: Int { _history.count }

  public let backendName = "Mock"

  public init(responder: @escaping Responder = { _, _ in "mock response" }) {
    self.responder = responder
  }

  /// Convenience: returns the same string for every call.
  public init(fixedResponse: String) {
    self.responder = { _, _ in fixedResponse }
  }

  /// Convenience: returns responses in order, cycling if exhausted.
  public init(responses: [String]) {
    let lock = OSAllocatedUnfairLock(initialState: 0)
    self.responder = { _, _ in
      lock.withLock { idx -> String in
        let r = responses[idx % responses.count]
        idx += 1
        return r
      }
    }
  }

  public func generate(prompt: String, system: String?) async throws -> String {
    _history.append((prompt: prompt, system: system))
    return responder(prompt, system)
  }

  public func generateStreaming(
    prompt: String,
    system: String?,
    onChunk: @escaping @Sendable (String) async -> Void
  ) async throws -> String {
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
    let text = try await generate(prompt: prompt, system: system)
    // All @Generable types are also Codable — decode from JSON
    guard let data = text.data(using: .utf8) else {
      throw LLMError.generationFailed("Mock: invalid UTF-8 response")
    }
    do {
      // T conforms to Generable & Sendable, and all our @Generable types are Codable.
      // Use FoundationModels' GeneratedContent to bridge.
      let content = try FoundationModels.GeneratedContent(json: text)
      return try T(content)
    } catch {
      throw LLMError.generationFailed("Mock: could not decode response as \(T.self): \(error)")
    }
  }

  public func countTokens(_ text: String) async -> Int {
    TokenBudget.estimate(text)
  }

  public var contextSize: Int { 4096 }
}
