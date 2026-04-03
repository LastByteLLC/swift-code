// LineEditor.swift — Interactive line editor with completions and history
//
// Built on TerminalIO protocol (works with TerminalDriver or VirtualTerminalDriver).
// Supports: @file completion, /command type-ahead, command history (up/down),
// cursor movement, Ctrl-U/W, tab accept, escape dismiss.

import Foundation

// MARK: - Completion Protocol

public protocol CompletionProvider: Sendable {
  func completions(for input: String, cursorPosition: Int) -> [Completion]
}

public struct Completion: Sendable {
  public let display: String
  public let insertion: String
  public let replaceFrom: Int

  public init(display: String, insertion: String, replaceFrom: Int) {
    self.display = display
    self.insertion = insertion
    self.replaceFrom = replaceFrom
  }
}

// MARK: - File Completer

public struct FileCompleter: CompletionProvider {
  private let files: FileTools
  private let maxResults: Int

  public init(workingDirectory: String, maxResults: Int = 6) {
    self.files = FileTools(workingDirectory: workingDirectory)
    self.maxResults = maxResults
  }

  public func completions(for input: String, cursorPosition: Int) -> [Completion] {
    let before = String(input.prefix(cursorPosition))
    guard let at = before.lastIndex(of: "@") else { return [] }

    let partial = String(before[before.index(after: at)...]).lowercased()
    let replaceFrom = before.distance(from: before.startIndex, to: at)

    let allFiles = files.listFiles(maxFiles: Config.maxListFiles)
    let matches: [String]

    if partial.isEmpty {
      matches = Array(allFiles.prefix(maxResults))
    } else {
      matches = allFiles.filter {
        $0.lowercased().contains(partial) ||
        ($0 as NSString).lastPathComponent.lowercased().contains(partial)
      }
    }

    return matches.prefix(maxResults).map {
      Completion(display: $0, insertion: "@\($0)", replaceFrom: replaceFrom)
    }
  }
}

// MARK: - Command Completer

public struct CommandCompleter: CompletionProvider {
  public static let allCommands = [
    "/clear", "/context", "/files", "/fork", "/forks",
    "/git", "/help", "/lang", "/metrics", "/model", "/notes", "/paste", "/pastes",
    "/reflections", "/session", "/speak", "/undo", "/unfork", "/usage",
  ]

  private let maxResults: Int

  public init(maxResults: Int = 5) {
    self.maxResults = maxResults
  }

  public func completions(for input: String, cursorPosition: Int) -> [Completion] {
    let trimmed = input.trimmingCharacters(in: .whitespaces)
    guard trimmed.hasPrefix("/") else { return [] }

    let partial = trimmed.lowercased()
    let matches: [String]

    if partial == "/" {
      matches = Array(Self.allCommands.prefix(maxResults))
    } else {
      matches = Self.allCommands.filter { $0.hasPrefix(partial) }
    }

    return matches.prefix(maxResults).map {
      Completion(display: $0, insertion: $0, replaceFrom: 0)
    }
  }
}

// MARK: - Line Editor

/// Result from the line editor including text and selected mode.
public struct LineEditorResult: Sendable {
  public let text: String?
  public let mode: AgentMode
}

/// Interactive line editor with completion dropdown, command history, and mode selection.
public struct LineEditor: Sendable {
  private let prompt: String
  private let promptWidth: Int
  private let completers: [any CompletionProvider]
  private let showModeBar: Bool

  public init(prompt: String, completers: [any CompletionProvider], showModeBar: Bool = true) {
    self.prompt = prompt
    self.promptWidth = TerminalDriver.visibleWidth(prompt)
    self.completers = completers
    self.showModeBar = showModeBar
  }

  /// Read a line interactively. Returns submitted text, or nil on cancel/EOF.
  /// Pass a CommandHistory to enable up/down arrow history navigation.
  public func readLine(driver: any TerminalIO, history: CommandHistory? = nil) -> String? {
    readLineWithMode(driver: driver, history: history).text
  }

