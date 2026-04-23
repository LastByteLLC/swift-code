// MetaConfigTests.swift — Range validation and JSON round-trip for the MetaConfig overlay

import Testing
import Foundation
@testable import JuncoKit

@Suite("MetaConfig")
struct MetaConfigTests {

  @Test("empty MetaConfig keeps all fields nil — defaults preserved")
  func emptyPreservesDefaults() {
    let mc = MetaConfig()
    #expect(mc.contextWindow == nil)
    #expect(mc.candidateTemperature == nil)
    #expect(mc.mlClassifierConfidence == nil)
  }

  @Test("validated() drops out-of-range contextWindow")
  func rejectsBogusContextWindow() {
    var mc = MetaConfig()
    mc.contextWindow = -1
    #expect(mc.validated().contextWindow == nil)
    mc.contextWindow = 10_000_000
    #expect(mc.validated().contextWindow == nil)
    mc.contextWindow = 4096
    #expect(mc.validated().contextWindow == 4096)
  }

  @Test("validated() drops out-of-range temperature")
  func rejectsBogusTemperature() {
    var mc = MetaConfig()
    mc.candidateTemperature = -0.1
    #expect(mc.validated().candidateTemperature == nil)
    mc.candidateTemperature = 17.0
    #expect(mc.validated().candidateTemperature == nil)
    mc.candidateTemperature = 0.5
    #expect(mc.validated().candidateTemperature == 0.5)
  }

  @Test("validated() drops bogus classifier confidence")
  func rejectsBogusConfidence() {
    var mc = MetaConfig()
    mc.mlClassifierConfidence = 1.5
    #expect(mc.validated().mlClassifierConfidence == nil)
    mc.mlClassifierConfidence = -0.2
    #expect(mc.validated().mlClassifierConfidence == nil)
    mc.mlClassifierConfidence = 0.75
    #expect(mc.validated().mlClassifierConfidence == 0.75)
  }

  @Test("MetaConfig round-trips through JSON")
  func jsonRoundTrip() throws {
    var mc = MetaConfig()
    mc.candidateCount = 5
    mc.candidateTemperature = 0.3
    mc.planBudget = .init(system: 200, generation: 1200)
    let data = try JSONEncoder().encode(mc)
    let decoded = try JSONDecoder().decode(MetaConfig.self, from: data)
    #expect(decoded.candidateCount == 5)
    #expect(decoded.candidateTemperature == 0.3)
    #expect(decoded.planBudget?.generation == 1200)
    #expect(decoded.planBudget?.system == 200)
    #expect(decoded.planBudget?.context == nil)
  }

  @Test("StageBudget.resolve merges per-field overrides onto default")
  func stageBudgetResolve() {
    let base = StageBudget(system: 100, context: 200, prompt: 100, generation: 400)
    let override = MetaConfig.StageBudgetOverride(generation: 800)
    let resolved = StageBudget.resolve(override, default: base)
    #expect(resolved.system == 100)  // inherited
    #expect(resolved.context == 200) // inherited
    #expect(resolved.prompt == 100)  // inherited
    #expect(resolved.generation == 800) // overridden
  }

  @Test("StageBudget.resolve with nil override returns default unchanged")
  func stageBudgetResolveNil() {
    let base = StageBudget(system: 100, context: 200, prompt: 100, generation: 400)
    let resolved = StageBudget.resolve(nil, default: base)
    #expect(resolved.total == base.total)
  }
}
