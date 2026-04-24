// GenerationProfileTests.swift — Named stage profiles → LLMGenerationOptions mapping

import Testing
@testable import JuncoKit

@Suite("GenerationProfile")
struct GenerationProfileTests {

  @Test("classifier profile is greedy with tight token cap")
  func classifierIsGreedy() {
    let opts = GenerationProfile.classifier(maxTokens: 50).options()
    #expect(opts.sampling == .greedy)
    #expect(opts.maximumResponseTokens == 50)
  }

  @Test("classifier uses 100-token default when not specified")
  func classifierDefault() {
    let opts = GenerationProfile.classifier().options()
    #expect(opts.maximumResponseTokens == 100)
    #expect(opts.sampling == .greedy)
  }

  @Test("toolArgs profile is greedy")
  func toolArgsIsGreedy() {
    let opts = GenerationProfile.toolArgs(maxTokens: 400).options()
    #expect(opts.sampling == .greedy)
    #expect(opts.maximumResponseTokens == 400)
  }

  @Test("planning profile is greedy with 1200-token default")
  func planningDefault() {
    let opts = GenerationProfile.planning().options()
    #expect(opts.sampling == .greedy)
    #expect(opts.maximumResponseTokens == 1200)
  }

  @Test("queryExpansion uses mild temperature for term diversity")
  func queryExpansionTemperature() {
    let opts = GenerationProfile.queryExpansion(maxTokens: 400).options()
    #expect(opts.temperature == 0.4)
    #expect(opts.sampling == nil)
  }

  @Test("synthesis uses bounded temperature and explicit cap")
  func synthesisBounded() {
    let opts = GenerationProfile.synthesis(maxTokens: 80).options()
    #expect(opts.maximumResponseTokens == 80)
    #expect(opts.temperature == 0.3)
  }

  @Test("codeGen uses low temperature by default")
  func codeGenTemperature() {
    let opts = GenerationProfile.codeGen(maxTokens: 2000).options()
    #expect(opts.maximumResponseTokens == 2000)
    #expect(opts.temperature == 0.2)
  }

  @Test("codeGen defaults to greedy sampling")
  func codeGenGreedyDefault() {
    // Greedy decoding reduces AFM stochasticity on enum+switch cases;
    // Phase E measured +20pp on create-traffic-enum with no regressions.
    let opts = GenerationProfile.codeGen(maxTokens: 2000).options()
    #expect(opts.sampling == .greedy)
  }

  @Test("codeGen honors explicit temperature")
  func codeGenCustomTemperature() {
    let opts = GenerationProfile.codeGen(maxTokens: 1500, temperature: 0.5).options()
    #expect(opts.temperature == 0.5)
  }

  @Test("candidate slot 0 is greedy — the reproducible floor")
  func candidateIndexZeroGreedy() {
    let opts = GenerationProfile.candidate(index: 0, temperature: 0.8).options()
    #expect(opts.sampling == .greedy)
    #expect(opts.temperature == nil)
  }

  @Test("candidate slot 1+ uses random + caller temperature")
  func candidateIndexOneRandom() {
    let opts = GenerationProfile.candidate(index: 1, temperature: 0.8).options()
    #expect(opts.temperature == 0.8)
    if case .random = opts.sampling {
      // expected
    } else {
      Issue.record("Expected .random sampling for candidate index 1, got \(String(describing: opts.sampling))")
    }
  }

  @Test("conversational leaves temperature and sampling unset")
  func conversationalDefaults() {
    let opts = GenerationProfile.conversational.options()
    #expect(opts.temperature == nil)
    #expect(opts.sampling == nil)
  }

  // MARK: - SamplingStrategy

  @Test("SamplingStrategy.random allows topK without topP")
  func samplingRandomTopK() {
    let s: SamplingStrategy = .random(topK: 40)
    if case .random(let k, let p, _) = s {
      #expect(k == 40)
      #expect(p == nil)
    } else {
      Issue.record("Expected .random, got \(s)")
    }
  }

  @Test("SamplingStrategy equality")
  func samplingEquality() {
    #expect(SamplingStrategy.greedy == SamplingStrategy.greedy)
    #expect(SamplingStrategy.random(topK: 40) == SamplingStrategy.random(topK: 40))
    #expect(SamplingStrategy.random(topK: 40) != SamplingStrategy.random(topK: 50))
  }

  // MARK: - LLMGenerationOptions init

  @Test("LLMGenerationOptions init carries all four fields")
  func optionsInit() {
    let opts = LLMGenerationOptions(
      maximumResponseTokens: 500,
      temperature: 0.3,
      sampling: .greedy,
      grammar: "root ::= \"hi\""
    )
    #expect(opts.maximumResponseTokens == 500)
    #expect(opts.temperature == 0.3)
    #expect(opts.sampling == .greedy)
    #expect(opts.grammar == "root ::= \"hi\"")
  }
}
