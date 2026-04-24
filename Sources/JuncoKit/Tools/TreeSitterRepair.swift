// TreeSitterRepair.swift — AST-guided structural repair for generated Swift code
//
// Applied after LLM generation, before compilation. Uses tree-sitter to find
// ERROR nodes and apply deterministic fixes: strip prose, balance braces,
// close strings, remove trailing junk. More precise than regex-based
// PostGenerationLinter.balanceBraces().

import Foundation
import SwiftTreeSitter
import TreeSitterSwiftGrammar

/// Deterministic structural repair of generated Swift code using tree-sitter AST.
/// Repairs are ordered: strip prose → strip trailing junk → balance braces → close strings.
/// Each pass re-parses to get a fresh AST.
public struct TreeSitterRepair: Sendable {

  public init() {}

  /// Apply all structural repairs. Returns repaired code and a list of fixes applied.
  public func repair(_ code: String) -> (code: String, fixes: [String]) {
    guard !code.isEmpty else { return (code, []) }
    var current = code
    var fixes: [String] = []

    // Pass 1: Strip leading non-code text
    let stripped = stripLeadingProse(current)
    if stripped != current {
      fixes.append("stripped leading prose")
      current = stripped
    }

    // Pass 2: Balance braces using AST error detection
    // Run before trailing junk removal so extra `}` are cleaned first.
    let balanced = balanceBraces(current)
    if balanced != current {
      fixes.append("balanced braces")
      current = balanced
    }

    // Pass 3: Strip trailing junk after last declaration
    let trimmed = stripTrailingJunk(current)
    if trimmed != current {
      fixes.append("stripped trailing junk")
      current = trimmed
    }

    // Pass 4: Close unterminated string literals
    let closed = closeUnterminatedStrings(current)
    if closed != current {
      fixes.append("closed unterminated string")
      current = closed
    }

    // Pass 5: Pull orphaned enum methods inside their enum body
    let pulled = pullEnumExternalMethods(current)
    if pulled.moved > 0 {
      fixes.append("pulled \(pulled.moved) enum method(s) inside")
      current = pulled.code
    }

    return (current, fixes)
  }

  // MARK: - Pass 1: Strip Leading Prose

  /// Strip leading non-code text before the first import/@/struct/func/comment.
  /// Uses tree-sitter to find the first valid top-level declaration node.
  public func stripLeadingProse(_ code: String) -> String {
    guard let tree = parse(code), let root = tree.rootNode else { return code }
    let lines = code.components(separatedBy: "\n")

    // Find the first non-ERROR top-level node
    let codeNodeTypes: Set<String> = [
      "import_declaration", "class_declaration", "function_declaration",
      "protocol_declaration", "property_declaration", "typealias_declaration",
      "comment", "multiline_comment"
    ]

    var firstCodeRow: UInt32?
    for i in 0..<root.childCount {
      guard let child = root.child(at: i) else { continue }
      let nodeType = child.nodeType ?? ""
      if codeNodeTypes.contains(nodeType) {
        firstCodeRow = child.pointRange.lowerBound.row
        break
      }
    }

    // If no code node found, try regex fallback for attribute-decorated declarations
    if firstCodeRow == nil {
      let codeStarters = ["import ", "@", "struct ", "class ", "enum ", "actor ",
                          "protocol ", "func ", "let ", "var ", "//", "/*", "#if"]
      for (i, line) in lines.enumerated() {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if codeStarters.contains(where: { trimmed.hasPrefix($0) }) {
          firstCodeRow = UInt32(i)
          break
        }
      }
    }

    guard let startRow = firstCodeRow, startRow > 0 else { return code }

    // Verify the lines before are actually prose (not blank lines we should keep)
    let preamble = lines[0..<Int(startRow)]
    let hasProseContent = preamble.contains { line in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      return !trimmed.isEmpty && !trimmed.hasPrefix("//") && !trimmed.hasPrefix("/*")
    }

    guard hasProseContent else { return code }

    let remaining = Array(lines[Int(startRow)...])
    return remaining.joined(separator: "\n")
  }

