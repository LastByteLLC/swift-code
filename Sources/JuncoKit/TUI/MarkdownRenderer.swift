// MarkdownRenderer.swift — Render markdown to styled terminal output
//
// Converts markdown elements to ANSI-styled text with syntax highlighting:
// - **bold** → bold
// - *italic* → italic (dim)
// - `code` → cyan
// - ```lang blocks → syntax-highlighted with border
// - # headers → bold with underline
// - - lists → bullet points
// - [links](url) → underlined

import Foundation

/// Renders markdown text as ANSI-styled terminal output.
public struct MarkdownRenderer: Sendable {
  private let highlighter: SyntaxHighlighter

  public init() {
    self.highlighter = SyntaxHighlighter()
  }

  /// Render markdown string to ANSI-styled terminal output.
  public func render(_ markdown: String) -> String {
    let lines = markdown.components(separatedBy: "\n")
    var output: [String] = []
    var inCodeBlock = false
    var codeLanguage = ""
    var codeBuffer: [String] = []

    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespaces)

      // Code block toggle
      if trimmed.hasPrefix("```") {
        if inCodeBlock {
          // End code block — render with syntax highlighting
          let code = codeBuffer.joined(separator: "\n")
          let highlighted = highlighter.highlight(code, language: codeLanguage)
          for codeLine in highlighted.components(separatedBy: "\n") {
            output.append("  \(Style.dim("\u{2502}")) \(codeLine)")
          }
          output.append("  \(Style.dim("\u{2502}"))")
          codeBuffer.removeAll()
          inCodeBlock = false
        } else {
          // Start code block — extract language
          codeLanguage = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
          inCodeBlock = true
          output.append("  \(Style.dim("\u{2502}"))")
        }
        continue
      }

      if inCodeBlock {
        codeBuffer.append(line)
        continue
      }

      // Headers
      if trimmed.hasPrefix("### ") {
        output.append(Style.bold(String(trimmed.dropFirst(4))))
      } else if trimmed.hasPrefix("## ") {
        output.append("")
        output.append(Style.bold(String(trimmed.dropFirst(3))))
      } else if trimmed.hasPrefix("# ") {
        output.append("")
        let title = String(trimmed.dropFirst(2))
        output.append(Style.bold(title))
        output.append(Style.dim(String(repeating: "\u{2500}", count: min(60, title.count + 4))))
      }
      // Unordered list items
      else if trimmed.hasPrefix("- ") || trimmed.hasPrefix("* ") {
        let indent = line.prefix(while: { $0 == " " }).count
        let text = String(trimmed.dropFirst(2))
        output.append(String(repeating: " ", count: indent) + "  \u{2022} " + renderInline(text))
      }
      // Ordered list items
      else if let match = trimmed.firstMatch(of: /^(\d+)\.\s+(.+)/) {
        output.append("  \(match.1). " + renderInline(String(match.2)))
      }
      // Horizontal rule
      else if trimmed == "---" || trimmed == "***" || trimmed == "___" {
        output.append(Style.dim(String(repeating: "\u{2500}", count: 40)))
      }
      // Blockquote
      else if trimmed.hasPrefix("> ") {
        let text = String(trimmed.dropFirst(2))
        output.append("  \(Style.dim("\u{2502}")) \(Style.dim(renderInline(text)))")
      }
      // Empty line
      else if trimmed.isEmpty {
        output.append("")
      }
      // Regular text
      else {
        output.append(renderInline(line))
      }
    }

    // Handle unclosed code block
    if inCodeBlock && !codeBuffer.isEmpty {
      let code = codeBuffer.joined(separator: "\n")
      let highlighted = highlighter.highlight(code, language: codeLanguage)
      for codeLine in highlighted.components(separatedBy: "\n") {
        output.append("  \(Style.dim("\u{2502}")) \(codeLine)")
      }
    }

    return output.joined(separator: "\n")
  }

  /// Render inline markdown: bold, italic, code, links.
  private func renderInline(_ text: String) -> String {
    var result = text

    // Bold: **text**
    result = result.replacingOccurrences(
      of: "\\*\\*(.+?)\\*\\*",
      with: "\u{1B}[1m$1\u{1B}[0m",
      options: .regularExpression
    )

    // Italic: *text* (but not ** which is bold)
    result = result.replacingOccurrences(
      of: "(?<!\\*)\\*(?!\\*)(.+?)(?<!\\*)\\*(?!\\*)",
      with: "\u{1B}[3m$1\u{1B}[0m",
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
      of: "\\[([^\\]]+)\\]\\(([^)]+)\\)",
      with: "\u{1B}[4m$1\u{1B}[0m",
      options: .regularExpression
    )

    return result
  }
}
