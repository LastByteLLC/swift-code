// ActionLog.swift — Live action log with symbols, diffs, and task progress
//
// Renders a scrolling log during pipeline execution:
//   ⏺ One-sentence summaries of each action
//   ⎿  Indented output (bash results, search hits, errors)
//   ✻ Task list with checkboxes (shown with spinner at bottom)
//
// Each entry is a permanent line — the spinner overwrites only the last line.

import Foundation

/// Symbols used in the action log.
public enum LogSymbol {
  /// Action taken (edit, create, bash, search).
  public static let action = "⏺"
  /// Output/result indentation.
  public static let output = "⎿ "
  /// Task list / spinner.
  public static let task = "✻"
  /// Diff addition.
  public static let add = "+"
  /// Diff removal.
  public static let remove = "-"
}

/// Formats and prints live action log entries during pipeline execution.
public struct ActionLog: Sendable {

  public init() {}

  // MARK: - Action Entries

  /// Log a one-sentence action summary.
  public func action(_ message: String) {
    Terminal.line("\(LogSymbol.action) \(message)")
  }

  /// Log indented output below the last action.
  public func output(_ text: String, maxLines: Int = 6) {
    let lines = text.components(separatedBy: "\n")
      .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    let shown = lines.prefix(maxLines)
    let remaining = lines.count - shown.count

    for line in shown {
      Terminal.line("  \(LogSymbol.output)\(Style.dim(line))")
    }
    if remaining > 0 {
      Terminal.line("  \(LogSymbol.output)\(Style.dim("… +\(remaining) lines"))")
    }
  }

  /// Log an error output.
  public func error(_ text: String) {
    Terminal.line("  \(LogSymbol.output)\(Style.red(text))")
  }

  // MARK: - Bash Commands

  /// Log a bash command execution.
  public func bash(_ command: String) {
    let short = String(command.prefix(80))
    action("\(Style.bold("Bash"))(\(short))")
  }

  /// Log bash output.
  public func bashOutput(_ result: String) {
    output(result)
  }

  // MARK: - File Operations

  /// Log a file read.
  public func read(_ path: String) {
    action("\(Style.bold("Read")) \(Style.dim(path))")
  }

  /// Log a file creation.
  public func create(_ path: String, chars: Int) {
    action("\(Style.bold("Created")) \(Style.cyan(path)) (\(chars) chars)")
  }

  /// Log a file write/overwrite.
  public func write(_ path: String, chars: Int) {
    action("\(Style.bold("Written")) \(Style.cyan(path)) (\(chars) chars)")
  }

  /// Log a compact find→replace diff.
  public func edit(_ path: String, find: String, replace: String) {
    action("\(Style.bold("Edit")) \(Style.cyan(path))")
    // Compact diff: show first meaningful line of find/replace
    let findLine = firstMeaningfulLine(find)
    let replaceLine = firstMeaningfulLine(replace)
    Terminal.line("  \(LogSymbol.output)\(Style.red("\(LogSymbol.remove) \(findLine)"))")
    Terminal.line("  \(LogSymbol.output)\(Style.green("\(LogSymbol.add) \(replaceLine)"))")
    if find.contains("\n") || replace.contains("\n") {
      let findLines = find.components(separatedBy: "\n").count
      let replaceLines = replace.components(separatedBy: "\n").count
      Terminal.line("  \(LogSymbol.output)\(Style.dim("(\(findLines) lines → \(replaceLines) lines)"))")
    }
  }

  /// Log a patch application.
  public func patch(_ path: String) {
    action("\(Style.bold("Patched")) \(Style.cyan(path))")
  }

  /// Log a search execution.
  public func search(_ pattern: String, resultCount: Int) {
    action("\(Style.bold("Search")) \(Style.dim(pattern)) → \(resultCount) results")
  }

  // MARK: - Pipeline Stages

  /// Log a classify result.
  public func classified(mode: AgentMode, taskType: String, targets: [String]) {
    let targetStr = targets.isEmpty ? "" : " → \(targets.joined(separator: ", "))"
    action("\(mode.icon) \(taskType)\(targetStr)")
  }

  /// Log plan steps as a brief summary.
  public func planned(stepCount: Int) {
    action("Plan (\(stepCount) steps)")
  }

  /// Log a step starting.
  public func stepStart(_ step: Int, total: Int, instruction: String) {
    let short = String(instruction.prefix(60))
    Terminal.line("  \(LogSymbol.output)\(Style.dim("[\(step)/\(total)]")) \(short)")
  }

  /// Log completion.
  public func done(succeeded: Bool, calls: Int, tokens: Int, files: Int) {
    let icon = succeeded ? Style.green("✓") : Style.yellow("△")
    Terminal.line("\(icon) \(Style.dim("[\(calls) calls | ~\(tokens) tokens | \(files) files]"))")
  }

  // MARK: - Helpers

  private func firstMeaningfulLine(_ text: String) -> String {
    let line = text.components(separatedBy: "\n")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .first { !$0.isEmpty } ?? text
    return String(line.prefix(80))
  }
}