  // MARK: - Pass 2: Strip Trailing Junk

  /// Strip extraneous text after the last top-level declaration's closing brace.
  /// Uses both tree-sitter AST and brace-depth tracking as fallback.
  public func stripTrailingJunk(_ code: String) -> String {
    let lines = code.components(separatedBy: "\n")

    // Strategy 1: Find last line where brace depth returns to 0 after being > 0.
    // Everything after that which isn't code is junk.
    var depth = 0
    var lastBalancedLine = 0
    var wasOpen = false
    var inString = false
    var prevChar: Character = "\0"

    for (i, line) in lines.enumerated() {
      let depthBefore = depth
      for ch in line {
        if ch == "\"" && prevChar != "\\" { inString.toggle() }
        if !inString {
          if ch == "{" { depth += 1; wasOpen = true }
          if ch == "}" { depth -= 1 }
        }
        prevChar = ch
      }
      // Only update when this line caused depth to return to 0 (a declaration closed here)
      if wasOpen && depth == 0 && depthBefore > 0 {
        lastBalancedLine = i
      }
    }

    // If we never opened a brace, try tree-sitter to find last declaration
    if !wasOpen {
      if let tree = parse(code), let root = tree.rootNode {
        for i in 0..<root.childCount {
          guard let child = root.child(at: i) else { continue }
          if child.nodeType != "ERROR" {
            let endRow = Int(child.pointRange.upperBound.row)
            if endRow > lastBalancedLine { lastBalancedLine = endRow }
          }
        }
      }
    }

    guard lastBalancedLine < lines.count - 1 else { return code }

    // Check if anything after is non-whitespace junk (not valid code)
    let trailing = lines[(lastBalancedLine + 1)...]
    let codeIndicators = ["import ", "struct ", "class ", "enum ", "actor ", "protocol ",
                          "func ", "let ", "var ", "//", "/*", "@", "#if", "extension "]
    let hasJunk = trailing.contains { line in
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if trimmed.isEmpty { return false }
      // If it looks like code, it's not junk
      return !codeIndicators.contains(where: { trimmed.hasPrefix($0) })
    }

    guard hasJunk else { return code }

    var result = lines[0...lastBalancedLine].joined(separator: "\n")
    if !result.hasSuffix("\n") { result += "\n" }
    return result
  }

  // MARK: - Pass 3: Balance Braces

  /// Balance braces using tree-sitter ERROR node detection.
  /// More precise than global counting — focuses on where the parser actually fails.
  public func balanceBraces(_ code: String) -> String {
    // First, do a global count as a quick check
    var opens = 0
    var closes = 0
    var inString = false
    var prevChar: Character = "\0"
    for ch in code {
      if ch == "\"" && prevChar != "\\" { inString.toggle() }
      if !inString {
        if ch == "{" { opens += 1 }
        if ch == "}" { closes += 1 }
      }
      prevChar = ch
    }

    if opens == closes { return code }

    var lines = code.components(separatedBy: "\n")

    if closes > opens {
      // Too many closing braces — find and remove lines where brace depth goes negative.
      // These are extraneous `}` after all declarations have been properly closed.
      var depth = 0
      var linesToRemove: [Int] = []
      for (i, line) in lines.enumerated() {
        var lineInString = false
        var linePrev: Character = "\0"
        for ch in line {
          if ch == "\"" && linePrev != "\\" { lineInString.toggle() }
          if !lineInString {
            if ch == "{" { depth += 1 }
            if ch == "}" {
              depth -= 1
              if depth < 0 {
                // This `}` has no matching `{` — mark for removal if line is just `}`
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed == "}" {
                  linesToRemove.append(i)
                }
                depth = 0 // reset to continue scanning
              }
            }
          }
          linePrev = ch
        }
      }
      // Remove in reverse order to preserve indices
      for i in linesToRemove.reversed() {
        lines.remove(at: i)
      }
      if linesToRemove.isEmpty { return code } // couldn't fix — return original
    } else {
      // Too few closing braces — use AST to find where they're missing
      let missing = opens - closes
      if missing > 3 { return code } // too many missing — likely deeper issue

      // Determine indent level for closing braces by finding the last
      // non-empty line and using its indent as a guide
      guard let tree = parse(code), let root = tree.rootNode else {
        // Fallback: just append missing braces
        for _ in 0..<missing {
          lines.append("}")
        }
        return ensureTrailingNewline(lines.joined(separator: "\n"))
      }

      // Find ERROR nodes at the end of the file — these indicate missing braces
      var errorAtEnd = false
      for i in (0..<root.childCount).reversed() {
        guard let child = root.child(at: i) else { continue }
        if child.nodeType == "ERROR" {
          errorAtEnd = true
          break
        }
        break // only check last child
      }

      if errorAtEnd {
        // Append missing braces with decreasing indent
        for level in (0..<missing).reversed() {
          let indent = String(repeating: "    ", count: level)
          lines.append("\(indent)}")
        }
      } else {
        // No ERROR at end — just append at top level
        for _ in 0..<missing {
          lines.append("}")
        }
      }
    }

    return ensureTrailingNewline(lines.joined(separator: "\n"))
  }

