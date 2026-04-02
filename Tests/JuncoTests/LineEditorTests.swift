// LineEditorTests.swift — Tests for LineEditor using VirtualTerminalDriver

import Testing
import Foundation
@testable import JuncoKit

@Suite("LineEditor")
struct LineEditorTests {
  private func makeEditor(completers: [any CompletionProvider] = []) -> LineEditor {
    LineEditor(prompt: "> ", completers: completers)
  }

  @Test("typing and submitting returns text")
  func typeAndSubmit() {
    let vt = VirtualTerminalDriver(keys: [
      .char("h"), .char("i"), .enter,
    ])
    let editor = makeEditor()
    let result = editor.readLine(driver: vt)
    #expect(result == "hi")
  }

  @Test("backspace deletes character")
  func backspace() {
    let vt = VirtualTerminalDriver(keys: [
      .char("a"), .char("b"), .char("c"), .backspace, .enter,
    ])
    let editor = makeEditor()
    let result = editor.readLine(driver: vt)
    #expect(result == "ab")
  }

  @Test("ctrl-U clears line")
  func ctrlU() {
    let vt = VirtualTerminalDriver(keys: [
      .char("h"), .char("e"), .char("l"), .char("l"), .char("o"),
      .ctrlU,
      .char("b"), .char("y"), .char("e"), .enter,
    ])
    let editor = makeEditor()
    let result = editor.readLine(driver: vt)
    #expect(result == "bye")
  }

  @Test("ctrl-C returns nil")
  func ctrlC() {
    let vt = VirtualTerminalDriver(keys: [
      .char("x"), .ctrlC,
    ])
    let editor = makeEditor()
    let result = editor.readLine(driver: vt)
    #expect(result == nil)
  }

  @Test("empty submit returns nil")
  func emptySubmit() {
    let vt = VirtualTerminalDriver(keys: [.enter])
    let editor = makeEditor()
    let result = editor.readLine(driver: vt)
    #expect(result == nil)
  }

  private func makeIsolatedHistory() -> (CommandHistory, String) {
    let dir = NSTemporaryDirectory() + "junco-le-hist-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return (CommandHistory(maxEntries: 100, path: "\(dir)/history"), dir)
  }

  @Test("history navigation via up/down")
  func historyNavigation() {
    let (history, dir) = makeIsolatedHistory()
    defer { try? FileManager.default.removeItem(atPath: dir) }

    history.append("first command")
    history.append("second command")

    let vt = VirtualTerminalDriver(keys: [
      .up,     // → "second command"
      .up,     // → "first command"
      .enter,
    ])
    let editor = makeEditor()
    let result = editor.readLine(driver: vt, history: history)
    #expect(result == "first command")
  }

  @Test("history: down returns to newer entry")
  func historyDown() {
    let (history, dir) = makeIsolatedHistory()
    defer { try? FileManager.default.removeItem(atPath: dir) }

    history.append("old")
    history.append("new")

    let vt = VirtualTerminalDriver(keys: [
      .up,     // → "new"
      .up,     // → "old"
      .down,   // → "new"
      .enter,
    ])
    let editor = makeEditor()
    let result = editor.readLine(driver: vt, history: history)
    #expect(result == "new")
  }

  @Test("command completion via tab")
  func commandCompletion() {
    let vt = VirtualTerminalDriver(keys: [
      .char("/"), .char("h"), .char("e"), .tab, .enter,
    ])
    let editor = LineEditor(prompt: "> ", completers: [CommandCompleter()])
    let result = editor.readLine(driver: vt)
    #expect(result == "/help")
  }

  @Test("escape dismisses completions")
  func escapeDismiss() {
    let vt = VirtualTerminalDriver(keys: [
      .char("/"), // triggers completions
      .escape,    // dismiss
      .backspace, // remove /
      .char("h"), .char("i"), .enter,
    ])
    let editor = LineEditor(prompt: "> ", completers: [CommandCompleter()])
    let result = editor.readLine(driver: vt)
    #expect(result == "hi")
  }

  @Test("output contains prompt text")
  func outputContainsPrompt() {
    let vt = VirtualTerminalDriver(keys: [.char("x"), .enter])
    let editor = LineEditor(prompt: "test> ", completers: [])
    _ = editor.readLine(driver: vt)
    #expect(vt.row(0).contains("test>"))
  }

  // MARK: - Completion Cursor Tests (regression: arrow keys swallowing lines above)

  /// A test completer that always returns fixed completions when "@" is typed.
  private struct StubFileCompleter: CompletionProvider {
    let files: [String]
    func completions(for input: String, cursorPosition: Int) -> [Completion] {
      let before = String(input.prefix(cursorPosition))
      guard let at = before.lastIndex(of: "@") else { return [] }
      let replaceFrom = before.distance(from: before.startIndex, to: at)
      return files.map { Completion(display: $0, insertion: "@\($0)", replaceFrom: replaceFrom) }
    }
  }

