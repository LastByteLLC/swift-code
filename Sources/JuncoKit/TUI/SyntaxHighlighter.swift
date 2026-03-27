// SyntaxHighlighter.swift — Regex-based syntax highlighting for terminal output
//
// Highlights code blocks in supported languages: Swift, JavaScript, TypeScript,
// HTML, CSS, XML/plist, JSON, bash. Applied inside fenced code blocks (```lang).

import Foundation

/// Applies syntax highlighting to a code string based on language.
public struct SyntaxHighlighter: Sendable {
  public init() {}

  /// Highlight a code string for a given language identifier.
  public func highlight(_ code: String, language: String) -> String {
    switch language.lowercased() {
    case "swift":                       return highlightSwift(code)
    case "js", "javascript":            return highlightJS(code)
    case "ts", "typescript":            return highlightTS(code)
    case "html", "xml", "plist":        return highlightXML(code)
    case "css":                         return highlightCSS(code)
    case "json":                        return highlightJSON(code)
    case "bash", "sh", "shell", "zsh":  return highlightBash(code)
    default:                            return highlightGeneric(code)
    }
  }

  // MARK: - Swift

  private func highlightSwift(_ code: String) -> String {
    var result = code
    result = highlightComments(result)
    result = highlightStrings(result)
    result = colorizeKeywords(result, keywords: [
      "import", "func", "let", "var", "struct", "class", "enum", "protocol",
      "actor", "extension", "if", "else", "guard", "switch", "case", "default",
      "for", "while", "return", "throw", "throws", "try", "catch", "do", "async",
      "await", "public", "private", "internal", "open", "static", "override",
      "init", "deinit", "self", "Self", "nil", "true", "false", "in", "where",
      "typealias", "associatedtype", "some", "any", "weak", "unowned", "lazy",
      "mutating", "nonisolated", "Sendable", "MainActor",
    ])
    result = colorizeTypes(result, types: [
      "String", "Int", "Bool", "Double", "Float", "Array", "Dictionary",
      "Optional", "Result", "Error", "URL", "Data", "Date", "UUID", "Set",
      "Task", "AsyncStream", "Void",
    ])
    result = colorizeNumbers(result)
    return result
  }

  // MARK: - JavaScript / TypeScript

  private func highlightJS(_ code: String) -> String {
    var result = code
    result = highlightComments(result)
    result = highlightStrings(result)
    result = colorizeKeywords(result, keywords: [
      "const", "let", "var", "function", "class", "extends", "return",
      "if", "else", "for", "while", "do", "switch", "case", "default",
      "break", "continue", "import", "export", "from", "async", "await",
      "try", "catch", "throw", "new", "this", "super", "typeof", "instanceof",
      "true", "false", "null", "undefined", "yield", "of", "in",
    ])
    result = colorizeNumbers(result)
    return result
  }

  private func highlightTS(_ code: String) -> String {
    var result = highlightJS(code)
    result = colorizeKeywords(result, keywords: [
      "type", "interface", "enum", "implements", "declare", "readonly",
      "as", "is", "keyof", "infer", "never", "unknown", "any",
    ])
    return result
  }

  // MARK: - HTML / XML / Plist

  private func highlightXML(_ code: String) -> String {
    var result = code
    // Tags: <tagname ...> and </tagname>
    result = result.replacingOccurrences(
      of: "(</?)(\\w+)",
      with: "$1\(esc(.cyan))$2\(esc(.reset))",
      options: .regularExpression
    )
    // Attribute names: name=
    result = result.replacingOccurrences(
      of: "\\s(\\w+)=",
      with: " \(esc(.yellow))$1\(esc(.reset))=",
      options: .regularExpression
    )
    // Attribute values: "..."
    result = highlightStrings(result)
    // Comments
    result = result.replacingOccurrences(
      of: "(<!--[\\s\\S]*?-->)",
      with: "\(esc(.dim))$1\(esc(.reset))",
      options: .regularExpression
    )
    return result
  }

  // MARK: - CSS

  private func highlightCSS(_ code: String) -> String {
    var result = code
    result = highlightComments(result)
    result = highlightStrings(result)
    // Properties: name:
    result = result.replacingOccurrences(
      of: "([a-z-]+)\\s*:",
      with: "\(esc(.cyan))$1\(esc(.reset)):",
      options: .regularExpression
    )
    // Values with units
    result = colorizeNumbers(result)
    // Selectors (lines that don't start with space and end with {)
    result = result.replacingOccurrences(
      of: "^([.#]?[\\w-]+)",
      with: "\(esc(.yellow))$1\(esc(.reset))",
      options: .regularExpression
    )
    return result
  }