  // MARK: - Pass 4: Close Unterminated Strings

  /// Close unterminated string literals detected via line-level analysis.
  /// Checks for lines with odd number of unescaped quotes.
  /// Uses both tree-sitter ERROR nodes and direct quote counting as fallback.
  public func closeUnterminatedStrings(_ code: String) -> String {
    var lines = code.components(separatedBy: "\n")
    var modified = false

    // Collect ERROR node rows from tree-sitter (if available)
    var errorRows: Set<Int> = []
    if let tree = parse(code), let root = tree.rootNode {
      var errorNodes: [(row: Int, col: Int)] = []
      collectErrorNodes(root, into: &errorNodes)
      for error in errorNodes {
        errorRows.insert(error.row)
      }
    }

    for i in 0..<lines.count {
      let line = lines[i]
      // Skip multi-line string delimiters
      if line.contains("\"\"\"") { continue }

      // Count unescaped quotes
      var quoteCount = 0
      var prevCh: Character = "\0"
      for ch in line {
        if ch == "\"" && prevCh != "\\" { quoteCount += 1 }
        prevCh = ch
      }

      // Odd number of quotes suggests unterminated string
      if quoteCount % 2 != 0 {
        // Only fix if tree-sitter flagged an error on or near this line,
        // OR if the line has an assignment with a string (common pattern)
        let hasError = errorRows.contains(i) || errorRows.contains(i + 1)
        let looksLikeStringAssignment = line.contains("= \"") || line.contains("(\"")
        if hasError || looksLikeStringAssignment {
          lines[i] = line + "\""
          modified = true
        }
      }
    }

    guard modified else { return code }
    return lines.joined(separator: "\n")
  }

  // MARK: - Pass 5: Pull Orphaned Enum Methods Inside

