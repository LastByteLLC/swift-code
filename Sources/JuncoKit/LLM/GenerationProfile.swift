// GenerationProfile.swift — Named `LLMGenerationOptions` presets per pipeline stage
//
// Call sites should pass a profile instead of hand-rolling options. One place
// encodes why an option is set ("greedy because classifiers are deterministic"),
// and `MetaConfig.shared.profileOverrides` lets a runtime overlay tweak any
// field without recompiling.

import Foundation

/// Named generation presets for each pipeline stage.
///
/// Each case returns `LLMGenerationOptions` tuned for the stage's needs:
/// determinism for classifiers and tool-arg resolution, bounded creativity
/// for synthesis, explicit diversity for candidate generation.
public enum GenerationProfile: Sendable {

  /// Mode / intent classifier. Short, fully deterministic.
  case classifier(maxTokens: Int = 100)

  /// Structured tool-argument resolution (BashParams, ReadParams, ...).
  /// Greedy sampling keeps @Generable JSON schema-valid.
  case toolArgs(maxTokens: Int = 600)

  /// Plan / task decomposition. Greedy, larger cap.
  case planning(maxTokens: Int = 1200)

  /// Query expansion for search / research. Mild diversity to surface varied terms.
  case queryExpansion(maxTokens: Int = 400)

  /// Synthesis of gathered context into a short answer. Bounded with mild temperature.
  case synthesis(maxTokens: Int)

  /// Code / file content generation. Low temperature; caller computes the cap
  /// from `adapter.contextSize - inputTokens - safetyReserve`.
  case codeGen(maxTokens: Int, temperature: Double = 0.2)

  /// One slot in a candidate generation run. Index 0 is greedy (a deterministic
  /// floor); subsequent indices use `.random` with the caller's temperature so
  /// later candidates explore alternatives.
  case candidate(index: Int, temperature: Double)

  /// Conversational streaming reply — use the backend's defaults.
  case conversational

  /// Resolve to `LLMGenerationOptions`, applying any `MetaConfig` overrides.
  public func options() -> LLMGenerationOptions {
    let overlay = MetaConfig.shared
    let globalDefaultMax = overlay.defaultMaximumResponseTokens

    switch self {
    case .classifier(let maxTokens):
      let override = overlay.profileOverrides?["classifier"]
      return LLMGenerationOptions(
        maximumResponseTokens: override?.maxTokens ?? maxTokens,
        temperature: override?.temperature,
        sampling: override?.sampling() ?? .greedy
      )

    case .toolArgs(let maxTokens):
      let override = overlay.profileOverrides?["toolArgs"]
      return LLMGenerationOptions(
        maximumResponseTokens: override?.maxTokens ?? maxTokens,
        temperature: override?.temperature,
        sampling: override?.sampling() ?? .greedy
      )

    case .planning(let maxTokens):
      let override = overlay.profileOverrides?["planning"]
      return LLMGenerationOptions(
        maximumResponseTokens: override?.maxTokens ?? maxTokens,
        temperature: override?.temperature,
        sampling: override?.sampling() ?? .greedy
      )

    case .queryExpansion(let maxTokens):
      let override = overlay.profileOverrides?["queryExpansion"]
      return LLMGenerationOptions(
        maximumResponseTokens: override?.maxTokens ?? maxTokens,
        temperature: override?.temperature ?? 0.4,
        sampling: override?.sampling()
      )

    case .synthesis(let maxTokens):
      let override = overlay.profileOverrides?["synthesis"]
      return LLMGenerationOptions(
        maximumResponseTokens: override?.maxTokens ?? maxTokens,
        temperature: override?.temperature ?? 0.3,
        sampling: override?.sampling()
      )

    case .codeGen(let maxTokens, let temperature):
      let override = overlay.profileOverrides?["codeGen"]
      return LLMGenerationOptions(
        maximumResponseTokens: override?.maxTokens ?? maxTokens,
        temperature: override?.temperature ?? temperature,
        sampling: override?.sampling() ?? .greedy
      )

    case .candidate(let index, let temperature):
      let override = overlay.profileOverrides?["candidate"]
      if index == 0 {
        // Greedy floor: guarantees one reproducible candidate per prompt.
        return LLMGenerationOptions(
          maximumResponseTokens: override?.maxTokens,
          temperature: nil,
          sampling: .greedy
        )
      }
      return LLMGenerationOptions(
        maximumResponseTokens: override?.maxTokens,
        temperature: override?.temperature ?? temperature,
        sampling: override?.sampling() ?? .random()
      )

    case .conversational:
      let override = overlay.profileOverrides?["conversational"]
      return LLMGenerationOptions(
        maximumResponseTokens: override?.maxTokens ?? globalDefaultMax,
        temperature: override?.temperature,
        sampling: override?.sampling()
      )
    }
  }
}
