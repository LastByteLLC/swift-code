// DiffRenderer.swift — Colored diff display in terminal
//
// Renders unified diffs with red (removed) / green (added) coloring.
// Used to show what the agent changed after edits.

import Foundation

/// Renders colored diffs in the terminal.
public struct DiffRenderer: Sendable {
  public init() {}

  /// Render a unified diff with colors.
  public func render(_ diff: String) -> String {
    diff.components(separatedBy: "\n").map { line in
      if line.hasPrefix("+++") || line.hasPrefix("---") {
        return Style.bold(line)
      } else if line.hasPrefix("@@") {
        return Style.cyan(line)
      } else if line.hasPrefix("+") {
        return Style.green(line)
      } else if line.hasPrefix("-") {
        return Style.red(line)
      } else {
        return line
      }
    }.joined(separator: "\n")
  }

  /// Generate and render a before/after diff for a file edit.
  public func renderEdit(path: String, before: String, after: String) -> String {
    let preview = DiffPreview()
    let diff = preview.diffWrite(filePath: path, existingContent: before, newContent: after)
    return render(diff)
  }
}