  /// Detect AFM's enum-external-method failure: `enum E { cases } func f() { switch E.x … }`
  /// where `x` is a non-case identifier (AFM hallucinates a static like `E.current` in
  /// place of `self`). Move the function inside the enum body and replace `E.<non-case>`
  /// with `self`. Runs only on functions with zero parameters — the signature that
  /// unambiguously implies an instance method, not a free helper.
  ///
  /// Implementation note: brace-counting over raw lines rather than the tree-sitter AST.
  /// tree-sitter-swift misparses `public enum X: String { raw-valued cases }`, truncating
  /// the enum body mid-case — which caused Pass 5 to miss the exact R3 Phase J failure.
  public func pullEnumExternalMethods(_ code: String) -> (code: String, moved: Int) {
    let lines = code.components(separatedBy: "\n")
    guard !lines.isEmpty else { return (code, 0) }

    struct EnumInfo {
      let name: String
      let cases: Set<String>
      let startRow: Int
      let endRow: Int  // row of closing `}`
    }

    // Regex for `[modifiers] enum Name [: RawType] [conformances] {` on a single line.
    let enumHeadPattern = #"^\s*(?:public\s+|private\s+|internal\s+|fileprivate\s+|open\s+)?enum\s+(\w+)\b"#
    let funcHeadPattern = #"^\s*(?:public\s+|private\s+|internal\s+|fileprivate\s+|open\s+|static\s+)?func\s+(\w+)\s*\(\s*\)"#
    guard let enumRegex = try? NSRegularExpression(pattern: enumHeadPattern),
          let funcRegex = try? NSRegularExpression(pattern: funcHeadPattern) else { return (code, 0) }

    var enums: [EnumInfo] = []
    struct FuncRange {
      let name: String
      let startRow: Int
      let endRow: Int
      let text: String
    }
    var topFuncs: [FuncRange] = []

    var i = 0
    while i < lines.count {
      let line = lines[i]
      let nsRange = NSRange(line.startIndex..., in: line)
      if let m = enumRegex.firstMatch(in: line, range: nsRange),
         m.numberOfRanges >= 2, let nameRange = Range(m.range(at: 1), in: line),
         line.contains("{") {
        let name = String(line[nameRange])
        if let endRow = findMatchingBrace(lines: lines, openRow: i) {
          // Single-line enums close on the same row — nothing strictly between i+1 and endRow.
          let body = endRow > i ? lines[(i+1)..<endRow].joined(separator: "\n") : lines[i]
          let cases = collectEnumCaseNames(body)
          enums.append(EnumInfo(name: name, cases: cases, startRow: i, endRow: endRow))
          i = endRow + 1
          continue
        }
      }
      if let m = funcRegex.firstMatch(in: line, range: nsRange),
         m.numberOfRanges >= 2, let nameRange = Range(m.range(at: 1), in: line),
         line.contains("{") {
        let name = String(line[nameRange])
        if let endRow = findMatchingBrace(lines: lines, openRow: i) {
          let text = lines[i...endRow].joined(separator: "\n")
          topFuncs.append(FuncRange(name: name, startRow: i, endRow: endRow, text: text))
          i = endRow + 1
          continue
        }
      }
      i += 1
    }

    guard !enums.isEmpty, !topFuncs.isEmpty else { return (code, 0) }

    struct FuncMove {
      let fnStartRow: Int
      let fnEndRow: Int
      let enumIndex: Int
      let rewrittenText: String
    }
    var moves: [FuncMove] = []

    for fn in topFuncs {
      var targetIdx: Int?
      for (eIdx, e) in enums.enumerated() where e.endRow < fn.startRow {
        if referencesNonCase(fn.text, enumName: e.name, cases: e.cases) {
          targetIdx = eIdx
          break
        }
      }
      guard let enumIdx = targetIdx else { continue }
      let target = enums[enumIdx]
      let rewritten = rewriteEnumRefs(fn.text, enumName: target.name, cases: target.cases)
      moves.append(FuncMove(
        fnStartRow: fn.startRow, fnEndRow: fn.endRow,
        enumIndex: enumIdx, rewrittenText: rewritten
      ))
    }
    guard !moves.isEmpty else { return (code, 0) }

    var output: [String] = []
    let skipRows: Set<Int> = Set(moves.flatMap { Array($0.fnStartRow ... $0.fnEndRow) })
    var insertsAtEnumEnd: [Int: [String]] = [:]
    for m in moves {
      insertsAtEnumEnd[enums[m.enumIndex].endRow, default: []].append(m.rewrittenText)
    }

    for (idx, line) in lines.enumerated() {
      if skipRows.contains(idx) { continue }
      if let inserts = insertsAtEnumEnd[idx] {
        let outerIndent = String(line.prefix { $0 == " " || $0 == "\t" })
        let methodIndent = outerIndent + "  "
        for fnText in inserts {
          output.append("")
          for fnLine in fnText.components(separatedBy: "\n") {
            output.append(fnLine.isEmpty ? fnLine : methodIndent + fnLine)
          }
        }
      }
      output.append(line)
    }
    return (output.joined(separator: "\n"), moves.count)
  }