  /// Read a line with mode selection. Returns text and chosen mode.
  public func readLineWithMode(driver: any TerminalIO, history: CommandHistory? = nil) -> LineEditorResult {
    var buf: [Character] = []
    var cur = 0
    var completions: [Completion] = []
    var sel = -1
    var historyNav = history.map { HistoryNavigator(history: $0) }
    var prevLines = 1  // tracks how many terminal rows our content spans
    var escPending = false  // true after first Esc press
    var mode: AgentMode = .build

    render(driver: driver, buffer: buf, cursor: cur, completions: completions, selected: sel, prevLines: &prevLines, escHint: escPending, mode: mode)

    while true {
      let key = driver.readKey()

      // Any key other than Esc cancels the "Esc again to clear" state
      if key != .escape && escPending {
        escPending = false
      }

      switch key {
      // --- Text editing ---
      case .char(let ch):
        buf.insert(ch, at: cur)
        cur += 1
        sel = -1
        historyNav?.reset()
        completions = queryCompletions(buf: buf, cur: cur)

      case .backspace:
        guard cur > 0 else { continue }
        cur -= 1
        buf.remove(at: cur)
        sel = -1
        completions = queryCompletions(buf: buf, cur: cur)

      case .delete:
        guard cur < buf.count else { continue }
        buf.remove(at: cur)
        completions = queryCompletions(buf: buf, cur: cur)

      case .ctrlU:
        buf.removeAll()
        cur = 0
        sel = -1
        completions = []

      case .ctrlW:
        while cur > 0 && buf[cur - 1] == " " { cur -= 1; buf.remove(at: cur) }
        while cur > 0 && buf[cur - 1] != " " { cur -= 1; buf.remove(at: cur) }
        sel = -1
        completions = queryCompletions(buf: buf, cur: cur)

      // --- Cursor movement ---
      case .left:
        if cur > 0 { cur -= 1 }
        render(driver: driver, buffer: buf, cursor: cur, completions: completions, selected: sel, prevLines: &prevLines, escHint: escPending, mode: mode)
        continue

      case .right:
        if cur < buf.count { cur += 1 }
        render(driver: driver, buffer: buf, cursor: cur, completions: completions, selected: sel, prevLines: &prevLines, escHint: escPending, mode: mode)
        continue

      case .home:
        cur = 0
        render(driver: driver, buffer: buf, cursor: cur, completions: completions, selected: sel, prevLines: &prevLines, escHint: escPending, mode: mode)
        continue

      case .end:
        cur = buf.count
        render(driver: driver, buffer: buf, cursor: cur, completions: completions, selected: sel, prevLines: &prevLines, escHint: escPending, mode: mode)
        continue

      // --- Up/Down: completions take priority, then history ---
      case .up:
        if !completions.isEmpty {
          sel = sel <= 0 ? completions.count - 1 : sel - 1
        } else if var nav = historyNav {
          if let entry = nav.up(currentInput: String(buf)) {
            buf = Array(entry)
            cur = buf.count
          }
          historyNav = nav
        }

      case .down:
        if !completions.isEmpty {
          sel = sel >= completions.count - 1 ? 0 : sel + 1
        } else if var nav = historyNav {
          if let entry = nav.down() {
            buf = Array(entry)
            cur = buf.count
          }
          historyNav = nav
        }

      // --- Completion accept ---
      case .tab:
        if !completions.isEmpty {
          let idx = sel >= 0 ? sel : 0
          accept(completions[idx], buf: &buf, cur: &cur)
          completions = []
          sel = -1
        }

      // --- Mode cycling (Shift+Tab) ---
      case .shiftTab:
        let allModes = AgentMode.allCases
        if let idx = allModes.firstIndex(of: mode) {
          mode = allModes[(idx + 1) % allModes.count]
        }

      case .escape:
        completions = []
        sel = -1
        if escPending {
          // Second Esc: clear input
          buf.removeAll()
          cur = 0
          escPending = false
        } else if !buf.isEmpty {
          escPending = true
        }

      // --- Multi-line (Alt+Enter or Shift+Enter) ---
      case .shiftEnter:
        buf.insert("\n", at: cur)
        cur += 1
        sel = -1
        completions = []

      // --- Submit ---
      case .enter:
        if sel >= 0 && !completions.isEmpty {
          accept(completions[sel], buf: &buf, cur: &cur)
          completions = []
          sel = -1
        } else {
          finalRender(driver: driver, buffer: buf, prevLines: prevLines)
          historyNav?.reset()
          let text = buf.isEmpty ? nil : String(buf)
          return LineEditorResult(text: text, mode: mode)
        }

      // --- Cancel ---
      case .ctrlC:
        finalRender(driver: driver, buffer: buf, prevLines: prevLines)
        return LineEditorResult(text: nil, mode: mode)

      case .ctrlD:
        if buf.isEmpty {
          finalRender(driver: driver, buffer: buf, prevLines: prevLines)
          return LineEditorResult(text: nil, mode: mode)
        }

      case .ctrlL, .eof:
        if key == .eof { return LineEditorResult(text: nil, mode: mode) }

      case .unknown:
        continue
      }

      render(driver: driver, buffer: buf, cursor: cur, completions: completions, selected: sel, prevLines: &prevLines, escHint: escPending, mode: mode)
    }
  }

