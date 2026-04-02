// ActionLogTests.swift — Tests for ActionLog symbols and formatting

import Testing
import Foundation
@testable import JuncoKit

@Suite("ActionLog")
struct ActionLogTests {

  @Test("log symbols are distinct")
  func symbolsDistinct() {
    let symbols = [LogSymbol.action, LogSymbol.output, LogSymbol.task, LogSymbol.add, LogSymbol.remove]
    #expect(Set(symbols).count == symbols.count)
  }

  @Test("action symbol is ⏺")
  func actionSymbol() {
    #expect(LogSymbol.action == "⏺")
  }

  @Test("output symbol is ⎿")
  func outputSymbol() {
    #expect(LogSymbol.output.hasPrefix("⎿"))
  }

  @Test("task symbol is ✻")
  func taskSymbol() {
    #expect(LogSymbol.task == "✻")
  }

  @Test("ActionLog can be created")
  func creation() {
    let log = ActionLog()
    // Smoke test — just ensure it doesn't crash
    // Actual output goes to Terminal which we can't capture in unit tests
    // without a virtual terminal. The VirtualTerminalDriver tests cover rendering.
    _ = log
  }
}
