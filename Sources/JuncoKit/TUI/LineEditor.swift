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
    "/clear", "/context", "/domain", "/files", "/fork", "/forks",
    "/git", "/help", "/lang", "/metrics", "/notes", "/paste", "/pastes",
    "/reflections", "/search", "/session", "/speak", "/undo", "/unfork",
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

/// Interactive line editor with completion dropdown and command history.
public struct LineEditor: Sendable {
  private let prompt: String
  private let promptWidth: Int
  private let completers: [any CompletionProvider]

  public init(prompt: String, completers: [any CompletionProvider]) {
    self.prompt = prompt
    self.promptWidth = TerminalDriver.visibleWidth(prompt)
    self.completers = completers
  }

  /// Read a line interactively. Returns submitted text, or nil on cancel/EOF.
  /// Pass a CommandHistory to enable up/down arrow history navigation.
  public func readLine(driver: any TerminalIO, history: CommandHistory? = nil) -> String? {
    var buf: [Character] = []
    var cur = 0
    var completions: [Completion] = []
    var sel = -1
    var historyNav = history.map { HistoryNavigator(history: $0) }

    render(driver: driver, buffer: buf, cursor: cur, completions: completions, selected: sel)

    while true {
      let key = driver.readKey()

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
        render(driver: driver, buffer: buf, cursor: cur, completions: completions, selected: sel)
        continue

      case .right:
        if cur < buf.count { cur += 1 }
        render(driver: driver, buffer: buf, cursor: cur, completions: completions, selected: sel)
        continue

      case .home:
        cur = 0
        render(driver: driver, buffer: buf, cursor: cur, completions: completions, selected: sel)
        continue

      case .end:
        cur = buf.count
        render(driver: driver, buffer: buf, cursor: cur, completions: completions, selected: sel)
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

      case .escape:
        completions = []
        sel = -1

      // --- Submit ---
      case .enter:
        if sel >= 0 && !completions.isEmpty {
          accept(completions[sel], buf: &buf, cur: &cur)
          completions = []
          sel = -1
        } else {
          finalRender(driver: driver, buffer: buf)
          historyNav?.reset()
          return buf.isEmpty ? nil : String(buf)
        }

      // --- Cancel ---
      case .ctrlC:
        finalRender(driver: driver, buffer: buf)
        return nil

      case .ctrlD:
        if buf.isEmpty {
          finalRender(driver: driver, buffer: buf)
          return nil
        }

      case .ctrlL, .eof:
        if key == .eof { return nil }

      case .unknown:
        continue
      }

      render(driver: driver, buffer: buf, cursor: cur, completions: completions, selected: sel)
    }
  }

  // MARK: - Rendering

  private func render(
    driver: any TerminalIO,
    buffer: [Character],
    cursor: Int,
    completions: [Completion],
    selected: Int
  ) {
    let text = String(buffer)

    driver.beginRedraw()
    driver.write(prompt)
    driver.write(text)

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

    driver.moveTo(column: promptWidth + cursor + 1)
    driver.flush()
  }

  private func finalRender(driver: any TerminalIO, buffer: [Character]) {
    driver.beginRedraw()
    driver.write(prompt)
    driver.write(String(buffer))
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
