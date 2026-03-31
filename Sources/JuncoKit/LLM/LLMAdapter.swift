// LLMAdapter.swift — Protocol for language model backends

/// Minimal adapter protocol for LLM text generation.
/// Structured output is handled at a higher level via AFM's @Generable
/// or JSON parsing for other backends.
public protocol LLMAdapter: Sendable {
  /// Generate a plain text response.
  func generate(prompt: String, system: String?) async throws -> String
}

/// Errors that any adapter can surface.
public enum LLMError: Error, Sendable {
  case unavailable(String)
  case guardrailViolation
  case generationFailed(String)
  case tokenBudgetExceeded(used: Int, limit: Int)
  case contextOverflow(String)
}
