// AFMAdapter.swift — Apple Foundation Models backend

import Foundation
import FoundationModels

/// On-device LLM adapter using Apple Foundation Models.
/// Each call creates a fresh LanguageModelSession (lightweight, not designed for reuse
/// across unrelated prompts).
/// Optionally loads a LoRA adapter from a .fmadapter package for improved output quality.
public actor AFMAdapter: LLMAdapter {

  /// LoRA adapter loaded from .fmadapter package, if available.
  private var loraAdapter: FoundationModels.SystemLanguageModel.Adapter?

  nonisolated public let backendName = "Apple Foundation Models (Neural Engine)"
  nonisolated public let isAFM = true

  public init() {}

  /// Try to load the junco LoRA adapter by registered name.
  /// Fails silently — junco works fine without it, just with lower quality.
  public func loadAdapter(named name: String = "junco_coding") {
    loraAdapter = try? FoundationModels.SystemLanguageModel.Adapter(name: name)
  }

  /// Load adapter from a .fmadapter file on disk (for local testing).
  public func loadAdapter(from url: URL) {
    loraAdapter = try? FoundationModels.SystemLanguageModel.Adapter(fileURL: url)
  }

  /// Whether a LoRA adapter is currently loaded.
  public var hasAdapter: Bool { loraAdapter != nil }

  // MARK: - Pre-warming

  public func prewarm() async {
    let session = makeSession(system: nil)
    session.prewarm()
  }

  public func prewarm(systemPrompt: String) async {
    let session = makeSession(system: systemPrompt)
    session.prewarm()
  }

  // MARK: - Session factory

  private func makeSession(system: String?) -> FoundationModels.LanguageModelSession {
    let model: FoundationModels.SystemLanguageModel = loraAdapter.map { FoundationModels.SystemLanguageModel(adapter: $0) } ?? .default
    if let system {
      return FoundationModels.LanguageModelSession(model: model, instructions: system)
    } else {
      return FoundationModels.LanguageModelSession(model: model)
    }
  }

  // MARK: - Plain text generation

  public func generate(prompt: String, system: String?) async throws -> String {
    let safeSystem = system ?? ""
    let (compactSystem, compactPrompt) = await TokenGuard.compact(
      system: safeSystem,
      prompt: prompt,
      adapter: self,
      reserveForGeneration: 2500,
      schemaOverhead: 0
    )

    let session = makeSession(system: compactSystem.isEmpty ? nil : compactSystem)

    do {
      let response = try await session.respond(to: compactPrompt)
      return response.content
    } catch let error as FoundationModels.LanguageModelSession.GenerationError {
      throw mapError(error)
    }
  }

  // MARK: - Streaming text generation

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
        if newContent.count > fullText.count {
          let delta = String(newContent.dropFirst(fullText.count))
          await onChunk(delta)
        }
        fullText = newContent
      }
      return fullText
    } catch let error as FoundationModels.LanguageModelSession.GenerationError {
      throw mapError(error)
    }
  }

  // MARK: - Structured generation

  public func generateStructured<T: GenerableContent>(
    prompt: String,
    system: String?,
    as type: T.Type,
    options: LLMGenerationOptions? = nil
  ) async throws -> T {
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
        let fmOpts = options.toFoundationModels()
        let response = try await session.respond(to: compactPrompt, generating: type, options: fmOpts)
        return response.content
      } else {
        let response = try await session.respond(to: compactPrompt, generating: type)
        return response.content
      }
    } catch let error as FoundationModels.LanguageModelSession.GenerationError {
      throw mapError(error)
    }
  }

  // MARK: - Token counting

  public func countTokens(_ text: String) async -> Int {
    #if compiler(>=6.3)
    if #available(macOS 26.4, iOS 26.4, *) {
      let fmModel: FoundationModels.SystemLanguageModel = loraAdapter.map { .init(adapter: $0) } ?? .default
      return (try? await fmModel.tokenCount(for: text)) ?? TokenBudget.estimate(text)
    }
    #endif
    return TokenBudget.estimate(text)
  }

  public var contextSize: Int {
    #if compiler(>=6.3)
    if #available(macOS 26.4, iOS 26.4, *) {
      let fmModel: FoundationModels.SystemLanguageModel = loraAdapter.map { .init(adapter: $0) } ?? .default
      return fmModel.contextSize
    }
    #endif
    return 4096
  }

  // MARK: - Error mapping

  private func mapError(_ error: FoundationModels.LanguageModelSession.GenerationError) -> LLMError {
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

// MARK: - Options bridging

extension LLMGenerationOptions {
  func toFoundationModels() -> FoundationModels.GenerationOptions {
    var opts = FoundationModels.GenerationOptions()
    if let maximumResponseTokens { opts.maximumResponseTokens = maximumResponseTokens }
    if let temperature { opts.temperature = temperature }
    return opts
  }
}

// MARK: - Typealias for @Generable conformance requirement

/// Types that can be generated must conform to this.
/// Requires Generable (for AFM structured output), Codable (for Ollama JSON decoding), and Sendable.
public typealias GenerableContent = FoundationModels.Generable & Codable & Sendable
