// SpinnerTests.swift — Tests for Spinner, ThinkingPhrases, and ProgressBar

import Testing
import Foundation
import os
@testable import JuncoKit

/// Thread-safe string collector for testing async output.
private final class OutputCollector: @unchecked Sendable {
  private let lock = OSAllocatedUnfairLock(initialState: [String]())

  func append(_ s: String) {
    lock.withLock { $0.append(s) }
  }

  var last: String {
    lock.withLock { $0.last ?? "" }
  }

  var count: Int {
    lock.withLock { $0.count }
  }
}

@Suite("Spinner")
struct SpinnerTests {

  // MARK: - ThinkingPhrases

  @Test("spinner frames cycle correctly")
  func spinnerFrames() {
    let frames = ThinkingPhrases.spinnerFrames
    #expect(frames.count == 10)
    // Cycling wraps around
    #expect(ThinkingPhrases.spinner(tick: 0) == frames[0])
    #expect(ThinkingPhrases.spinner(tick: 10) == frames[0])
    #expect(ThinkingPhrases.spinner(tick: 3) == frames[3])
  }

  @Test("phrases returns non-empty for all stages")
  func phrasesForStages() {
    let phrases = ThinkingPhrases()
    for stage in ["classify", "strategy", "plan", "execute", "read", "edit", "write", "bash", "search", "reflect", "fetch", "explain"] {
      let p = phrases.phrase(for: stage)
      #expect(!p.isEmpty, "No phrase for stage: \(stage)")
    }
  }

  @Test("unknown stage falls back to execute phrases")
  func unknownStageFallback() {
    let phrases = ThinkingPhrases()
    let p = phrases.phrase(for: "nonexistent")
    #expect(!p.isEmpty)
  }

  @Test("status combines spinner and phrase")
  func statusFormat() {
    let phrases = ThinkingPhrases()
    let s = phrases.status(stage: "plan", tick: 0)
    #expect(s.contains(ThinkingPhrases.spinnerFrames[0]))
  }

  @Test("custom phrases merge with built-in")
  func customPhrases() throws {
    let dir = NSTemporaryDirectory() + "junco-phrases-\(UUID().uuidString)"
    let juncoDir = "\(dir)/.junco"
    try FileManager.default.createDirectory(atPath: juncoDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let custom: [String: [String]] = ["plan": ["Custom planning"]]
    let data = try JSONEncoder().encode(custom)
    try data.write(to: URL(fileURLWithPath: "\(juncoDir)/phrases.json"))

    let phrases = ThinkingPhrases(projectDirectory: dir)
    // Custom phrase should be in the pool — try multiple times to find it
    var found = false
    for _ in 0..<50 {
      if phrases.phrase(for: "plan") == "Custom planning" {
        found = true
        break
      }
    }
    #expect(found, "Custom phrase never appeared in 50 samples")
  }

  // MARK: - ProgressBar

  @Test("progress bar renders step count")
  func progressBarStep() {
    let bar = ProgressBar()
    let rendered = bar.render(step: 2, total: 5, tool: "edit", target: "main.swift")
    #expect(rendered.contains("[2/5]"))
  }

  @Test("progress bar renders stage")
  func progressBarStage() {
    let bar = ProgressBar()
    let rendered = bar.renderStage("plan")
    #expect(!rendered.isEmpty)
    // Should contain a spinner frame
    #expect(ThinkingPhrases.spinnerFrames.contains(where: { rendered.contains($0) }))
  }

  // MARK: - Spinner Actor

  @Test("spinner renders frames to output")
  func spinnerRenders() async throws {
    let collector = OutputCollector()
    let spinner = Spinner(phrases: ThinkingPhrases(), fps: 20) { line in
      collector.append(line)
    }

    await spinner.start(stage: "plan")
    try await Task.sleep(for: .milliseconds(250))
    await spinner.stop()

    #expect(collector.count >= 2, "Expected at least 2 frames in 250ms at 20fps, got \(collector.count)")
  }

  @Test("spinner update changes detail")
  func spinnerUpdateDetail() async throws {
    let collector = OutputCollector()
    let spinner = Spinner(phrases: ThinkingPhrases(), fps: 20) { line in
      collector.append(line)
    }

    await spinner.start(stage: "execute")
    await spinner.update(detail: "[2/5] editing main.swift")
    try await Task.sleep(for: .milliseconds(150))
    await spinner.stop()

    #expect(collector.last.contains("[2/5]"), "Detail not reflected in output: \(collector.last)")
  }

  @Test("spinner stop clears and sets isRunning false")
  func spinnerStop() async {
    let spinner = Spinner(phrases: ThinkingPhrases(), fps: 10) { _ in }
    await spinner.start(stage: "plan")
    #expect(await spinner.isRunning)
    await spinner.stop()
    #expect(await !spinner.isRunning)
  }

  @Test("spinner stage change rotates phrase immediately")
  func spinnerStageChange() async throws {
    let collector = OutputCollector()
    let spinner = Spinner(phrases: ThinkingPhrases(), fps: 20) { line in
      collector.append(line)
    }

    await spinner.start(stage: "classify")
    try await Task.sleep(for: .milliseconds(100))
    await spinner.update(stage: "execute")
    try await Task.sleep(for: .milliseconds(100))
    await spinner.stop()

    #expect(collector.count >= 2)
  }
}

// MARK: - VirtualTerminalDriver Tests

@Suite("VirtualTerminalDriver")
struct VirtualTerminalDriverTests {

