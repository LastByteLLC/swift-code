// ErrorRegionExtractor.swift — Parse build errors and extract enclosing code blocks
//
// Used by the targeted retry system to send only the broken code region
// to the model for fixing, instead of the entire file.

import Foundation

/// A region of code extracted from a file, with its line range.
public struct CodeRegion: Sendable {
  /// The extracted code text.
  public let text: String
  /// Start line (0-indexed) in the original file.
  public let startLine: Int
  /// End line (0-indexed, inclusive) in the original file.
  public let endLine: Int
}

/// Parsed build error with file location.
public struct BuildError: Sendable {
  public let filePath: String
  public let line: Int
  public let column: Int
  public let message: String

  /// Single-line summary for LLM prompts.
  public var oneLiner: String {
    "\(filePath):\(line): \(message)"
  }
}

public struct ErrorRegionExtractor: Sendable {

  public init() {}

  // MARK: - Error Parsing

  /// Parse swiftc/swift build error output into structured errors.
  /// Handles format: `path/File.swift:12:5: error: message`
  public func parseErrors(_ output: String) -> [BuildError] {
    var errors: [BuildError] = []
    let lines = output.components(separatedBy: "\n")

    for line in lines {
      // Match: path.swift:LINE:COL: error: message
      // or:    path.swift:LINE:COL: warning: message
      guard line.contains(": error:") || line.contains(": warning:") else { continue }

      let parts = line.components(separatedBy: ":")
      guard parts.count >= 5 else { continue }

      let filePath = parts[0]
      guard let lineNum = Int(parts[1].trimmingCharacters(in: .whitespaces)),
            let col = Int(parts[2].trimmingCharacters(in: .whitespaces)) else { continue }

      // Everything after "error: " or "warning: " is the message
      let messageStart = line.range(of: "error: ")?.upperBound
        ?? line.range(of: "warning: ")?.upperBound
      let message = messageStart.map { String(line[$0...]) } ?? parts.dropFirst(4).joined(separator: ":")

      errors.append(BuildError(
        filePath: filePath,
        line: lineNum,
        column: col,
        message: message.trimmingCharacters(in: .whitespaces)
      ))
    }

    return errors
  }

  // MARK: - Region Extraction

  /// Extract the enclosing function/type around an error line.
  /// Walks backward to find the containing `func`, `struct`, `class`, `actor`, or `enum`,
  /// then forward to find its matching closing `}`.
  public func extract(content: String, errorLine: Int) -> CodeRegion? {
    let lines = content.components(separatedBy: "\n")
    guard errorLine > 0, errorLine <= lines.count else { return nil }

    let targetLine = errorLine - 1 // Convert to 0-indexed

    // Walk backward to find the enclosing declaration
    var startLine = targetLine
    let declarationPattern = #"^\s*(public |private |internal |fileprivate |open )?(static )?(func |struct |class |actor |enum |init\(|var |let )"#

    while startLine > 0 {
      if lines[startLine].range(of: declarationPattern, options: .regularExpression) != nil {
        break
      }
      startLine -= 1
    }

    // Walk forward from the declaration to find matching closing brace
    var braceDepth = 0
    var endLine = startLine
    var foundOpenBrace = false

    for i in startLine..<lines.count {
      for char in lines[i] {
        if char == "{" { braceDepth += 1; foundOpenBrace = true }
        if char == "}" { braceDepth -= 1 }
      }
      endLine = i
      if foundOpenBrace && braceDepth <= 0 { break }
    }

    // Safety: don't extract more than 30 lines (keeps retry within token budget)
    if endLine - startLine > 30 {
      // Narrow to just 10 lines around the error
      startLine = max(0, targetLine - 5)
      endLine = min(lines.count - 1, targetLine + 5)
    }

    let regionLines = Array(lines[startLine...endLine])
    return CodeRegion(
      text: regionLines.joined(separator: "\n"),
      startLine: startLine,
      endLine: endLine
    )
  }

  /// Extract from an error message string (parses line number from the error).
  public func extract(content: String, errorMessage: String) -> CodeRegion? {
    let errors = parseErrors(errorMessage)
    guard let firstError = errors.first else {
      // Try to extract a line number from generic error format
      let pattern = #":(\d+):"#
      guard let match = errorMessage.range(of: pattern, options: .regularExpression),
            let line = Int(errorMessage[match].dropFirst().dropLast()) else {
        return nil
      }
      return extract(content: content, errorLine: line)
    }
    return extract(content: content, errorLine: firstError.line)
  }

  // MARK: - Splicing

  /// Replace a region in the original content with fixed code.
  public func splice(original: String, region: CodeRegion, fix: String) -> String {
    var lines = original.components(separatedBy: "\n")
    let fixLines = fix.components(separatedBy: "\n")

    // Replace the region
    let range = region.startLine...min(region.endLine, lines.count - 1)
    lines.replaceSubrange(range, with: fixLines)

    return lines.joined(separator: "\n")
  }
}
