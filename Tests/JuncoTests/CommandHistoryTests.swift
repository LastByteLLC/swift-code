// CommandHistoryTests.swift

import Testing
import Foundation
@testable import JuncoKit

@Suite("CommandHistory")
struct CommandHistoryTests {
  private func makeHistory() -> (CommandHistory, String) {
    let dir = NSTemporaryDirectory() + "junco-hist-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = "\(dir)/history"
    return (CommandHistory(maxEntries: 100, path: path), dir)
  }

  private func cleanup(_ dir: String) {
    try? FileManager.default.removeItem(atPath: dir)
  }

  @Test("appends and loads entries")
  func appendAndLoad() {
    let (history, dir) = makeHistory()
    defer { cleanup(dir) }
    history.append("first")
    history.append("second")
    #expect(history.count == 2)
    let entries = history.load()
    #expect(entries == ["first", "second"])
  }

  @Test("does not duplicate consecutive identical entries")
  func noDuplicates() {
    let (history, dir) = makeHistory()
    defer { cleanup(dir) }
    history.append("same")
    history.append("same")
    #expect(history.count == 1)
  }

  @Test("ignores empty entries")
  func ignoreEmpty() {
    let (history, dir) = makeHistory()
    defer { cleanup(dir) }
    history.append("")
    history.append("   ")
    #expect(history.isEmpty)
  }

  @Test("respects max entries")
  func maxEntries() {
    let dir = NSTemporaryDirectory() + "junco-hist-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let history = CommandHistory(maxEntries: 3, path: "\(dir)/history")
    history.append("a")
    history.append("b")
    history.append("c")
    history.append("d")
    #expect(history.count == 3)
    #expect(history.load().first == "b")  // "a" was pruned
  }

  @Test("navigator goes up through history")
  func navigatorUp() {
    let (history, dir) = makeHistory()
    defer { cleanup(dir) }
    history.append("old")
    history.append("new")

    var nav = HistoryNavigator(history: history)
    #expect(nav.up(currentInput: "") == "new")
    #expect(nav.up(currentInput: "") == "old")
  }

  @Test("navigator down returns to saved input")
  func navigatorDown() {
    let (history, dir) = makeHistory()
    defer { cleanup(dir) }
    history.append("entry")

    var nav = HistoryNavigator(history: history)
    _ = nav.up(currentInput: "my typing")
    let back = nav.down()
    #expect(back == "my typing")
  }

  @Test("navigator stays at bounds")
  func navigatorBounds() {
    let (history, dir) = makeHistory()
    defer { cleanup(dir) }
    history.append("only")

    var nav = HistoryNavigator(history: history)
    _ = nav.up(currentInput: "")
    #expect(nav.up(currentInput: "") == nil)  // Already at top
  }
}
