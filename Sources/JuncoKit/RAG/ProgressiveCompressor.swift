// ProgressiveCompressor.swift — Multi-tier context compression
//
// Compresses code and text to fit token budgets using 4 tiers:
//   full (1.0x) → gist (~0.25x) → micro (~0.08x) → dropped (0x)
//
// For code: gist keeps declarations + properties, drops function bodies.
// For text: gist keeps key sentences, drops filler.
// Inspired by ContextCore's progressive compression strategy.

import Foundation
import SwiftTreeSitter
import TreeSitterSwiftGrammar

/// Compression fidelity tier.
public enum CompressionTier: String, Sendable {
  case full     // 1.0x — include as-is
  case gist     // ~0.25x — declarations, signatures, key facts
  case micro    // ~0.08x — symbol names only
  case dropped  // 0x — removed entirely
}

/// Result of compressing a piece of content.
public struct CompressedContent: Sendable {
  public let compressed: String
  public let tier: CompressionTier
  public let originalTokens: Int
  public let compressedTokens: Int
  public var tokensSaved: Int { originalTokens - compressedTokens }
}

/// Progressively compresses content to fit token budgets.
/// Tries lighter tiers first, escalating only as needed.
public struct ProgressiveCompressor: Sendable {

  public init() {}

  // MARK: - Single Content Compression

  /// Compress content to fit a target token budget.
  /// Tries full → gist → micro → drop in order.
  public func compress(code: String, target: Int) -> CompressedContent {
    let originalTokens = TokenBudget.estimate(code)

    // Full: fits as-is
    if originalTokens <= target {
      return CompressedContent(
        compressed: code, tier: .full,
        originalTokens: originalTokens, compressedTokens: originalTokens
      )
    }

    // Gist: keep declarations, drop bodies (AST-first, regex fallback)
    let gist = codeGistAST(code) ?? codeGist(code)
    let gistTokens = TokenBudget.estimate(gist)
    if gistTokens <= target {
      return CompressedContent(
        compressed: gist, tier: .gist,
        originalTokens: originalTokens, compressedTokens: gistTokens
      )
    }

    // Micro: symbol names only
    let micro = codeMicro(code)
    let microTokens = TokenBudget.estimate(micro)
    if microTokens <= target {
      return CompressedContent(
        compressed: micro, tier: .micro,
        originalTokens: originalTokens, compressedTokens: microTokens
      )
    }

    // Dropped: doesn't fit at any tier
    return CompressedContent(
      compressed: "", tier: .dropped,
      originalTokens: originalTokens, compressedTokens: 0
    )
  }

  // MARK: - Multi-Section Compression

  /// Compress multiple sections to fit a total budget.
  /// Higher-priority sections get lighter compression.
  /// Sections are processed in priority order (highest first).
  public func compressSections(
    _ sections: [(content: String, priority: Int)],
    totalBudget: Int
  ) -> [CompressedContent] {
    let sorted = sections.sorted { $0.priority > $1.priority }
    var results: [CompressedContent] = []
    var remaining = totalBudget

    for section in sorted {
      let result = compress(code: section.content, target: remaining)
      results.append(result)
      remaining -= result.compressedTokens
      if remaining <= 0 { break }
    }

    return results
  }

  // MARK: - AST-Based Code Gist (~0.25x)

