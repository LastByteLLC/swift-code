// AFMAdapter.swift — Apple Foundation Models backend

import Foundation
import FoundationModels

/// On-device LLM adapter using Apple Foundation Models.
/// Each call creates a fresh LanguageModelSession (lightweight, not designed for reuse
/// across unrelated prompts).
/// Optionally loads a LoRA adapter from a .fmadapter package for improved output quality.
public actor AFMAdapter: LLMAdapter {

  /// LoRA adapter loaded from .fmadapter package, if available.
  private var loraAdapter: SystemLanguageModel.Adapter?

  public init() {}

  /// Try to load the junco LoRA adapter by registered name.
  /// Fails silently — junco works fine without it, just with lower quality.
  public func loadAdapter(named name: String = "junco_coding") {
    loraAdapter = try? SystemLanguageModel.Adapter(name: name)
  }

  /// Load adapter from a .fmadapter file on disk (for local testing).
  public func loadAdapter(from url: URL) {
    loraAdapter = try? SystemLanguageModel.Adapter(fileURL: url)
  }

  /// Whether a LoRA adapter is currently loaded.
  public var hasAdapter: Bool { loraAdapter != nil }

  // MARK: - Pre-warming

  /// Pre-warm the model to reduce first-call latency.
  /// Call this during startup (e.g., while showing the welcome message)
  /// so the Neural Engine is loaded before the first query.
  public func prewarm() async {
    let session = makeSession(system: nil)
    session.prewarm()
  }

  /// Pre-warm with a system prompt for even faster first response.
  /// Use this when you know the system prompt that will be used.
  public func prewarm(systemPrompt: String) async {
    let session = makeSession(system: systemPrompt)
    session.prewarm()
  }

  // MARK: - Session factory

  private func makeSession(system: String?) -> LanguageModelSession {
    let model: SystemLanguageModel = loraAdapter.map { SystemLanguageModel(adapter: $0) } ?? .default
    if let system {
      return LanguageModelSession(model: model, instructions: system)
    } else {
      return LanguageModelSession(model: model)
    }
  }

  // MARK: - Plain text generation

  public func generate(prompt: String, system: String?) async throws -> String {
    // Pre-flight token guard: compact if needed (no schema overhead for plain text)
    let safeSystem = system ?? ""
    let (compactSystem, compactPrompt) = await TokenGuard.compact(
      system: safeSystem,
      prompt: prompt,
      adapter: self,
      reserveForGeneration: 2500,  // Plain text gets more generation room
      schemaOverhead: 0
    )

    let session = makeSession(system: compactSystem.isEmpty ? nil : compactSystem)

    do {
      let response = try await session.respond(to: compactPrompt)
      return response.content
    } catch let error as LanguageModelSession.GenerationError {
      throw LLMError.from(error)
    }
  }

  // MARK: - Streaming text generation

  /// Generate text with streaming — calls handler with each partial update.
  /// Returns the complete final text.
  public func generateStreaming(
    prompt: String,
    system: String?,
    onChunk: @escaping @Sendable (String) async -> Void
  ) async throws -> String {
    let session = makeSession(system: system)

    do {
      var fullText = ""
      let stream = session.streamResponse(to: prompt)
      for try await partial in stream {
        let newContent = partial.content
        // Only send the delta (new characters since last chunk)
        if newContent.count > fullText.count {
          let delta = String(newContent.dropFirst(fullText.count))
          await onChunk(delta)
        }
        fullText = newContent
      }
      return fullText
    } catch let error as LanguageModelSession.GenerationError {
      throw LLMError.from(error)
    }
  }

  // MARK: - Structured generation (AFM-specific)

  /// Generate structured output constrained by a @Generable type.
  /// Automatically compacts prompts to fit the model's context window.
  public func generateStructured<T: GenerableContent>(
    prompt: String,
    system: String?,
    as type: T.Type,
    options: GenerationOptions? = nil
  ) async throws -> T {
    // Pre-flight token guard: compact if needed
    // Schema overhead ~100-150 tokens, reserve ~800 for structured response
    let safeSystem = system ?? ""
    let (compactSystem, compactPrompt) = await TokenGuard.compact(
      system: safeSystem,
      prompt: prompt,
      adapter: self,
      reserveForGeneration: 800,
      schemaOverhead: 150
    )

    let session = makeSession(system: compactSystem.isEmpty ? nil : compactSystem)

    do {
      if let options {
        let response = try await session.respond(to: compactPrompt, generating: type, options: options)
        return response.content
      } else {
        let response = try await session.respond(to: compactPrompt, generating: type)
        return response.content
      }
    } catch let error as LanguageModelSession.GenerationError {
      throw LLMError.from(error)
    }
  }

  // MARK: - Token counting

  /// Count tokens for a prompt string. Uses exact API on iOS 26.4+, falls back to estimation.
  public func countTokens(_ text: String) async -> Int {
    let model: SystemLanguageModel = loraAdapter.map { SystemLanguageModel(adapter: $0) } ?? .default
    if #available(macOS 26.4, iOS 26.4, *) {
      return (try? await model.tokenCount(for: text)) ?? TokenBudget.estimate(text)
    }
    return TokenBudget.estimate(text)
  }

  /// The model's context window size.
  public var contextSize: Int {
    let model: SystemLanguageModel = loraAdapter.map { SystemLanguageModel(adapter: $0) } ?? .default
    return model.contextSize
  }
}

// MARK: - Typealias for @Generable conformance requirement

/// Types that can be generated by AFM must conform to this.
public typealias GenerableContent = Generable & Sendable

// MARK: - Error mapping

extension LLMError {
  static func from(_ error: LanguageModelSession.GenerationError) -> LLMError {
    switch error {
    case .guardrailViolation:
      return .guardrailViolation
    case .assetsUnavailable:
      return .unavailable("On-device model assets not downloaded. Check Settings > Apple Intelligence.")
    case .exceededContextWindowSize(let context):
      return .contextOverflow(context.debugDescription)
    default:
      return .generationFailed(error.localizedDescription)
    }
  }
}