  /// Starting at a row that contains at least one `{`, return the row of the matching `}`
  /// (same brace depth). Nil if unbalanced. Ignores braces inside `"…"` string literals.
  private func findMatchingBrace(lines: [String], openRow: Int) -> Int? {
    var depth = 0
    var seenOpen = false
    for r in openRow..<lines.count {
      var inString = false
      var prev: Character = "\0"
      for ch in lines[r] {
        if ch == "\"" && prev != "\\" { inString.toggle() }
        if !inString {
          if ch == "{" {
            depth += 1; seenOpen = true
          } else if ch == "}" {
            depth -= 1
            if seenOpen && depth == 0 { return r }
          }
        }
        prev = ch
      }
    }
    return nil
  }

  /// Extract enum case names from an enum body. Handles `case a, b, c`, `case x = "y"`,
  /// inline single-line enums, and skips `case .red:` switch patterns (preceded by `.`).
  private func collectEnumCaseNames(_ body: String) -> Set<String> {
    var names: Set<String> = []
    // Match `case <ident>[=value][, <ident>[=value]]…` where <ident> starts with a letter
    // or underscore (so `.red` inside a switch is not matched as a case name).
    let pattern = #"\bcase\s+([a-zA-Z_]\w*(?:\s*=\s*"[^"]*")?(?:\s*,\s*[a-zA-Z_]\w*(?:\s*=\s*"[^"]*")?)*)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return names }
    let nsRange = NSRange(body.startIndex..., in: body)
    for m in regex.matches(in: body, range: nsRange) {
      guard m.numberOfRanges >= 2, let r = Range(m.range(at: 1), in: body) else { continue }
      let payload = String(body[r])
      for entry in payload.components(separatedBy: ",") {
        let token = entry.trimmingCharacters(in: .whitespaces)
          .components(separatedBy: CharacterSet(charactersIn: " =")).first ?? ""
        if !token.isEmpty { names.insert(token) }
      }
    }
    return names
  }

  private func referencesNonCase(_ text: String, enumName: String, cases: Set<String>) -> Bool {
    let pattern = "\\b\(NSRegularExpression.escapedPattern(for: enumName))\\.(\\w+)"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return false }
    let nsRange = NSRange(text.startIndex..., in: text)
    for m in regex.matches(in: text, range: nsRange) {
      guard m.numberOfRanges >= 2, let r = Range(m.range(at: 1), in: text) else { continue }
      if !cases.contains(String(text[r])) { return true }
    }
    return false
  }

  private func rewriteEnumRefs(_ text: String, enumName: String, cases: Set<String>) -> String {
    let pattern = "\\b\(NSRegularExpression.escapedPattern(for: enumName))\\.(\\w+)"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return text }
    var result = text
    let nsRange = NSRange(result.startIndex..., in: result)
    let matches = regex.matches(in: result, range: nsRange).reversed()
    for m in matches {
      guard m.numberOfRanges >= 2,
            let full = Range(m.range, in: result),
            let idRange = Range(m.range(at: 1), in: result) else { continue }
      let ident = String(result[idRange])
      let replacement = cases.contains(ident) ? ".\(ident)" : "self"
      result.replaceSubrange(full, with: replacement)
    }
    return result
  }

  // MARK: - Helpers

  private func parse(_ code: String) -> MutableTree? {
    let language = Language(language: tree_sitter_swift())
    let parser = Parser()
    do { try parser.setLanguage(language) } catch { return nil }
    return parser.parse(code)
  }

  private func collectErrorNodes(_ node: Node, into errors: inout [(row: Int, col: Int)]) {
    if node.nodeType == "ERROR" {
      let row = Int(node.pointRange.lowerBound.row)
      let col = Int(node.pointRange.lowerBound.column)
      errors.append((row: row, col: col))
    }
    for i in 0..<node.childCount {
      if let child = node.child(at: i) {
        collectErrorNodes(child, into: &errors)
      }
    }
  }

  private func ensureTrailingNewline(_ content: String) -> String {
    content.hasSuffix("\n") ? content : content + "\n"
  }
}