  /// Keep declarations and property lines using TreeSitter AST.
  /// Returns nil if parsing fails (caller falls back to regex-based codeGist).
  /// Correctly handles multi-line signatures, where clauses, and nested types.
  public func codeGistAST(_ code: String) -> String? {
    let language = Language(language: tree_sitter_swift())
    let parser = Parser()
    do { try parser.setLanguage(language) } catch { return nil }
    guard let tree = parser.parse(code) else { return nil }
    guard let root = tree.rootNode else { return nil }

    let utf16 = Array(code.utf16)
    var parts: [String] = []

    for i in 0..<root.childCount {
      guard let child = root.child(at: i) else { continue }
      let nodeType = child.nodeType ?? ""

      switch nodeType {
      case "import_declaration":
        // Keep imports in full
        parts.append(astNodeText(child, utf16: utf16))

      case "class_declaration":
        // struct/class/enum/actor/extension: keep declaration line + properties + func signatures
        parts.append(astGistType(child, utf16: utf16))

      case "protocol_declaration":
        parts.append(astGistType(child, utf16: utf16))

      case "function_declaration":
        // Top-level function: keep signature only
        parts.append(astGistFunction(child, utf16: utf16))

      case "property_declaration":
        parts.append(astNodeText(child, utf16: utf16))

      case "typealias_declaration":
        parts.append(astNodeText(child, utf16: utf16))

      default:
        // Skip other top-level nodes (comments, etc.)
        break
      }
    }

    return parts.isEmpty ? nil : parts.joined(separator: "\n")
  }

  /// Extract gist of a type declaration: header + properties + func signatures.
  private func astGistType(_ node: Node, utf16: [UInt16]) -> String {
    var parts: [String] = []

    // Find the class_body / protocol_body child
    var headerEnd: Int?
    var bodyNode: Node?

    for i in 0..<node.childCount {
      guard let child = node.child(at: i) else { continue }
      let ct = child.nodeType ?? ""
      if ct == "class_body" || ct == "protocol_body" || ct == "enum_class_body" {
        bodyNode = child
        // Header is everything before the body's opening brace
        headerEnd = Int(child.byteRange.lowerBound) / 2
        break
      }
    }

    // Emit the declaration header (up to opening brace)
    if let end = headerEnd {
      let start = Int(node.byteRange.lowerBound) / 2
      let headerUtf16 = Array(utf16[start..<min(end, utf16.count)])
      let header = String(utf16CodeUnits: headerUtf16, count: headerUtf16.count)
        .trimmingCharacters(in: .whitespacesAndNewlines)
      parts.append(header + " {")
    } else {
      // No body found — emit entire node
      parts.append(astNodeText(node, utf16: utf16))
      return parts.joined(separator: "\n")
    }

    // Walk body children
    if let body = bodyNode {
      for i in 0..<body.childCount {
        guard let child = body.child(at: i) else { continue }
        let ct = child.nodeType ?? ""
        switch ct {
        case "property_declaration":
          parts.append("  " + astNodeText(child, utf16: utf16).trimmingCharacters(in: .whitespaces))
        case "function_declaration":
          parts.append("  " + astGistFunction(child, utf16: utf16).trimmingCharacters(in: .whitespaces))
        case "class_declaration", "protocol_declaration":
          // Nested type: recurse
          parts.append("  " + astGistType(child, utf16: utf16))
        case "enum_entry":
          parts.append("  " + astNodeText(child, utf16: utf16).trimmingCharacters(in: .whitespaces))
        default:
          break
        }
      }
    }

    parts.append("}")
    return parts.joined(separator: "\n")
  }

  /// Extract gist of a function: signature only, body replaced with "// ...".
  private func astGistFunction(_ node: Node, utf16: [UInt16]) -> String {
    // Find the function_body child
    for i in 0..<node.childCount {
      guard let child = node.child(at: i) else { continue }
      if child.nodeType == "function_body" || child.nodeType == "statements" {
        // Emit everything before the body
        let start = Int(node.byteRange.lowerBound) / 2
        let bodyStart = Int(child.byteRange.lowerBound) / 2
        let sigUtf16 = Array(utf16[start..<min(bodyStart, utf16.count)])
        let sig = String(utf16CodeUnits: sigUtf16, count: sigUtf16.count)
          .trimmingCharacters(in: .whitespacesAndNewlines)
        return sig + "{ // ... }"
      }
    }
    // No body found (protocol requirement or abstract) — emit full text
    return astNodeText(node, utf16: utf16)
  }