  @Test("write places characters on screen")
  func writeToScreen() {
    let vt = VirtualTerminalDriver(screenWidth: 20)
    vt.write("Hello")
    #expect(vt.row(0) == "Hello")
  }

  @Test("newline advances to next row")
  func newlineAdvances() {
    let vt = VirtualTerminalDriver(screenWidth: 20)
    vt.write("Line 1")
    vt.newline()
    vt.write("Line 2")
    #expect(vt.row(0) == "Line 1")
    #expect(vt.row(1) == "Line 2")
  }

  @Test("carriage return resets column")
  func carriageReturn() {
    let vt = VirtualTerminalDriver(screenWidth: 20)
    vt.write("AAAA")
    vt.write("\r")
    vt.write("BB")
    #expect(vt.row(0) == "BBAA")
  }

  @Test("clearToEndOfScreen clears from cursor to bottom")
  func clearToEnd() {
    let vt = VirtualTerminalDriver(screenWidth: 20)
    vt.write("Row 0 content")
    vt.newline()
    vt.write("Row 1 content")
    vt.newline()
    vt.write("Row 2 content")
    // Move to row 1, col 0
    vt.moveUp(1)
    vt.write("\r")
    vt.clearToEndOfScreen()
    #expect(vt.row(0) == "Row 0 content")
    #expect(vt.row(1) == "")
    #expect(vt.row(2) == "")
  }

  @Test("moveUp tracks history")
  func moveUpHistory() {
    let vt = VirtualTerminalDriver(screenWidth: 20)
    vt.setCursorRow(5)
    vt.moveUp(2)
    vt.moveUp(1)
    #expect(vt.moveUpHistory == [2, 1])
    #expect(vt.cursor.row == 2)
  }

  @Test("moveUp detects overshoot above content start")
  func moveUpOvershoot() {
    let vt = VirtualTerminalDriver(screenWidth: 20)
    vt.setCursorRow(3)
    vt.moveUp(5)  // Goes above row 3
    #expect(vt.cursorWentNegative)
    #expect(vt.cursor.row == 0)  // Clamped
  }

  @Test("moveUp within bounds does not flag negative")
  func moveUpWithinBounds() {
    let vt = VirtualTerminalDriver(screenWidth: 20)
    vt.setCursorRow(5)
    // Move down first (simulating content being written below start)
    vt.newline()
    vt.newline()
    // Now at row 7, moveUp(2) goes to row 5 — exactly at content start
    vt.moveUp(2)
    #expect(!vt.cursorWentNegative)
    #expect(vt.cursor.row == 5)
  }

  @Test("ANSI escape sequences are stripped from write output")
  func ansiStripping() {
    let vt = VirtualTerminalDriver(screenWidth: 40)
    vt.write("\u{1B}[2mDim text\u{1B}[0m Normal")
    #expect(vt.row(0) == "Dim text Normal")
  }

  @Test("moveTo sets column correctly")
  func moveToColumn() {
    let vt = VirtualTerminalDriver(screenWidth: 20)
    vt.write("AAAA")
    vt.moveTo(column: 1)  // 1-based → col 0
    vt.write("X")
    #expect(vt.row(0) == "XAAA")
  }

  @Test("word wrap at screen width")
  func wordWrap() {
    let vt = VirtualTerminalDriver(screenWidth: 5)
    vt.write("ABCDEFGH")
    #expect(vt.row(0) == "ABCDE")
    #expect(vt.row(1) == "FGH")
  }

  @Test("visibleRows returns only non-empty rows")
  func visibleRows() {
    let vt = VirtualTerminalDriver(screenWidth: 20)
    vt.write("First")
    vt.newline()
    vt.newline()
    vt.write("Third")
    let rows = vt.visibleRows()
    #expect(rows == ["First", "Third"])
  }

  @Test("reset clears everything")
  func resetClearsAll() {
    let vt = VirtualTerminalDriver(keys: [.char("a")])
    vt.setCursorRow(5)
    vt.write("content")
    vt.moveUp(2)
    vt.reset()
    #expect(vt.cursor == (row: 0, col: 0))
    #expect(vt.moveUpHistory.isEmpty)
    #expect(!vt.cursorWentNegative)
    #expect(vt.row(0) == "")
    #expect(vt.readKey() == .eof)
  }

  @Test("clearLine clears current row only")
  func clearLineOnly() {
    let vt = VirtualTerminalDriver(screenWidth: 20)
    vt.write("Row 0")
    vt.newline()
    vt.write("Row 1")
    vt.clearLine()
    #expect(vt.row(0) == "Row 0")
    #expect(vt.row(1) == "")
  }
}
