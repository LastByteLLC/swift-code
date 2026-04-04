// ModeTests.swift — Tests for agent mode detection, dispatch, and types

import Testing
import Foundation
@testable import JuncoKit

@Suite("AgentMode")
struct ModeTests {

  // MARK: - AgentMode Enum

  @Test("all modes have distinct icons")
  func modeIcons() {
    let icons = AgentMode.allCases.map(\.icon)
    #expect(Set(icons).count == AgentMode.allCases.count, "Mode icons are not unique")
  }

  @Test("mode raw values round-trip")
  func modeRawValues() {
    for mode in AgentMode.allCases {
      #expect(AgentMode(rawValue: mode.rawValue) == mode)
    }
  }

  @Test("unknown mode string defaults to nil")
  func unknownMode() {
    #expect(AgentMode(rawValue: "deploy") == nil)
  }

  // MARK: - AgentIntent Mode Detection

  @Test("AgentIntent.agentMode parses valid modes")
  func intentModeParsing() {
    let intent = AgentIntent(
      domain: "swift", taskType: "fix", complexity: "simple",
      mode: "answer", targets: []
    )
    #expect(intent.agentMode == .answer)
  }

  @Test("AgentIntent.agentMode defaults to build for unknown")
  func intentModeDefault() {
    let intent = AgentIntent(
      domain: "swift", taskType: "fix", complexity: "simple",
      mode: "unknown", targets: []
    )
    #expect(intent.agentMode == .build)
  }

  @Test("AgentIntent.agentMode maps legacy modes to answer")
  func intentModeLegacyMapping() {
    for legacy in ["search", "plan", "research"] {
      let intent = AgentIntent(
        domain: "swift", taskType: "explore", complexity: "simple",
        mode: legacy, targets: []
      )
      #expect(intent.agentMode == .answer, "Legacy mode '\(legacy)' should map to .answer")
    }
  }

  // MARK: - WorkingMemory Mode

  @Test("WorkingMemory defaults to build mode")
  func memoryDefaultMode() {
    let memory = WorkingMemory(query: "test")
    #expect(memory.mode == .build)
  }

  @Test("compact description includes mode icon")
  func compactIncludesMode() {
    var memory = WorkingMemory(query: "find the auth handler")
    memory.mode = .answer
    let desc = memory.compactDescription()
    #expect(desc.contains("⌕"), "Compact description missing answer mode icon")
  }

  // MARK: - SearchHit

  @Test("SearchHit stores all fields")
  func searchHitFields() {
    let hit = SearchHit(
      file: "Package.swift", line: 16,
      snippet: ".executableTarget(", source: "grep", score: 2.0
    )
    #expect(hit.file == "Package.swift")
    #expect(hit.line == 16)
    #expect(hit.score == 2.0)
  }

  // MARK: - Shared Types

  @Test("AgentResponse round-trips through Codable")
  func agentResponseCodable() throws {
    let response = AgentResponse(
      answer: "The target is defined in Package.swift",
      details: ["Line 16: .executableTarget(name: \"junco\")"],
      followUp: ["Run swift build to verify"]
    )
    let data = try JSONEncoder().encode(response)
    let decoded = try JSONDecoder().decode(AgentResponse.self, from: data)
    #expect(decoded.answer == response.answer)
    #expect(decoded.details.count == 1)
    #expect(decoded.followUp.count == 1)
  }

  @Test("SearchQueries round-trips through Codable")
  func searchQueriesCodable() throws {
    let sq = SearchQueries(
      queries: ["targets", "executableTarget"],
      fileHints: ["Package.swift"],
      queryType: "definition"
    )
    let data = try JSONEncoder().encode(sq)
    let decoded = try JSONDecoder().decode(SearchQueries.self, from: data)
    #expect(decoded.queries.count == 2)
    #expect(decoded.fileHints.first == "Package.swift")
  }

  @Test("StructuredPlan round-trips through Codable")
  func structuredPlanCodable() throws {
    let plan = StructuredPlan(
      summary: "Add OAuth login",
      sections: [
        PlanSection(heading: "Auth Service", items: ["Create OAuthService.swift"], files: ["OAuthService.swift"]),
      ],
      questions: ["Which provider?"],
      concerns: ["Needs entitlements"]
    )
    let data = try JSONEncoder().encode(plan)
    let decoded = try JSONDecoder().decode(StructuredPlan.self, from: data)
    #expect(decoded.sections.count == 1)
    #expect(decoded.questions.first == "Which provider?")
  }

  @Test("ResearchQueries round-trips through Codable")
  func researchQueriesCodable() throws {
    let rq = ResearchQueries(
      webSearches: ["SwiftData @Query macro"],
      urls: ["https://developer.apple.com/documentation/swiftdata"]
    )
    let data = try JSONEncoder().encode(rq)
    let decoded = try JSONDecoder().decode(ResearchQueries.self, from: data)
    #expect(decoded.webSearches.count == 1)
    #expect(decoded.urls.count == 1)
  }

  // MARK: - ThinkingPhrases for Modes

  @Test("mode-specific thinking phrases exist")
  func modePhrases() {
    let phrases = ThinkingPhrases()
    let p = phrases.phrase(for: "answer-mode")
    #expect(!p.isEmpty, "No phrase for answer-mode")
  }
}