  @Test("arrow navigation in completions does not overshoot cursor above prompt")
  func completionArrowsNoOvershoot() {
    // Simulate: type "@", get 3 completions, press down 3 times, then tab+enter
    let vt = VirtualTerminalDriver(keys: [
      .char("@"),
      .down, .down, .down,  // navigate completions
      .tab,                 // accept
      .enter,               // submit
    ])
    // Place cursor at row 5 (simulating welcome banner above)
    vt.setCursorRow(5)

    let completer = StubFileCompleter(files: ["README.md", "Package.swift", "main.swift"])
    let editor = LineEditor(prompt: "> ", completers: [completer])
    let result = editor.readLine(driver: vt)

    #expect(result == "@main.swift")
    // The cursor must never have gone above row 5 (the content start)
    #expect(!vt.cursorWentNegative, "Cursor moved above content area — would overwrite welcome banner")
  }

  @Test("multiple completion cycles stay within content area")
  func completionCyclesStayInBounds() {
    // Type "@", cycle through completions multiple times, then escape and submit
    let vt = VirtualTerminalDriver(keys: [
      .char("@"),
      .down, .down, .up, .up, .down,  // cycle around
      .escape,                         // dismiss completions
      .enter,                          // submit "@"
    ])
    vt.setCursorRow(3)

    let completer = StubFileCompleter(files: ["a.swift", "b.swift", "c.swift", "d.swift"])
    let editor = LineEditor(prompt: "> ", completers: [completer])
    _ = editor.readLine(driver: vt)

    #expect(!vt.cursorWentNegative, "Cursor escaped content area during completion cycling")
    // All moveUp values should be reasonable (never exceed content rows)
    for move in vt.moveUpHistory {
      #expect(move <= 10, "Excessive moveUp(\(move)) — likely overshoot")
    }
  }

  @Test("completions render below prompt and are cleared on dismiss")
  func completionsRenderAndClear() {
    let vt = VirtualTerminalDriver(keys: [
      .char("@"),
      .down,       // select first
      .escape,     // dismiss completions
      .backspace,  // remove @
      .char("x"),
      .enter,
    ], screenWidth: 40)
    vt.setCursorRow(2)

    let completer = StubFileCompleter(files: ["File.swift", "Other.swift"])
    let editor = LineEditor(prompt: "> ", completers: [completer])
    let result = editor.readLine(driver: vt)

    #expect(result == "x")
    #expect(!vt.cursorWentNegative)
  }

  @Test("prompt with text and completions: cursor tracks correctly")
  func textBeforeAtCompletion() {
    // "fix @" — text before the @ trigger
    let vt = VirtualTerminalDriver(keys: [
      .char("f"), .char("i"), .char("x"), .char(" "), .char("@"),
      .down,   // select first
      .tab,    // accept
      .enter,
    ])
    vt.setCursorRow(4)

    let completer = StubFileCompleter(files: ["main.swift"])
    let editor = LineEditor(prompt: "> ", completers: [completer])
    let result = editor.readLine(driver: vt)

    #expect(result == "fix @main.swift")
    #expect(!vt.cursorWentNegative)
  }

  // MARK: - Mode Bar Tests

  @Test("mode bar renders during editing and is cleaned on submit")
  func modeBarRendered() {
    // Mode bar appears during editing, finalRender cleans it on submit.
    // Verify: mode bar doesn't corrupt cursor, result is correct,
    // and no cursor overshoot occurs.
    let vt = VirtualTerminalDriver(keys: [
      .char("x"), .enter,
    ], screenWidth: 60)
    vt.setCursorRow(3)
    let editor = LineEditor(prompt: "> ", completers: [], showModeBar: true)
    let result = editor.readLineWithMode(driver: vt)

    #expect(result.text == "x")
    #expect(result.mode == .build)
    #expect(!vt.cursorWentNegative, "Mode bar caused cursor overshoot")
  }

  @Test("mode bar hidden when showModeBar is false")
  func modeBarHidden() {
    let vt = VirtualTerminalDriver(keys: [
      .char("x"), .enter,
    ], screenWidth: 60)
    let editor = LineEditor(prompt: "> ", completers: [], showModeBar: false)
    _ = editor.readLineWithMode(driver: vt)

    let rows = vt.visibleRows()
    let hasModeRow = rows.contains { $0.contains("shift+tab") }
    #expect(!hasModeRow, "Mode bar should not appear when disabled")
  }

  @Test("default mode is build")
  func defaultModeBuild() {
    let vt = VirtualTerminalDriver(keys: [
      .char("x"), .enter,
    ])
    let editor = LineEditor(prompt: "> ", completers: [], showModeBar: true)
    let result = editor.readLineWithMode(driver: vt)

    #expect(result.mode == .build)
    #expect(result.text == "x")
  }

  @Test("shift+tab cycles to search mode")
  func shiftTabToSearch() {
    let vt = VirtualTerminalDriver(keys: [
      .shiftTab,  // build → search
      .char("q"),
      .enter,
    ])
    let editor = LineEditor(prompt: "> ", completers: [], showModeBar: true)
    let result = editor.readLineWithMode(driver: vt)

    #expect(result.mode == .search)
    #expect(result.text == "q")
  }

