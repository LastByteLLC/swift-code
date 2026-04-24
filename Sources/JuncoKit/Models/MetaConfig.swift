// MetaConfig.swift — Runtime overlay of Config and TokenBudget constants.
//
// When $META_CONFIG_JSON points to a readable JSON file, fields present in the
// overlay override their defaults. Absent file or absent keys leave defaults intact.
// Used by the meta-harness to A/B different knob settings without rebuilding.

import Foundation

/// Runtime overlay of tunable constants. All fields are optional — nil means "use default".
public struct MetaConfig: Sendable, Codable {
  // Token / context
  /// Optional runtime override for LLMAdapter.contextSize. When set and in-range, the
  /// active adapter returns this value instead of the model's reported context size.
  /// Primarily useful for squeezing the harness under a smaller effective window to
  /// surface compaction-layer bugs.
  public var contextWindow: Int?
  public var charsPerToken: Int?
  public var toolOutputMaxTokens: Int?
  public var fileReadMaxTokens: Int?
  public var planFileReadMaxTokens: Int?
  public var tokenSafetyMarginPercent: Int?

  // Session
  public var maxTurnHistory: Int?
  public var maxObservations: Int?
  public var maxErrors: Int?

  // Tools / generation
  public var bashTimeout: TimeInterval?
  public var maxValidationRetries: Int?
  /// E6: per-file-role retry caps keyed by `MicroSkill.inferFileRole` output
  /// ("view" / "viewmodel" / "service" / "model" / "app" / "test" / "unknown").
  /// When a role is in this dict, its value overrides `maxValidationRetries`.
  public var validationRetriesByRole: [String: Int]?
  public var maxCVFCyclesView: Int?
  public var candidateCount: Int?
  public var candidateTemperature: Double?
  public var twoPhaseDefault: Bool?
  public var sandboxEnabled: Bool?

  // RAG
  public var maxIndexFiles: Int?
  public var maxScanDepth: Int?
  public var maxListFiles: Int?

  // Classifier / reflections
  public var maxReflections: Int?
  public var mlClassifierConfidence: Double?
  public var languageDetectionConfidence: Double?
  public var skillHintBudget: Int?

  // TokenBudget per-stage
  public var classifyBudget: StageBudgetOverride?
  public var planBudget: StageBudgetOverride?
  public var executeBudget: StageBudgetOverride?
  public var observeBudget: StageBudgetOverride?

  public struct StageBudgetOverride: Sendable, Codable {
    public var system: Int?
    public var context: Int?
    public var prompt: Int?
    public var generation: Int?
    public init(system: Int? = nil, context: Int? = nil, prompt: Int? = nil, generation: Int? = nil) {
      self.system = system; self.context = context; self.prompt = prompt; self.generation = generation
    }
  }

  // GenerationProfile overrides — runtime tuning of per-stage `LLMGenerationOptions`.
  public var defaultMaximumResponseTokens: Int?
  public var defaultTemperature: Double?
  public var profileOverrides: [String: ProfileOverride]?

  public struct ProfileOverride: Sendable, Codable {
    public var maxTokens: Int?
    public var temperature: Double?
    /// "greedy", "random", or nil to keep the profile's native sampling.
    public var samplingStrategy: String?
    public var topK: Int?
    public var topP: Double?
    public var seed: UInt64?

    public init(
      maxTokens: Int? = nil, temperature: Double? = nil,
      samplingStrategy: String? = nil, topK: Int? = nil, topP: Double? = nil, seed: UInt64? = nil
    ) {
      self.maxTokens = maxTokens
      self.temperature = temperature
      self.samplingStrategy = samplingStrategy
      self.topK = topK
      self.topP = topP
      self.seed = seed
    }

    /// Decode the override's sampling fields into a `SamplingStrategy`, if set.
    public func sampling() -> SamplingStrategy? {
      switch samplingStrategy?.lowercased() {
      case "greedy": return .greedy
      case "random": return .random(topK: topK, topP: topP, seed: seed)
      default: return nil
      }
    }
  }

  public init() {}

  /// Shared overlay — loaded once from $META_CONFIG_JSON at process start.
  public static let shared: MetaConfig = loadFromEnv()

  private static func loadFromEnv() -> MetaConfig {
    guard let path = ProcessInfo.processInfo.environment["META_CONFIG_JSON"] else {
      return MetaConfig()
    }
    guard let data = FileManager.default.contents(atPath: path) else {
      FileHandle.standardError.write(Data("[MetaConfig] File not found: \(path)\n".utf8))
      return MetaConfig()
    }
    do {
      let parsed = try JSONDecoder().decode(MetaConfig.self, from: data)
      return parsed.validated()
    } catch {
      FileHandle.standardError.write(Data("[MetaConfig] Parse failed \(path): \(error)\n".utf8))
      return MetaConfig()
    }
  }

  /// Clamp / drop out-of-range values. Returns a copy with invalid fields reset to nil.
  public func validated() -> MetaConfig {
    var copy = self
    if let v = copy.contextWindow, v < 256 || v > 1_000_000 { copy.contextWindow = nil }
    if let v = copy.charsPerToken, v < 1 || v > 20 { copy.charsPerToken = nil }
    if let v = copy.toolOutputMaxTokens, v < 10 || v > 10_000 { copy.toolOutputMaxTokens = nil }
    if let v = copy.fileReadMaxTokens, v < 50 || v > 20_000 { copy.fileReadMaxTokens = nil }
    if let v = copy.planFileReadMaxTokens, v < 20 || v > 5_000 { copy.planFileReadMaxTokens = nil }
    if let v = copy.tokenSafetyMarginPercent, v < 0 || v > 50 { copy.tokenSafetyMarginPercent = nil }
    if let v = copy.maxTurnHistory, v < 0 || v > 50 { copy.maxTurnHistory = nil }
    if let v = copy.maxObservations, v < 0 || v > 100 { copy.maxObservations = nil }
    if let v = copy.maxErrors, v < 0 || v > 100 { copy.maxErrors = nil }
    if let v = copy.bashTimeout, v < 1 || v > 600 { copy.bashTimeout = nil }
    if let v = copy.maxValidationRetries, v < 0 || v > 10 { copy.maxValidationRetries = nil }
    if let v = copy.maxCVFCyclesView, v < 0 || v > 10 { copy.maxCVFCyclesView = nil }
    if let v = copy.candidateCount, v < 1 || v > 20 { copy.candidateCount = nil }
    if let v = copy.candidateTemperature, v < 0 || v > 2 { copy.candidateTemperature = nil }
    if let v = copy.maxIndexFiles, v < 10 || v > 100_000 { copy.maxIndexFiles = nil }
    if let v = copy.maxScanDepth, v < 1 || v > 50 { copy.maxScanDepth = nil }
    if let v = copy.maxListFiles, v < 10 || v > 10_000 { copy.maxListFiles = nil }
    if let v = copy.maxReflections, v < 0 || v > 10_000 { copy.maxReflections = nil }
    if let v = copy.mlClassifierConfidence, v < 0 || v > 1 { copy.mlClassifierConfidence = nil }
    if let v = copy.languageDetectionConfidence, v < 0 || v > 1 { copy.languageDetectionConfidence = nil }
    if let v = copy.skillHintBudget, v < 0 || v > 5_000 { copy.skillHintBudget = nil }
    if let v = copy.defaultMaximumResponseTokens, v < 1 || v > 100_000 { copy.defaultMaximumResponseTokens = nil }
    if let v = copy.defaultTemperature, v < 0 || v > 2 { copy.defaultTemperature = nil }
    return copy
  }
}