  /// Extract text of an AST node from UTF-16 source.
  private func astNodeText(_ node: Node, utf16: [UInt16]) -> String {
    let start = Int(node.byteRange.lowerBound) / 2
    let end = Int(node.byteRange.upperBound) / 2
    guard start >= 0, end <= utf16.count, start < end else { return "" }
    return String(utf16CodeUnits: Array(utf16[start..<end]), count: end - start)
  }

  // MARK: - Regex-Based Code Gist (~0.25x, fallback)

  /// Keep declarations and property lines, drop function bodies.
  /// Preserves: import, func/struct/class/enum/actor/protocol signatures,
  /// let/var declarations, /// doc comments on kept lines.
  public func codeGist(_ code: String) -> String {
    let lines = code.components(separatedBy: "\n")
    var kept: [String] = []
    var braceDepth = 0
    var inFunctionBody = false
    var bodyStartDepth = 0

    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespaces)

      // Track brace depth
      let opens = trimmed.filter { $0 == "{" }.count
      let closes = trimmed.filter { $0 == "}" }.count

      // Always keep: imports
      if trimmed.hasPrefix("import ") {
        kept.append(line)
        braceDepth += opens - closes
        continue
      }

      // Always keep: doc comments (/// lines)
      if trimmed.hasPrefix("///") {
        kept.append(line)
        braceDepth += opens - closes
        continue
      }

      // Detect declaration lines (these start or contain declarations)
      let isDeclaration = Self.declarationPattern.firstMatch(in: trimmed, range: NSRange(trimmed.startIndex..., in: trimmed)) != nil

      if isDeclaration && !inFunctionBody {
        kept.append(line)
        // If this declaration opens a function body, start skipping
        if trimmed.contains("func ") && opens > closes {
          inFunctionBody = true
          bodyStartDepth = braceDepth
        }
      } else if inFunctionBody {
        // Skip function body lines, but track braces
        if trimmed == "}" && braceDepth + opens - closes <= bodyStartDepth {
          // Closing brace of the function — keep it and stop skipping
          kept.append(line)
          inFunctionBody = false
        }
      } else if braceDepth <= 1 {
        // At top level or type level — keep property declarations
        if trimmed.hasPrefix("let ") || trimmed.hasPrefix("var ") ||
           trimmed.hasPrefix("public let ") || trimmed.hasPrefix("public var ") ||
           trimmed.hasPrefix("private let ") || trimmed.hasPrefix("private var ") ||
           trimmed.hasPrefix("public private(set) var ") {
          kept.append(line)
        }
      }

      braceDepth += opens - closes
      braceDepth = max(0, braceDepth)
    }

    return kept.joined(separator: "\n")
  }

  // MARK: - Code Micro (~0.08x)

  /// Extract only symbol names — a compact list of what's in the file.
  public func codeMicro(_ code: String) -> String {
    let lines = code.components(separatedBy: "\n")
    var symbols: [String] = []

    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespaces)

      // Extract symbol names from declarations
      if let match = trimmed.firstMatch(of: /(?:func|struct|class|enum|actor|protocol)\s+(\w+)/) {
        symbols.append(String(match.1))
      } else if let match = trimmed.firstMatch(of: /(?:let|var)\s+(\w+)/) {
        // Only top-level-ish properties (not inside closures)
        if !trimmed.contains("=") || trimmed.hasPrefix("let ") || trimmed.hasPrefix("var ") ||
           trimmed.hasPrefix("public ") || trimmed.hasPrefix("private ") {
          symbols.append(String(match.1))
        }
      } else if trimmed.hasPrefix("import ") {
        symbols.append(trimmed)
      }
    }

    return symbols.joined(separator: ", ")
  }

  // MARK: - Private

  /// Regex for declaration lines (func, type, protocol, property, case).
  private static let declarationPattern: NSRegularExpression = {
    // swiftlint:disable:next force_try
    try! NSRegularExpression(pattern:
      "^\\s*(?:public\\s+|private\\s+|internal\\s+|open\\s+|public\\s+private\\(set\\)\\s+)?" +
      "(?:func |struct |class |enum |actor |protocol |case |typealias |init\\(|deinit)"
    )
  }()
}