  // MARK: - Rendering

  /// Calculate row and column position at a given character offset in the buffer,
  /// accounting for explicit newlines and terminal width wrapping.
  private func cursorPosition(
    in buffer: [Character], at offset: Int, promptWidth: Int, screenWidth: Int
  ) -> (row: Int, col: Int) {
    var row = 0
    var col = promptWidth  // prompt occupies the first line
    for i in 0..<min(offset, buffer.count) {
      if buffer[i] == "\n" {
        row += 1
        col = 0
      } else {
        col += 1
        if col >= screenWidth {
          row += 1
          col = 0
        }
      }
    }
    return (row, col)
  }

  private func render(
    driver: any TerminalIO,
    buffer: [Character],
    cursor: Int,
    completions: [Completion],
    selected: Int,
    prevLines: inout Int,
    escHint: Bool = false,
    mode: AgentMode = .build
  ) {
    let width = max(driver.screenWidth, 20)
    let escSuffix = escHint ? "  " + TerminalDriver.dim("Esc again to clear") : ""

    // Move to the start of our content
    if prevLines > 1 {
      driver.moveUp(prevLines - 1)
    }
    driver.write("\r")
    driver.clearToEndOfScreen()

    // Write prompt + buffer line by line (handle \n explicitly)
    driver.write(prompt)
    for ch in buffer {
      if ch == "\n" {
        driver.newline()
      } else {
        driver.write(String(ch))
      }
    }
    driver.write(escSuffix)

    // Mode bar (below prompt, above completions)
    var extraRows = 0
    if showModeBar {
      driver.newline()
      let modeLabel = "\(mode.icon) \(mode.rawValue.capitalized)"
      let hints = TerminalDriver.dim("(shift+tab to cycle) · esc to interrupt")
      driver.write(modeLabel + " · " + hints)
      extraRows += 1
    }

    // Completions dropdown
    if !completions.isEmpty {
      for (i, c) in completions.enumerated() {
        driver.newline()
        if i == selected {
          driver.write("  " + TerminalDriver.highlight(" \(c.display) "))
        } else {
          driver.write("  " + TerminalDriver.dim(c.display))
        }
      }
      driver.moveUp(completions.count)
    }

    // Move back up past mode bar
    if extraRows > 0 {
      driver.moveUp(extraRows)
    }

    // Position cursor at the correct row+col within the content area
    let curPos = cursorPosition(in: buffer, at: cursor, promptWidth: promptWidth, screenWidth: width)
    let endPos = cursorPosition(in: buffer, at: buffer.count, promptWidth: promptWidth, screenWidth: width)

    let rowsUp = endPos.row - curPos.row
    if rowsUp > 0 { driver.moveUp(rowsUp) }
    driver.moveTo(column: curPos.col + 1)
    driver.flush()

    // Track cursor's row within the content area. On next render,
    // moveUp(prevLines - 1) moves from cursor position back to the top.
    // Completions below the cursor are cleaned by clearToEndOfScreen().
    prevLines = curPos.row + 1
  }

  private func finalRender(driver: any TerminalIO, buffer: [Character], prevLines: Int) {
    if prevLines > 1 {
      driver.moveUp(prevLines - 1)
    }
    driver.write("\r")
    driver.clearToEndOfScreen()
    driver.write(prompt)
    for ch in buffer {
      if ch == "\n" {
        driver.newline()
      } else {
        driver.write(String(ch))
      }
    }
    driver.newline()
    driver.flush()
  }

  // MARK: - Helpers

  private func queryCompletions(buf: [Character], cur: Int) -> [Completion] {
    let input = String(buf)
    for completer in completers {
      let results = completer.completions(for: input, cursorPosition: cur)
      if !results.isEmpty { return results }
    }
    return []
  }

  private func accept(_ completion: Completion, buf: inout [Character], cur: inout Int) {
    let before = Array(String(buf).prefix(completion.replaceFrom))
    let after = Array(String(buf).dropFirst(cur))
    buf = before + Array(completion.insertion) + after
    cur = before.count + completion.insertion.count
  }
}
