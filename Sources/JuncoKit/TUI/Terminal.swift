// Terminal.swift — ANSI terminal utilities for the TUI
//
// Thin wrapper over ANSI escape codes for colored output,
// status lines, and cursor control. No external dependencies.

import Foundation

/// ANSI color and style helpers.
public enum Style {
  // Colors
  public static func dim(_ s: String) -> String { "\u{1B}[2m\(s)\u{1B}[0m" }
  public static func bold(_ s: String) -> String { "\u{1B}[1m\(s)\u{1B}[0m" }
  public static func green(_ s: String) -> String { "\u{1B}[32m\(s)\u{1B}[0m" }
  public static func red(_ s: String) -> String { "\u{1B}[31m\(s)\u{1B}[0m" }
  public static func yellow(_ s: String) -> String { "\u{1B}[33m\(s)\u{1B}[0m" }
  public static func cyan(_ s: String) -> String { "\u{1B}[36m\(s)\u{1B}[0m" }
  public static func blue(_ s: String) -> String { "\u{1B}[34m\(s)\u{1B}[0m" }
  public static func magenta(_ s: String) -> String { "\u{1B}[35m\(s)\u{1B}[0m" }

  // Status indicators
  public static let ok = green("ok")
  public static let err = red("!!")
  public static let working = yellow(">>")
  public static let info = cyan("--")
}

/// Terminal output helpers.
public enum Terminal {
  /// Whether we're connected to a real terminal (not piped).
  public static var isInteractive: Bool {
    isatty(STDOUT_FILENO) != 0
  }

  /// Whether we're currently in alternate screen mode.
  nonisolated(unsafe) private static var inAlternateScreen = false

  /// Enter the alternate screen buffer and clear it.
  /// The user's existing terminal content is preserved underneath.
  /// Call `leaveFullScreen()` on exit to restore it.
  public static func enterFullScreen() {
    guard isInteractive else { return }
    print("\u{1B}[?1049h", terminator: "")  // Switch to alternate buffer
    print("\u{1B}[2J", terminator: "")       // Clear screen
    print("\u{1B}[H", terminator: "")        // Cursor to top-left
    fflush(stdout)
    inAlternateScreen = true

    // Register atexit handler so we restore even on unexpected exit
    atexit {
      if Terminal.inAlternateScreen {
        print("\u{1B}[?1049l", terminator: "")
        fflush(stdout)
      }
    }
  }

  /// Leave the alternate screen buffer, restoring the original terminal content.
  public static func leaveFullScreen() {
    guard isInteractive, inAlternateScreen else { return }
    print("\u{1B}[?1049l", terminator: "")
    fflush(stdout)
    inAlternateScreen = false
  }

  /// Clear the current line and move cursor to start.
  public static func clearLine() {
    if isInteractive {
      print("\u{1B}[2K\r", terminator: "")
    }
  }

  /// Show a status line that will be overwritten by the next status/output.
  /// In piped mode, emits plain text to stderr so status is visible.
  public static func status(_ message: String) {
    if isInteractive {
      clearLine()
      print(Style.dim(message), terminator: "")
      fflush(stdout)
    } else {
      FileHandle.standardError.write("[status] \(message)\n".data(using: .utf8) ?? Data())
    }
  }

  /// Print a permanent line (won't be overwritten).
  /// In piped mode, strips ANSI codes for clean output.
  public static func line(_ message: String) {
    if isInteractive {
      clearLine()
      print(message)
    } else {
      // Strip ANSI escape sequences for piped output
      let clean = message.replacingOccurrences(
        of: "\u{1B}\\[[0-9;]*[a-zA-Z]", with: "", options: .regularExpression
      )
      print(clean)
    }
  }

  /// Print a section header.
  public static func header(_ title: String) {
    line(Style.bold(title))
  }

  /// Set the terminal window/tab title. Works in Terminal.app, iTerm2, Ghostty, VS Code.
  public static func setTitle(_ title: String) {
    if isInteractive {
      print("\u{1B}]0;\(title)\u{07}", terminator: "")
      fflush(stdout)
    }
  }

  /// Detect terminal emulator from environment.
  public static var terminalApp: String {
    if let program = ProcessInfo.processInfo.environment["TERM_PROGRAM"] {
      return program
    }
    return "unknown"
  }

  /// Print a divider.
  public static func divider() {
    line(Style.dim(String(repeating: "─", count: min(terminalWidth(), 60))))
  }

  /// Get terminal width, with fallback.
  public static func terminalWidth() -> Int {
    var w = winsize()
    if ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0 {
      return Int(w.ws_col)
    }
    return 80
  }
}

/// Formatted display for session metrics.
public struct MetricsDisplay {
  public let metrics: SessionMetrics
  public let domain: DomainConfig
  public let startTime: Date
  public let reflectionCount: Int

  public init(
    metrics: SessionMetrics, domain: DomainConfig,
    startTime: Date, reflectionCount: Int = 0
  ) {
    self.metrics = metrics
    self.domain = domain
    self.startTime = startTime
    self.reflectionCount = reflectionCount
  }

  /// Format metrics as a compact summary string.
  public func summary() -> String {
    let elapsed = Date().timeIntervalSince(startTime)
    let elapsedStr = String(format: "%.1fs", elapsed)

    var parts: [String] = []
    parts.append("tasks:\(metrics.tasksCompleted)")
    parts.append("calls:\(metrics.totalLLMCalls)")
    parts.append("tokens:~\(metrics.totalTokensUsed)")
    parts.append("files:\(metrics.filesModified)")
    if metrics.bashCommandsRun > 0 { parts.append("cmds:\(metrics.bashCommandsRun)") }
    if reflectionCount > 0 { parts.append("reflections:\(reflectionCount)") }
    parts.append("time:\(elapsedStr)")

    // Rough energy estimate: ~3W Neural Engine active × time
    let energyWh = 3.0 * elapsed / 3600.0
    parts.append(String(format: "energy:~%.2fWh", energyWh))

    return parts.joined(separator: " | ")
  }

  /// Formatted header for display.
  public func header() -> String {
    Style.dim("[\(summary())]")
  }
}
