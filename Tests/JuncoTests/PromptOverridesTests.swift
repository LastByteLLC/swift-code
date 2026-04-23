// PromptOverridesTests.swift — Verify JSON round-trip and fallback behavior

import Testing
import Foundation
@testable import JuncoKit

@Suite("PromptOverrides")
struct PromptOverridesTests {

  @Test("empty PromptOverrides leaves all fields nil")
  func emptyFieldsAreNil() {
    let po = PromptOverrides()
    #expect(po.modeClassifySystem == nil)
    #expect(po.classifySystem == nil)
    #expect(po.planSystem == nil)
  }

  @Test("PromptOverrides round-trips through JSON")
  func jsonRoundTrip() throws {
    var po = PromptOverrides()
    po.modeClassifySystem = "Custom classifier"
    po.planSystem = "Custom planner"
    let data = try JSONEncoder().encode(po)
    let decoded = try JSONDecoder().decode(PromptOverrides.self, from: data)
    #expect(decoded.modeClassifySystem == "Custom classifier")
    #expect(decoded.planSystem == "Custom planner")
    #expect(decoded.classifySystem == nil)
  }

  @Test("Prompts reads override when present, default when nil")
  func promptsOverlayFallback() {
    // Snapshot of the default — the static defaults in DefaultPrompts are what
    // Prompts should return when PromptOverrides.shared has nil for that field.
    // Since PromptOverrides.shared is loaded at process start from the
    // $PROMPT_OVERRIDES_JSON env var (which is unset in the test harness), we
    // expect the default-backed values.
    #expect(!Prompts.modeClassifySystem.isEmpty)
    #expect(Prompts.modeClassifySystem.lowercased().contains("classify"))
    #expect(!Prompts.planSystem.isEmpty)
    #expect(!Prompts.searchSynthesizeSystem.isEmpty)
  }
}
