// MarkdownRenderer.swift — Render markdown to styled terminal output
//
// Converts common markdown elements to ANSI-styled text:
// - **bold** → bold
// - `code` → cyan
// - ```blocks``` → indented + dimmed border
// - # headers → bold
// - - lists → bullet points
// - [links](url) → underlined

import Foundation

/// Renders markdown text as ANSI-styled terminal output.
public struct MarkdownRenderer: Sendable {
  public init() {}

  /// Render markdown string to ANSI-styled terminal output.
  public func render(_ markdown: String) -> String {
    var lines = markdown.components(separatedBy: "\n")
    var output: [String] = []
    var inCodeBlock = false

    var i = 0
    while i < lines.count {
      let line = lines[i]

      // Code block toggle
      if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
        inCodeBlock.toggle()
        if inCodeBlock {
          output.append(Style.dim("  \u{2502}"))
        } else {
          output.append(Style.dim("  \u{2502}"))
        }
        i += 1
        continue
      }

      if inCodeBlock {
        output.append(Style.dim("  \u{2502} ") + Style.cyan(line))
        i += 1
        continue
      }

      // Headers
      if line.hasPrefix("### ") {
        output.append(Style.bold(String(line.dropFirst(4))))
      } else if line.hasPrefix("## ") {
        output.append("")
        output.append(Style.bold(String(line.dropFirst(3))))
      } else if line.hasPrefix("# ") {
        output.append("")
        output.append(Style.bold(String(line.dropFirst(2))))
        output.append(Style.dim(String(repeating: "\u{2500}", count: min(60, line.count))))
      }
      // List items
      else if line.trimmingCharacters(in: .whitespaces).hasPrefix("- ") {
        let indent = line.prefix(while: { $0 == " " }).count
        let text = line.trimmingCharacters(in: .whitespaces).dropFirst(2)
        output.append(String(repeating: " ", count: indent) + "  \u{2022} " + renderInline(String(text)))
      } else if let match = line.firstMatch(of: /^\s*(\d+)\.\s+(.+)/) {
        let num = match.1
        let text = match.2
        output.append("  \(num). " + renderInline(String(text)))
      }
      // Regular text
      else {
        output.append(renderInline(line))
      }

      i += 1
    }

    return output.joined(separator: "\n")
  }

  /// Render inline markdown: bold, code, links.
  private func renderInline(_ text: String) -> String {
    var result = text

    // Bold: **text**
    result = result.replacingOccurrences(
      of: "\\*\\*(.+?)\\*\\*",
      with: "\u{1B}[1m$1\u{1B}[0m",
      options: .regularExpression
    )

    // Inline code: `text`
    result = result.replacingOccurrences(
      of: "`([^`]+)`",
      with: "\u{1B}[36m$1\u{1B}[0m",
      options: .regularExpression
    )

    // Links: [text](url) → text (underlined)
    result = result.replacingOccurrences(
      of: "\\[([^\\]]+)\\]\\([^)]+\\)",
      with: "\u{1B}[4m$1\u{1B}[0m",
      options: .regularExpression
    )

    return result
  }
}
