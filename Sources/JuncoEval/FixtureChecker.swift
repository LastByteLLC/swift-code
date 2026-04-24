// FixtureChecker.swift — Executes SubCheck assertions against a generated file.
//
// Each check is a pure function over the on-disk source. Uses swiftc for
// `compiles` and tree-sitter-swift for structural assertions. Returns a
// SubCheckResult per check; never throws.

import Foundation
import SwiftTreeSitter
import TreeSitterSwiftGrammar
import JuncoKit
import NaturalLanguage

public struct FixtureChecker: Sendable {
  public init() {}

  /// Per-case metadata passed alongside source/answer to the check evaluators.
  public struct EvalContext: Sendable {
    public var llmCalls: Int?
    public var durationSec: Double?
    public var mode: String?
    public init(llmCalls: Int? = nil, durationSec: Double? = nil, mode: String? = nil) {
      self.llmCalls = llmCalls; self.durationSec = durationSec; self.mode = mode
    }
  }

  /// Run every check against the file at `filePath`, the optional answer text, and the
  /// optional case metadata. Missing file yields every file-check failing with
  /// "file not found"; missing answer yields every answer-check failing similarly.
  public func run(
    checks: [SubCheck],
    filePath: String?,
    answer: String? = nil,
    context: EvalContext = EvalContext(),
    workingDirectory: String
  ) -> [SubCheckResult] {
    let absolutePath: String?
    if let filePath {
      absolutePath = filePath.hasPrefix("/")
        ? filePath
        : (workingDirectory as NSString).appendingPathComponent(filePath)
    } else {
      absolutePath = nil
    }
    let source: String? = absolutePath.flatMap { try? String(contentsOfFile: $0, encoding: .utf8) }
    return checks.map { evaluate($0, source: source, path: absolutePath, answer: answer, context: context) }
  }

  private func evaluate(
    _ check: SubCheck, source: String?, path: String?, answer: String?, context: EvalContext
  ) -> SubCheckResult {
    switch check.kind {
    case "compiles":
      return checkCompiles(path: path, source: source, label: check.label)

    case "hasType":
      return checkHasType(check: check, source: source)

    case "hasCase":
      return checkHasCase(check: check, source: source)

    case "hasConformance":
      return checkHasConformance(check: check, source: source)

    case "hasMember":
      return checkHasMember(check: check, source: source)

    case "doesNotReferenceType":
      return checkDoesNotReferenceType(check: check, source: source)

    case "referenceSimilarity":
      return checkReferenceSimilarity(check: check, answer: answer, source: source)

    case "answerContains":
      return checkAnswerContains(check: check, answer: answer)
    case "answerDoesNotContain":
      return checkAnswerDoesNotContain(check: check, answer: answer)
    case "answerMentionsAny":
      return checkAnswerMentionsAny(check: check, answer: answer)
    case "answerMatches":
      return checkAnswerMatches(check: check, answer: answer)
    case "answerCitesPath":
      return checkAnswerCitesPath(check: check, answer: answer)
    case "answerLengthOver":
      return checkAnswerLengthOver(check: check, answer: answer)
    case "answerLengthUnder":
      return checkAnswerLengthUnder(check: check, answer: answer)
    case "llmCallsUnder":
      return checkLlmCallsUnder(check: check, context: context)
    case "durationUnder":
      return checkDurationUnder(check: check, context: context)
    case "modeIs":
      return checkModeIs(check: check, context: context)

    default:
      return SubCheckResult(label: check.label, passed: false, detail: "unknown kind")
    }
  }

  // MARK: - Answer / context kinds

  private func normalized(_ s: String, ci: Bool?) -> String {
    (ci ?? true) ? s.lowercased() : s
  }

  private func checkAnswerContains(check: SubCheck, answer: String?) -> SubCheckResult {
    guard let answer, let text = check.text else {
      return SubCheckResult(label: check.label, passed: false, detail: "missing answer or text")
    }
    let passed = normalized(answer, ci: check.caseInsensitive)
      .contains(normalized(text, ci: check.caseInsensitive))
    return SubCheckResult(label: check.label, passed: passed, detail: passed ? nil : "substring not found")
  }

  private func checkAnswerDoesNotContain(check: SubCheck, answer: String?) -> SubCheckResult {
    guard let answer, let text = check.text else {
      return SubCheckResult(label: check.label, passed: false, detail: "missing answer or text")
    }
    let passed = !normalized(answer, ci: check.caseInsensitive)
      .contains(normalized(text, ci: check.caseInsensitive))
    return SubCheckResult(label: check.label, passed: passed, detail: passed ? nil : "forbidden substring present")
  }

