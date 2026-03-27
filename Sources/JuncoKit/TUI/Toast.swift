// Toast.swift — In-TUI notification messages
//
// Styled single-line messages that appear between output and the next prompt.
// Not overlays — they're permanent lines styled to look transient.
// Supports info, success, warning, and error severities.

import Foundation

/// Severity levels for toast messages.
public enum ToastLevel: Sendable {
  case info, success, warning, error
}

/// Renders styled toast notification lines in the terminal.
public enum Toast {
  /// Show a toast message. Renders as a styled line to stdout.
  public static func show(_ message: String, level: ToastLevel = .info) {
    let prefix: String
    switch level {
    case .info:    prefix = Style.cyan("  \u{2139} ")
    case .success: prefix = Style.green("  \u{2713} ")
    case .warning: prefix = Style.yellow("  \u{26A0} ")
    case .error:   prefix = Style.red("  \u{2717} ")
    }
    Terminal.line(prefix + Style.dim(message))
  }

  /// Format a build result as a toast.
  public static func buildResult(_ result: String) {
    if result.contains("FAIL") || result.contains("error") {
      show(result.components(separatedBy: "\n").first ?? result, level: .error)
    } else {
      show(result.components(separatedBy: "\n").first ?? result, level: .success)
    }
  }

  /// Format a timing message.
  public static func timing(_ label: String, seconds: TimeInterval) {
    show("\(label) (\(String(format: "%.1fs", seconds)))", level: .info)
  }
}
