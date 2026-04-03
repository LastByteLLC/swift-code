// TokenBudgetTests.swift — Verify token estimation and truncation

import Testing
@testable import JuncoKit

@Suite("TokenBudget")
struct TokenBudgetTests {

  @Test("estimates roughly 1 token per 4 characters")
  func estimation() {
    // 100 characters → ~25 tokens
    let text = String(repeating: "a", count: 100)
    let estimate = TokenBudget.estimate(text)
    #expect(estimate == 25)
  }

  @Test("empty string returns 1 token minimum")
  func emptyEstimate() {
    #expect(TokenBudget.estimate("") == 1)
  }

  @Test("truncation preserves text under budget")
  func noTruncation() {
    let text = "short text"
    let result = TokenBudget.truncate(text, toTokens: 100)
    #expect(result == text)
  }

  @Test("truncation cuts text over budget")
  func truncates() {
    let text = String(repeating: "x", count: 1000)  // ~250 tokens
    let result = TokenBudget.truncate(text, toTokens: 50)
    #expect(TokenBudget.estimate(result) < 100)  // Rough check, includes marker
    #expect(result.contains("truncated"))
  }

  @Test("all stage budgets fit within context window")
  func budgetsFit() {
    let stages: [StageBudget] = [
      TokenBudget.classify,
      TokenBudget.strategy,
      TokenBudget.plan,
      TokenBudget.execute,
      TokenBudget.observe,
      TokenBudget.reflect,
    ]

    for stage in stages {
      #expect(stage.total <= TokenBudget.defaultContextWindow,
        "Stage budget \(stage.total) exceeds default context window \(TokenBudget.defaultContextWindow)")
    }
  }

  @Test("estimate handles multi-string arrays")
  func multiEstimate() {
    let texts = ["hello", "world", "test"]
    let total = TokenBudget.estimate(texts)
    #expect(total > 0)
    #expect(total == texts.map { TokenBudget.estimate($0) }.reduce(0, +))
  }

  // MARK: - Line-Aware Truncation

  @Test("truncateSmart preserves complete lines")
  func smartTruncateLines() {
    let lines = (1...20).map { "Line \($0): some content here that takes up space" }
    let text = lines.joined(separator: "\n")
    let result = TokenBudget.truncateSmart(text, toTokens: 30)
    // Should not break mid-line
    for line in result.components(separatedBy: "\n") {
      let isMarker = line.contains("omitted")
      let isCompleteLine = line.hasPrefix("Line ") || line.isEmpty
      #expect(isMarker || isCompleteLine, "Broken line: \(line)")
    }
  }

  @Test("truncateSmart includes omission marker with count")
  func smartTruncateMarker() {
    let lines = (1...50).map { "Line \($0)" }
    let text = lines.joined(separator: "\n")
    let result = TokenBudget.truncateSmart(text, toTokens: 20)
    #expect(result.contains("lines omitted"))
  }

  @Test("truncateSmart preserves text under budget")
  func smartTruncateNoop() {
    let text = "short\ntext\nhere"
    let result = TokenBudget.truncateSmart(text, toTokens: 100)
    #expect(result == text)
  }

  @Test("truncateSmart keeps head and tail lines")
  func smartTruncateHeadTail() {
    let lines = (1...30).map { "Line \($0): content" }
    let text = lines.joined(separator: "\n")
    let result = TokenBudget.truncateSmart(text, toTokens: 20)
    #expect(result.hasPrefix("Line 1:"))
    #expect(result.contains("Line 30:"))
  }

  // MARK: - Safety Margin

  @Test("safety margin config is reasonable")
  func safetyMarginConfig() {
    #expect(Config.tokenSafetyMarginPercent >= 3)
    #expect(Config.tokenSafetyMarginPercent <= 15)
    // At 4K window, 5% = 200 tokens
    let margin = 4096 * Config.tokenSafetyMarginPercent / 100
    #expect(margin >= 100)
  }
}