  private func checkAnswerMentionsAny(check: SubCheck, answer: String?) -> SubCheckResult {
    guard let answer, let options = check.anyOf, !options.isEmpty else {
      return SubCheckResult(label: check.label, passed: false, detail: "missing answer or anyOf")
    }
    let haystack = normalized(answer, ci: check.caseInsensitive)
    let passed = options.contains { haystack.contains(normalized($0, ci: check.caseInsensitive)) }
    return SubCheckResult(label: check.label, passed: passed,
                          detail: passed ? nil : "none of \(options.count) options mentioned")
  }

  private func checkAnswerMatches(check: SubCheck, answer: String?) -> SubCheckResult {
    guard let answer, let pattern = check.pattern else {
      return SubCheckResult(label: check.label, passed: false, detail: "missing answer or pattern")
    }
    guard let regex = try? NSRegularExpression(pattern: pattern, options: check.caseInsensitive ?? true ? [.caseInsensitive] : []) else {
      return SubCheckResult(label: check.label, passed: false, detail: "invalid regex")
    }
    let nsRange = NSRange(answer.startIndex..., in: answer)
    let passed = regex.firstMatch(in: answer, range: nsRange) != nil
    return SubCheckResult(label: check.label, passed: passed, detail: passed ? nil : "no match")
  }