  // MARK: - JSON

  private func highlightJSON(_ code: String) -> String {
    var result = code
    // Keys: "key":
    result = result.replacingOccurrences(
      of: "(\"[^\"]+\")\\s*:",
      with: "\(esc(.cyan))$1\(esc(.reset)):",
      options: .regularExpression
    )
    // String values
    result = result.replacingOccurrences(
      of: ":\\s*(\"[^\"]*\")",
      with: ": \(esc(.green))$1\(esc(.reset))",
      options: .regularExpression
    )
    result = colorizeNumbers(result)
    // true/false/null
    result = colorizeKeywords(result, keywords: ["true", "false", "null"])
    return result
  }

  // MARK: - Bash

  private func highlightBash(_ code: String) -> String {
    var result = code
    // Comments
    result = result.replacingOccurrences(
      of: "(#[^\n]*)",
      with: "\(esc(.dim))$1\(esc(.reset))",
      options: .regularExpression
    )
    result = highlightStrings(result)
    result = colorizeKeywords(result, keywords: [
      "if", "then", "else", "elif", "fi", "for", "while", "do", "done",
      "case", "esac", "function", "return", "exit", "echo", "export",
      "source", "local", "readonly", "set", "unset",
    ])
    // Variables: $VAR ${VAR}
    result = result.replacingOccurrences(
      of: "(\\$\\{?[A-Za-z_][A-Za-z0-9_]*\\}?)",
      with: "\(esc(.yellow))$1\(esc(.reset))",
      options: .regularExpression
    )
    return result
  }

  // MARK: - Generic (fallback)

  private func highlightGeneric(_ code: String) -> String {
    var result = code
    result = highlightComments(result)
    result = highlightStrings(result)
    result = colorizeNumbers(result)
    return result
  }

  // MARK: - Shared Patterns

  private func highlightComments(_ code: String) -> String {
    var result = code
    // Single-line: // ...
    result = result.replacingOccurrences(
      of: "(//[^\n]*)",
      with: "\(esc(.dim))$1\(esc(.reset))",
      options: .regularExpression
    )
    // Multi-line: /* ... */
    result = result.replacingOccurrences(
      of: "(/\\*[\\s\\S]*?\\*/)",
      with: "\(esc(.dim))$1\(esc(.reset))",
      options: .regularExpression
    )
    return result
  }

  private func highlightStrings(_ code: String) -> String {
    // Double-quoted strings
    code.replacingOccurrences(
      of: "(\"[^\"\\\\]*(?:\\\\.[^\"\\\\]*)*\")",
      with: "\(esc(.green))$1\(esc(.reset))",
      options: .regularExpression
    )
  }

  private func colorizeKeywords(_ code: String, keywords: [String]) -> String {
    var result = code
    for kw in keywords {
      // Word-boundary match to avoid partial highlights
      result = result.replacingOccurrences(
        of: "\\b(\(NSRegularExpression.escapedPattern(for: kw)))\\b",
        with: "\(esc(.magenta))$1\(esc(.reset))",
        options: .regularExpression
      )
    }
    return result
  }

  private func colorizeTypes(_ code: String, types: [String]) -> String {
    var result = code
    for t in types {
      result = result.replacingOccurrences(
        of: "\\b(\(NSRegularExpression.escapedPattern(for: t)))\\b",
        with: "\(esc(.blue))$1\(esc(.reset))",
        options: .regularExpression
      )
    }
    return result
  }

  private func colorizeNumbers(_ code: String) -> String {
    code.replacingOccurrences(
      of: "\\b(\\d+\\.?\\d*)\\b",
      with: "\(esc(.cyan))$1\(esc(.reset))",
      options: .regularExpression
    )
  }

  // MARK: - ANSI Escape Helpers

  private enum ANSICode: String {
    case reset   = "0"
    case dim     = "2"
    case green   = "32"
    case yellow  = "33"
    case blue    = "34"
    case magenta = "35"
    case cyan    = "36"
  }

  private func esc(_ code: ANSICode) -> String {
    "\u{1B}[\(code.rawValue)m"
  }
}
