// LineEditor.swift — Interactive line editor with pluggable completions
//
// Built on TerminalDriver. Supports:
// - Full cursor movement (arrows, home, end)
// - @file path completion with dropdown
// - /command type-ahead
// - Ctrl-U (clear line), Ctrl-W (delete word), Ctrl-C (cancel)
//
// Rendering: each keypress triggers a full redraw via TerminalDriver.beginRedraw().
// All output is buffered and flushed once per render cycle — no tearing.
//
// Future extensions plug in via CompletionProvider protocol:
// syntax highlighting, multi-choice prompts, etc.

import Foundation

// MARK: - Completion Protocol

/// Provides contextual completions for user input.
public protocol CompletionProvider: Sendable {
  /// Return completions for the current input state.
  /// Empty array means "no completions from this provider."
  func completions(for input: String, cursorPosition: Int) -> [Completion]
}

/// A single completion suggestion.
public struct Completion: Sendable {
  /// Text shown in the dropdown.
  public let display: String
  /// Text inserted into the buffer when accepted.
  public let insertion: String
  /// Character offset in the buffer where insertion replaces from.
  public let replaceFrom: Int

  public init(display: String, insertion: String, replaceFrom: Int) {
    self.display = display
    self.insertion = insertion
    self.replaceFrom = replaceFrom
  }
}

// MARK: - File Completer

/// Completes @file paths from the project's file listing.
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

/// Type-ahead for /slash commands.
public struct CommandCompleter: CompletionProvider {
  public static let allCommands = [
    "/clear", "/context", "/domain", "/git",
    "/help", "/metrics", "/paste", "/pastes",
    "/reflections", "/undo",
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

/// Interactive line editor with completion dropdown.
///
/// Usage:
/// ```swift
/// let driver = TerminalDriver()!
/// let editor = LineEditor(prompt: "junco> ", completers: [...])
/// driver.enableRawMode()
/// let input = editor.readLine(driver: driver)
/// driver.restoreMode()
/// ```
public struct LineEditor: Sendable {
  private let prompt: String
  private let promptWidth: Int
  private let completers: [any CompletionProvider]

  public init(prompt: String, completers: [any CompletionProvider]) {
    self.prompt = prompt
    self.promptWidth = TerminalDriver.visibleWidth(prompt)
    self.completers = completers
  }

  /// Read a line interactively. Returns the submitted text, or nil on cancel/EOF.
  public func readLine(driver: TerminalDriver) -> String? {
    var buf: [Character] = []
    var cur = 0
    var completions: [Completion] = []
    var sel = -1  // -1 = no selection

    render(driver: driver, buffer: buf, cursor: cur, completions: completions, selected: sel)

    while true {
      let key = driver.readKey()

      switch key {
      // --- Text editing ---
      case .char(let ch):
        buf.insert(ch, at: cur)
        cur += 1
        sel = -1
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

      case .ctrlU:  // Clear entire line
        buf.removeAll()
        cur = 0
        sel = -1
        completions = []

      case .ctrlW:  // Delete previous word
        while cur > 0 && buf[cur - 1] == " " { cur -= 1; buf.remove(at: cur) }
        while cur > 0 && buf[cur - 1] != " " { cur -= 1; buf.remove(at: cur) }
        sel = -1
        completions = queryCompletions(buf: buf, cur: cur)

      // --- Cursor movement ---
      case .left:
        if cur > 0 { cur -= 1 }
        continue  // Don't requery completions on pure movement

      case .right:
        if cur < buf.count { cur += 1 }
        continue

      case .home:
        cur = 0
        continue

      case .end:
        cur = buf.count
        continue

      // --- Completion navigation ---
      case .up:
        if !completions.isEmpty {
          sel = sel <= 0 ? completions.count - 1 : sel - 1
        }

      case .down:
        if !completions.isEmpty {
          sel = sel >= completions.count - 1 ? 0 : sel + 1
        }

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

      // --- Submission ---
      case .enter:
        if sel >= 0 && !completions.isEmpty {
          // Accept the selected completion
          accept(completions[sel], buf: &buf, cur: &cur)
          completions = []
          sel = -1
        } else {
          // Submit the line
          finalRender(driver: driver, buffer: buf)
          return buf.isEmpty ? nil : String(buf)
        }

      // --- Cancel / EOF ---
      case .ctrlC:
        finalRender(driver: driver, buffer: buf)
        return nil

      case .ctrlD:
        if buf.isEmpty {
          finalRender(driver: driver, buffer: buf)
          return nil
        }

      case .ctrlL:  // Refresh screen
        break

      case .eof:
        return nil

      case .unknown:
        continue
      }

      render(driver: driver, buffer: buf, cursor: cur, completions: completions, selected: sel)
    }
  }

  // MARK: - Rendering

  /// Full render cycle: clear prompt region, draw prompt + buffer + completions, position cursor.
  private func render(
    driver: TerminalDriver,
    buffer: [Character],
    cursor: Int,
    completions: [Completion],
    selected: Int
  ) {
    let text = String(buffer)

    // 1. Move to column 1 and clear everything from here down
    driver.beginRedraw()

    // 2. Draw prompt + input text
    driver.write(prompt)
    driver.write(text)

    // 3. Draw completions below (each on its own line)
    if !completions.isEmpty {
      for (i, c) in completions.enumerated() {
        driver.newline()
        if i == selected {
          driver.write("  " + TerminalDriver.highlight(" \(c.display) "))
        } else {
          driver.write("  " + TerminalDriver.dim(c.display))
        }
      }

      // 4. Move cursor back up to the prompt line
      driver.moveUp(completions.count)
    }

    // 5. Position cursor at the right column in the input
    driver.moveTo(column: promptWidth + cursor + 1)

    // 6. Single flush — everything appears at once
    driver.flush()
  }

  /// Final render before returning: clear completions, show the final line, newline.
  private func finalRender(driver: TerminalDriver, buffer: [Character]) {
    driver.beginRedraw()
    driver.write(prompt)
    driver.write(String(buffer))
    driver.newline()
    driver.flush()
  }

  // MARK: - Completion Logic

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