  private func checkAnswerCitesPath(check: SubCheck, answer: String?) -> SubCheckResult {
    guard let answer else {
      return SubCheckResult(label: check.label, passed: false, detail: "missing answer")
    }
    // Matches things like "Sources/X/Y.swift", "Tests/Foo.swift", "Package.swift",
    // or the "path:line" citation form "Sources/X/Y.swift:123".
    let pattern = #"\b(?:Sources|Tests|Package\.swift|[\w-]+)/[\w/.-]+\.(?:swift|md|json|plist)(?::\d+)?"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else {
      return SubCheckResult(label: check.label, passed: false, detail: "regex failed")
    }
    let nsRange = NSRange(answer.startIndex..., in: answer)
    let matches = regex.numberOfMatches(in: answer, range: nsRange)
    let passed = matches > 0
    return SubCheckResult(label: check.label, passed: passed,
                          detail: passed ? nil : "no file-path-like citation found")
  }

  private func checkAnswerLengthOver(check: SubCheck, answer: String?) -> SubCheckResult {
    guard let answer, let min = check.minLength else {
      return SubCheckResult(label: check.label, passed: false, detail: "missing answer or minLength")
    }
    let passed = answer.count >= min
    return SubCheckResult(label: check.label, passed: passed, detail: passed ? nil : "length \(answer.count) < \(min)")
  }

  private func checkAnswerLengthUnder(check: SubCheck, answer: String?) -> SubCheckResult {
    guard let answer, let max = check.maxLength else {
      return SubCheckResult(label: check.label, passed: false, detail: "missing answer or maxLength")
    }
    let passed = answer.count <= max
    return SubCheckResult(label: check.label, passed: passed, detail: passed ? nil : "length \(answer.count) > \(max)")
  }

  private func checkLlmCallsUnder(check: SubCheck, context: EvalContext) -> SubCheckResult {
    guard let calls = context.llmCalls, let max = check.maxLlmCalls else {
      return SubCheckResult(label: check.label, passed: false, detail: "missing llmCalls or bound")
    }
    let passed = calls <= max
    return SubCheckResult(label: check.label, passed: passed, detail: passed ? nil : "\(calls) > \(max)")
  }

  private func checkDurationUnder(check: SubCheck, context: EvalContext) -> SubCheckResult {
    guard let dur = context.durationSec, let max = check.maxDurationSec else {
      return SubCheckResult(label: check.label, passed: false, detail: "missing duration or bound")
    }
    let passed = dur <= max
    return SubCheckResult(label: check.label, passed: passed,
                          detail: passed ? nil : String(format: "%.1fs > %.1fs", dur, max))
  }

  private func checkModeIs(check: SubCheck, context: EvalContext) -> SubCheckResult {
    guard let mode = context.mode, let expected = check.expectedMode else {
      return SubCheckResult(label: check.label, passed: false, detail: "missing mode")
    }
    let passed = mode.lowercased() == expected.lowercased()
    return SubCheckResult(label: check.label, passed: passed, detail: passed ? nil : "mode=\(mode) expected=\(expected)")
  }

  // MARK: - Kinds

  private func checkCompiles(path: String?, source: String?, label: String) -> SubCheckResult {
    guard let path else {
      return SubCheckResult(label: label, passed: false, detail: "no file path")
    }
    guard source != nil else {
      return SubCheckResult(label: label, passed: false, detail: "file not found")
    }
    let task = Process()
    task.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    task.arguments = ["swiftc", "-typecheck", path]
    // Redirect output to tempfile to avoid pipe-buffer deadlocks.
    let err = URL(fileURLWithPath: NSTemporaryDirectory())
      .appendingPathComponent("fixchk-\(UUID().uuidString).err")
    let fh = FileHandle(forWritingAtPath: err.path) ?? {
      FileManager.default.createFile(atPath: err.path, contents: nil)
      return FileHandle(forWritingAtPath: err.path)!
    }()
    task.standardOutput = fh
    task.standardError = fh
    defer {
      try? fh.close()
      try? FileManager.default.removeItem(at: err)
    }
    do {
      try task.run()
      task.waitUntilExit()
    } catch {
      return SubCheckResult(label: label, passed: false, detail: "swiftc launch: \(error)")
    }
    let passed = task.terminationStatus == 0
    let detail: String?
    if passed {
      detail = nil
    } else {
      let stderr = (try? String(contentsOf: err, encoding: .utf8)) ?? ""
      detail = String(stderr.prefix(300))
    }
    return SubCheckResult(label: label, passed: passed, detail: detail)
  }

  private func checkHasType(check: SubCheck, source: String?) -> SubCheckResult {
    guard let source, let name = check.name else {
      return SubCheckResult(label: check.label, passed: false, detail: "missing source or name")
    }
    let category = check.category ?? "any"
    guard let (_, info) = findTypeDeclaration(named: name, in: source) else {
      return SubCheckResult(label: check.label, passed: false, detail: "type \(name) not found")
    }
    if category != "any", info.keyword != category {
      return SubCheckResult(
        label: check.label, passed: false,
        detail: "type \(name) has keyword \(info.keyword), expected \(category)"
      )
    }
    if let expected = check.conformsTo {
      let missing = expected.filter { !info.conformances.contains($0) }
      if !missing.isEmpty {
        return SubCheckResult(
          label: check.label, passed: false,
          detail: "\(name) missing conformances: \(missing.joined(separator: ", "))"
        )
      }
    }
    return SubCheckResult(label: check.label, passed: true)
  }

  private func checkHasCase(check: SubCheck, source: String?) -> SubCheckResult {
    guard let source, let on = check.on, let names = check.names, !names.isEmpty else {
      return SubCheckResult(label: check.label, passed: false, detail: "missing source or names")
    }
    guard let (enumBody, info) = findTypeDeclaration(named: on, in: source) else {
      return SubCheckResult(label: check.label, passed: false, detail: "enum \(on) not found")
    }
    guard info.keyword == "enum" else {
      return SubCheckResult(label: check.label, passed: false, detail: "\(on) is not an enum")
    }
    let cases = enumCaseNames(in: enumBody)
    let missing = names.filter { !cases.contains($0) }
    if missing.isEmpty {
      return SubCheckResult(label: check.label, passed: true)
    }
    return SubCheckResult(
      label: check.label, passed: false,
      detail: "\(on) missing case(s): \(missing.joined(separator: ", "))"
    )
  }

  private func checkHasConformance(check: SubCheck, source: String?) -> SubCheckResult {
    guard let source, let on = check.on, let expected = check.conformsTo else {
      return SubCheckResult(label: check.label, passed: false, detail: "missing fields")
    }
    guard let (_, info) = findTypeDeclaration(named: on, in: source) else {
      return SubCheckResult(label: check.label, passed: false, detail: "type \(on) not found")
    }
    let missing = expected.filter { !info.conformances.contains($0) }
    if missing.isEmpty {
      return SubCheckResult(label: check.label, passed: true)
    }
    return SubCheckResult(
      label: check.label, passed: false,
      detail: "\(on) missing conformance(s): \(missing.joined(separator: ", "))"
    )
  }

  private func checkHasMember(check: SubCheck, source: String?) -> SubCheckResult {
    guard let source, let on = check.on, let name = check.name else {
      return SubCheckResult(label: check.label, passed: false, detail: "missing source/on/name")
    }
    // Accept members inside the type body OR in a matching `extension Type`.
    let bodies = findAllBodies(for: on, in: source)
    guard !bodies.isEmpty else {
      return SubCheckResult(label: check.label, passed: false, detail: "type \(on) not found")
    }
    let wantMember = check.member ?? "any"
    let wantReturns = check.returns
    for body in bodies {
      if memberExists(in: body, name: name, kind: wantMember, returns: wantReturns) {
        return SubCheckResult(label: check.label, passed: true)
      }
    }
    let returnSuffix = wantReturns.map { " returning \($0)" } ?? ""
    return SubCheckResult(
      label: check.label, passed: false,
      detail: "\(on).\(name) (\(wantMember)\(returnSuffix)) not found"
    )
  }

  private func checkDoesNotReferenceType(check: SubCheck, source: String?) -> SubCheckResult {
    guard let source, let name = check.name else {
      return SubCheckResult(label: check.label, passed: false, detail: "missing fields")
    }
    let pattern = "\\b\(NSRegularExpression.escapedPattern(for: name))\\b"
    let regex = try? NSRegularExpression(pattern: pattern)
    let count = regex?.numberOfMatches(in: source, range: NSRange(source.startIndex..., in: source)) ?? 0
    let passed = count == 0
    return SubCheckResult(
      label: check.label, passed: passed,
      detail: passed ? nil : "found \(count) reference(s)"
    )
  }

  private func checkReferenceSimilarity(check: SubCheck, answer: String?, source: String?) -> SubCheckResult {
    let text = answer ?? source ?? ""
    guard let reference = check.reference, let threshold = check.minSimilarity else {
      return SubCheckResult(label: check.label, passed: false, detail: "missing reference/threshold")
    }
    guard let embedder = NLEmbedding.sentenceEmbedding(for: .english),
          let a = embedder.vector(for: text),
          let b = embedder.vector(for: reference) else {
      return SubCheckResult(label: check.label, passed: false, detail: "embedding unavailable")
    }
    var dot = 0.0, na = 0.0, nb = 0.0
    for i in 0..<min(a.count, b.count) { dot += a[i] * b[i]; na += a[i] * a[i]; nb += b[i] * b[i] }
    let sim = (na > 0 && nb > 0) ? dot / (na.squareRoot() * nb.squareRoot()) : 0
    let passed = sim >= threshold
    return SubCheckResult(
      label: check.label, passed: passed,
      detail: passed ? nil : String(format: "sim=%.2f < %.2f", sim, threshold)
    )
  }

  // MARK: - AST helpers

  private struct TypeInfo {
    let keyword: String     // "struct" | "class" | "enum" | "actor" | "protocol" | "extension"
    let conformances: Set<String>
  }

  /// Find the first declaration of a named top-level type. Returns (body-text, info).
  /// Body-text is the content between the type's opening `{` and matching `}`.
  private func findTypeDeclaration(named name: String, in source: String) -> (String, TypeInfo)? {
    let lines = source.components(separatedBy: "\n")
    let modifierPrefix = #"(?:public\s+|private\s+|internal\s+|fileprivate\s+|open\s+|final\s+)*"#
    let pattern = "^\\s*\(modifierPrefix)(struct|class|enum|actor|protocol)\\s+\(NSRegularExpression.escapedPattern(for: name))\\b([^{]*)"
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return nil }
    for (i, line) in lines.enumerated() {
      let nsRange = NSRange(line.startIndex..., in: line)
      guard let m = regex.firstMatch(in: line, range: nsRange),
            m.numberOfRanges >= 3 else { continue }
      guard line.contains("{") else { continue }
      guard let endRow = matchingBrace(lines: lines, openRow: i) else { continue }
      let kwRange = Range(m.range(at: 1), in: line)!
      let keyword = String(line[kwRange])
      let tailRange = Range(m.range(at: 2), in: line)!
      let conformances = parseConformances(String(line[tailRange]))
      let body: String
      if endRow > i {
        body = lines[(i + 1)..<endRow].joined(separator: "\n")
      } else {
        body = lines[i]
      }
      return (body, TypeInfo(keyword: keyword, conformances: conformances))
    }
    return nil
  }

  /// Find every body associated with `name`: the main declaration plus any
  /// `extension Name …` blocks. Each tuple is just the body text.
  private func findAllBodies(for name: String, in source: String) -> [String] {
    var results: [String] = []
    let lines = source.components(separatedBy: "\n")
    let escaped = NSRegularExpression.escapedPattern(for: name)
    let declPattern = "^\\s*(?:public\\s+|private\\s+|internal\\s+|fileprivate\\s+|open\\s+|final\\s+)*(?:struct|class|enum|actor|protocol)\\s+\(escaped)\\b"
    let extPattern = "^\\s*(?:public\\s+|private\\s+|internal\\s+|fileprivate\\s+|open\\s+)*extension\\s+\(escaped)\\b"
    let declRegex = try? NSRegularExpression(pattern: declPattern)
    let extRegex = try? NSRegularExpression(pattern: extPattern)
    for (i, line) in lines.enumerated() {
      let nsRange = NSRange(line.startIndex..., in: line)
      let isDecl = declRegex?.firstMatch(in: line, range: nsRange) != nil
      let isExt = extRegex?.firstMatch(in: line, range: nsRange) != nil
      guard isDecl || isExt, line.contains("{") else { continue }
      guard let endRow = matchingBrace(lines: lines, openRow: i) else { continue }
      let body: String
      if endRow > i {
        body = lines[(i + 1)..<endRow].joined(separator: "\n")
      } else {
        body = lines[i]
      }
      results.append(body)
    }
    return results
  }

  /// Return the row of the matching `}` for the first `{` on (or after) `openRow`.
  /// Honors string literals; unbalanced input returns nil.
  private func matchingBrace(lines: [String], openRow: Int) -> Int? {
    var depth = 0
    var seen = false
    for r in openRow..<lines.count {
      var inStr = false
      var prev: Character = "\0"
      for ch in lines[r] {
        if ch == "\"" && prev != "\\" { inStr.toggle() }
        if !inStr {
          if ch == "{" {
            depth += 1; seen = true
          } else if ch == "}" {
            depth -= 1
            if seen && depth == 0 { return r }
          }
        }
        prev = ch
      }
    }
    return nil
  }

  /// Parse a type tail like `: Codable, Identifiable where T: Hashable`.
  private func parseConformances(_ tail: String) -> Set<String> {
    guard let colonIdx = tail.firstIndex(of: ":") else { return [] }
    let afterColon = tail[tail.index(after: colonIdx)...]
    // Split on `{`, `where`, then commas.
    let untilBrace = afterColon.split(separator: "{", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
    let untilWhere = untilBrace
      .replacingOccurrences(of: " where ", with: "{")
      .split(separator: "{", maxSplits: 1, omittingEmptySubsequences: false).first ?? ""
    var names: Set<String> = []
    for part in untilWhere.split(separator: ",") {
      // Trim leading/trailing whitespace and common punctuation.
      let name = part.trimmingCharacters(in: .whitespaces)
      if !name.isEmpty { names.insert(name) }
    }
    return names
  }

  /// Enum case names in a body. Reuses the same pattern as TreeSitterRepair Pass 5.
  private func enumCaseNames(in body: String) -> Set<String> {
    var names: Set<String> = []
    let pattern = #"\bcase\s+([a-zA-Z_]\w*(?:\s*=\s*"[^"]*")?(?:\s*,\s*[a-zA-Z_]\w*(?:\s*=\s*"[^"]*")?)*)"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return names }
    let nsRange = NSRange(body.startIndex..., in: body)
    for m in regex.matches(in: body, range: nsRange) {
      guard m.numberOfRanges >= 2, let r = Range(m.range(at: 1), in: body) else { continue }
      for entry in body[r].components(separatedBy: ",") {
        let token = entry.trimmingCharacters(in: .whitespaces)
          .components(separatedBy: CharacterSet(charactersIn: " =")).first ?? ""
        if !token.isEmpty { names.insert(token) }
      }
    }
    return names
  }

  /// Does `body` contain a member declaration matching name + kind + (optional) return type?
  /// kind: "func" | "var" | "computed" | "property" | "any".
  private func memberExists(in body: String, name: String, kind: String, returns: String?) -> Bool {
    let escaped = NSRegularExpression.escapedPattern(for: name)
    let funcPattern = "\\bfunc\\s+\(escaped)\\s*\\([^)]*\\)"
    let propPattern = "\\b(?:var|let)\\s+\(escaped)\\s*(?::|=)"
    let computedPattern = "\\bvar\\s+\(escaped)\\s*:[^=]*\\{"  // var name: Type {
    let patterns: [String]
    switch kind {
    case "func": patterns = [funcPattern]
    case "var", "property": patterns = [propPattern]
    case "computed": patterns = [computedPattern]
    default: patterns = [funcPattern, propPattern]
    }
    for pat in patterns {
      guard let r = try? NSRegularExpression(pattern: pat) else { continue }
      let nsRange = NSRange(body.startIndex..., in: body)
      for m in r.matches(in: body, range: nsRange) {
        guard let matchRange = Range(m.range, in: body) else { continue }
        if let returns {
          // Extract the rest of the signature up to the next `{` and check for `-> returns`.
          let tail = body[matchRange.upperBound...]
          guard let braceIdx = tail.firstIndex(of: "{") else { continue }
          let sig = tail[..<braceIdx]
          if sig.contains("-> \(returns)") || sig.contains("->\(returns)") {
            return true
          }
        } else {
          return true
        }
      }
    }
    return false
  }
}
