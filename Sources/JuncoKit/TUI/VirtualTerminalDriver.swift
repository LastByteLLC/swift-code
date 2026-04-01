// VirtualTerminalDriver.swift — Mock terminal for testing TUI components
//
// Simulates a virtual screen buffer with cursor tracking. Processes
// ANSI-like operations (moveUp, clearToEndOfScreen, etc.) to produce
// a screen state that tests can inspect. Used by tests to verify
// LineEditor rendering, completions, and cursor behavior.

import Foundation

/// A mock terminal driver that replays key sequences and maintains a virtual screen.
public final class VirtualTerminalDriver: @unchecked Sendable, TerminalIO {
  private var keyQueue: [Key] = []
  private var keyIndex = 0

  // Virtual screen: array of rows, each is a string of characters.
  // Row 0 is the top of the screen.
  private var screen: [[Character]]
  private var cursorRow: Int = 0
  private var cursorCol: Int = 0

  /// Number of rows that have ever been written to (high-water mark).
  public private(set) var maxRowReached: Int = 0

  /// Track every moveUp amount for debugging.
  public private(set) var moveUpHistory: [Int] = []

  /// Whether any moveUp moved above the initial cursor row (the bug).
  public private(set) var cursorWentNegative = false

  /// The initial row where content starts (set on first write).
  public private(set) var contentStartRow: Int = 0

  public let screenWidth: Int
  public let screenHeight: Int

  public init(keys: [Key] = [], screenWidth: Int = 80, screenHeight: Int = 24) {
    self.keyQueue = keys
    self.screenWidth = screenWidth
    self.screenHeight = screenHeight
    self.screen = Array(repeating: Array(repeating: Character(" "), count: screenWidth), count: screenHeight)
  }

  /// Set the initial cursor row (simulates content already on screen above the prompt).
  public func setCursorRow(_ row: Int) {
    cursorRow = row
    contentStartRow = row
  }

  /// Inject additional keys.
  public func injectKeys(_ keys: [Key]) {
    keyQueue.append(contentsOf: keys)
  }

  /// Read the next injected key. Returns .eof when queue is exhausted.
  public func readKey() -> Key {
    guard keyIndex < keyQueue.count else { return .eof }
    let key = keyQueue[keyIndex]
    keyIndex += 1
    return key
  }

  /// Write text to the virtual screen at the current cursor position.
  /// Strips ANSI escape sequences (e.g., color codes) so only visible
  /// characters appear on the virtual screen.
  public func write(_ text: String) {
    var inEscape = false
    for ch in text {
      if inEscape {
        // Consume characters until an ASCII letter terminates the sequence
        if ch.isASCII && ch.isLetter { inEscape = false }
        continue
      }
      if ch == "\u{1B}" {
        inEscape = true
        continue
      }
      if ch == "\r" {
        cursorCol = 0
      } else {
        if cursorRow >= 0 && cursorRow < screenHeight && cursorCol < screenWidth {
          screen[cursorRow][cursorCol] = ch
        }
        cursorCol += 1
        if cursorCol >= screenWidth {
          cursorCol = 0
          cursorRow += 1
        }
        maxRowReached = max(maxRowReached, cursorRow)
      }
    }
  }

  /// Flush (no-op for virtual driver).
  public func flush() {}

  /// Move cursor to column 1 and clear to end of screen.
  public func beginRedraw() {
    cursorCol = 0
    clearToEndOfScreen()
  }

  /// Move cursor to column (1-based).
  public func moveTo(column: Int) {
    cursorCol = max(0, column - 1)
  }

  /// Move cursor up n rows. Tracks history and detects overshooting.
  public func moveUp(_ n: Int = 1) {
    guard n > 0 else { return }
    moveUpHistory.append(n)
    cursorRow -= n
    if cursorRow < contentStartRow {
      cursorWentNegative = true
    }
    // Clamp to prevent array out-of-bounds
    cursorRow = max(0, cursorRow)
  }

  /// Move cursor down n rows.
  public func moveDown(_ n: Int = 1) {
    guard n > 0 else { return }
    cursorRow = min(screenHeight - 1, cursorRow + n)
    maxRowReached = max(maxRowReached, cursorRow)
  }

  /// Clear from cursor position to end of screen.
  public func clearToEndOfScreen() {
    // Clear rest of current row
    if cursorRow >= 0 && cursorRow < screenHeight {
      for col in cursorCol..<screenWidth {
        screen[cursorRow][col] = " "
      }
    }
    // Clear all rows below
    for row in (cursorRow + 1)..<screenHeight {
      screen[row] = Array(repeating: Character(" "), count: screenWidth)
    }
  }

  /// Clear the entire current line.
  public func clearLine() {
    if cursorRow >= 0 && cursorRow < screenHeight {
      screen[cursorRow] = Array(repeating: Character(" "), count: screenWidth)
    }
  }

  /// Write a newline (move to next line, column 0).
  public func newline() {
    cursorRow += 1
    cursorCol = 0
    maxRowReached = max(maxRowReached, cursorRow)
  }

  // MARK: - Test Inspection

  /// All non-empty rows concatenated (for backward-compatible tests).
  public var visibleOutput: String {
    visibleRows().joined(separator: "\n")
  }

  /// Get the visible text on a specific row (trimming trailing spaces).
  public func row(_ r: Int) -> String {
    guard r >= 0 && r < screenHeight else { return "" }
    return String(screen[r]).replacingOccurrences(of: "\\s+$", with: "", options: .regularExpression)
  }

  /// Get all non-empty rows as an array of strings.
  public func visibleRows() -> [String] {
    var rows: [String] = []
    for r in 0..<screenHeight {
      let text = row(r)
      if !text.isEmpty { rows.append(text) }
    }
    return rows
  }

  /// The current cursor position.
  public var cursor: (row: Int, col: Int) { (cursorRow, cursorCol) }

  /// Reset for a new test.
  public func reset() {
    keyQueue.removeAll()
    keyIndex = 0
    screen = Array(repeating: Array(repeating: Character(" "), count: screenWidth), count: screenHeight)
    cursorRow = 0
    cursorCol = 0
    maxRowReached = 0
    moveUpHistory.removeAll()
    cursorWentNegative = false
    contentStartRow = 0
  }
}