  @Test("shift+tab cycles through all modes and wraps")
  func shiftTabFullCycle() {
    // build → search → plan → research → build
    let vt = VirtualTerminalDriver(keys: [
      .shiftTab,  // → search
      .shiftTab,  // → plan
      .shiftTab,  // → research
      .shiftTab,  // → build (wrap)
      .char("x"),
      .enter,
    ])
    let editor = LineEditor(prompt: "> ", completers: [], showModeBar: true)
    let result = editor.readLineWithMode(driver: vt)

    #expect(result.mode == .build, "Full cycle should return to build")
  }

  @Test("shift+tab to plan mode returns plan")
  func shiftTabPlanMode() {
    let vt = VirtualTerminalDriver(keys: [
      .shiftTab,  // → search
      .shiftTab,  // → plan
      .char("x"),
      .enter,
    ])
    let editor = LineEditor(prompt: "> ", completers: [], showModeBar: true)
    let result = editor.readLineWithMode(driver: vt)

    #expect(result.mode == .plan)
    #expect(result.text == "x")
  }

  @Test("shift+tab preserves typed text")
  func shiftTabPreservesText() {
    let vt = VirtualTerminalDriver(keys: [
      .char("h"), .char("i"),
      .shiftTab,  // cycle mode
      .char("!"),
      .enter,
    ])
    let editor = LineEditor(prompt: "> ", completers: [], showModeBar: true)
    let result = editor.readLineWithMode(driver: vt)

    #expect(result.text == "hi!")
    #expect(result.mode == .search)
  }

  @Test("first escape keeps text, second escape clears, typing resumes")
  func escBehavior() {
    let vt = VirtualTerminalDriver(keys: [
      .char("h"), .char("i"),
      .escape,    // first esc — sets escPending (hint rendered transiently)
      .char("x"), // cancels esc pending, adds character
      .enter,
    ])
    let editor = LineEditor(prompt: "> ", completers: [], showModeBar: true)
    let result = editor.readLineWithMode(driver: vt)

    // Text should be "hix" — first esc didn't clear, typing resumed
    #expect(result.text == "hix")
  }

  @Test("double escape clears input")
  func doubleEscClears() {
    let vt = VirtualTerminalDriver(keys: [
      .char("h"), .char("i"),
      .escape,    // first esc — hint
      .escape,    // second esc — clear
      .enter,     // submit empty → nil
    ])
    let editor = LineEditor(prompt: "> ", completers: [], showModeBar: true)
    let result = editor.readLineWithMode(driver: vt)

    #expect(result.text == nil)
  }

  @Test("mode bar does not cause cursor overshoot with completions")
  func modeBarWithCompletions() {
    let vt = VirtualTerminalDriver(keys: [
      .char("@"),
      .down, .down,
      .tab,
      .enter,
    ], screenWidth: 60)
    vt.setCursorRow(5)

    let completer = StubFileCompleter(files: ["a.swift", "b.swift", "c.swift"])
    let editor = LineEditor(prompt: "> ", completers: [completer], showModeBar: true)
    let result = editor.readLineWithMode(driver: vt)

    #expect(result.text == "@b.swift")
    #expect(!vt.cursorWentNegative, "Mode bar + completions caused cursor overshoot")
  }

  @Test("shift+tab during completions cycles mode, not completions")
  func shiftTabDuringCompletions() {
    let vt = VirtualTerminalDriver(keys: [
      .char("@"),     // trigger completions
      .shiftTab,      // should cycle mode, not affect completions
      .tab,           // accept first completion
      .enter,
    ])

    let completer = StubFileCompleter(files: ["main.swift"])
    let editor = LineEditor(prompt: "> ", completers: [completer], showModeBar: true)
    let result = editor.readLineWithMode(driver: vt)

    #expect(result.mode == .search, "Shift+tab should cycle mode")
    #expect(result.text == "@main.swift", "Completion should still work")
  }

  @Test("readLine backward compat returns string not result")
  func readLineBackwardCompat() {
    let vt = VirtualTerminalDriver(keys: [
      .shiftTab,  // cycle to search
      .char("x"),
      .enter,
    ])
    let editor = LineEditor(prompt: "> ", completers: [], showModeBar: true)
    // readLine() returns String?, not LineEditorResult
    let text: String? = editor.readLine(driver: vt)
    #expect(text == "x")
  }

  @Test("ctrlC preserves current mode in result")
  func ctrlCPreservesMode() {
    let vt = VirtualTerminalDriver(keys: [
      .shiftTab,  // → search
      .shiftTab,  // → plan
      .ctrlC,
    ])
    let editor = LineEditor(prompt: "> ", completers: [], showModeBar: true)
    let result = editor.readLineWithMode(driver: vt)

    #expect(result.text == nil)
    #expect(result.mode == .plan, "Mode should be preserved on cancel")
  }
}
