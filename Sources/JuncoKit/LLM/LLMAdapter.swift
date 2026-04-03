// LLMAdapter.swift — Protocol for language model backends

/// Options that control how the model generates its response.
public struct LLMGenerationOptions: Sendable {
  public var maximumResponseTokens: Int?
  public var temperature: Double?

  public init(maximumResponseTokens: Int? = nil, temperature: Double? = nil) {
    self.maximumResponseTokens = maximumResponseTokens
    self.temperature = temperature
  }
}

/// Adapter protocol for LLM text and structured generation.
/// Covers all capabilities the Orchestrator pipeline requires.
public protocol LLMAdapter: Sendable {
  /// Generate a plain text response.
  func generate(prompt: String, system: String?) async throws -> String

  /// Generate text with streaming — calls handler with each partial update.
  /// Returns the complete final text.
  func generateStreaming(
    prompt: String,
    system: String?,
    onChunk: @escaping @Sendable (String) async -> Void
  ) async throws -> String

  /// Generate structured output constrained by a @Generable type.
  func generateStructured<T: GenerableContent>(
    prompt: String,
    system: String?,
    as type: T.Type,
    options: LLMGenerationOptions?
  ) async throws -> T

  /// Count tokens for a prompt string.
  func countTokens(_ text: String) async -> Int

  /// The model's context window size.
  var contextSize: Int { get async }

  /// Human-readable backend name for UI display (e.g., "Apple Foundation Models", "Ollama (qwen2.5-coder)").
  var backendName: String { get }

  /// Whether this adapter uses Apple Foundation Models (enables LoRA, prewarm, etc.).
  var isAFM: Bool { get }
}

// MARK: - Defaults & Convenience

extension LLMAdapter {
  public var isAFM: Bool { false }

  /// Convenience: generateStructured without options (default nil).
  /// Needed because default parameter values don't work through existentials.
  public func generateStructured<T: GenerableContent>(
    prompt: String,
    system: String?,
    as type: T.Type
  ) async throws -> T {
    try await generateStructured(prompt: prompt, system: system, as: type, options: nil)
  }
}

/// Errors that any adapter can surface.
public enum LLMError: Error, Sendable {
  case unavailable(String)
  case guardrailViolation
  case generationFailed(String)
  case tokenBudgetExceeded(used: Int, limit: Int)
  case contextOverflow(String)
}
