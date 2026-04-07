// PostGenerationLinter.swift — Deterministic transforms for known anti-patterns
//
// Applied to every generated Swift file BEFORE syntax validation.
// These are fast, regex-based fixes for patterns the model reliably gets wrong.
// No LLM call needed — just string transforms.

import Foundation

public struct PostGenerationLinter: Sendable {

  public init() {}

  /// Apply all lint rules to generated content. Returns the fixed content.
  public func lint(content: String, filePath: String) -> String {
    guard filePath.hasSuffix(".swift") else { return content }
    var result = content
    result = fixObservableObjectToObservable(result)
    result = fixObservablePublished(result)
    result = fixStateObjectWithObservable(result)
    result = fixNavigationView(result)
    result = fixHallucinatedModifiers(result)
    result = fixCallbackChimera(result)
    result = fixMissingImports(result)
    result = fixXCTestToSwiftTesting(result)
    result = fixCodableLetId(result)
    result = balanceBraces(result)
    return result
  }

  /// Apply swift-format to generated Swift code. Call AFTER lint() and before validation.
  /// Returns formatted content, or original if swift-format is unavailable or fails.
  public func format(content: String, filePath: String) -> String {
    guard filePath.hasSuffix(".swift") else { return content }
    return formatWithSwiftFormat(content, filePath: filePath)
  }

  // MARK: - swift-format

  /// Cached check for swift-format availability.
  nonisolated(unsafe) private static var _swiftFormatAvailable: Bool?

  private static var swiftFormatAvailable: Bool {
    if let cached = _swiftFormatAvailable { return cached }
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["swift-format", "--version"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    let available: Bool
    do {
      try process.run()
      process.waitUntilExit()
      available = process.terminationStatus == 0
    } catch {
      available = false
    }
    _swiftFormatAvailable = available
    return available
  }

  /// Run swift-format on generated Swift code. Returns formatted content,
  /// or original content if swift-format is unavailable or fails.
  private func formatWithSwiftFormat(_ content: String, filePath: String) -> String {
    guard Self.swiftFormatAvailable else { return content }

    let tmp = NSTemporaryDirectory() + "junco-fmt-\(UUID().uuidString).swift"
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    do {
      try content.write(toFile: tmp, atomically: true, encoding: .utf8)
    } catch {
      return content
    }

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    process.arguments = ["swift-format", "format", "--in-place", tmp]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice

    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      return content
    }

    guard process.terminationStatus == 0 else { return content }

    do {
      return try String(contentsOfFile: tmp, encoding: .utf8)
    } catch {
      return content
    }
  }

  // MARK: - Rules

  /// Transform ObservableObject conformance to @Observable class.
  /// The 3B model's pre-training strongly favors ObservableObject over @Observable.
  /// This rule catches the fallback path's output and rewrites it correctly.
  private func fixObservableObjectToObservable(_ content: String) -> String {
    guard content.contains("ObservableObject") else { return content }
    guard !content.contains("@Observable") else { return content }

    var lines = content.components(separatedBy: "\n")
    var i = 0

    while i < lines.count {
      let trimmed = lines[i].trimmingCharacters(in: .whitespaces)

      // Match: [access] struct/class Name: ... ObservableObject ... {
      guard trimmed.contains("ObservableObject"),
            trimmed.contains("{") || (i + 1 < lines.count && lines[i + 1].contains("{")) else {
        i += 1
        continue
      }

      // Parse the declaration
      let declPattern = #"^(\s*)((?:public|private|internal|open|fileprivate)\s+)?(struct|class)\s+(\w+)\s*:\s*(.+?)\s*\{(.*)$"#
      guard let regex = try? NSRegularExpression(pattern: declPattern),
            let match = regex.firstMatch(in: lines[i], range: NSRange(lines[i].startIndex..., in: lines[i])) else {
        i += 1
        continue
      }

      let indent = Range(match.range(at: 1), in: lines[i]).map { String(lines[i][$0]) } ?? ""
      let access = Range(match.range(at: 2), in: lines[i]).map { String(lines[i][$0]).trimmingCharacters(in: .whitespaces) } ?? ""
      let typeName = Range(match.range(at: 4), in: lines[i]).map { String(lines[i][$0]) } ?? ""
      let conformancesStr = Range(match.range(at: 5), in: lines[i]).map { String(lines[i][$0]) } ?? ""
      let afterBrace = Range(match.range(at: 6), in: lines[i]).map { String(lines[i][$0]) } ?? ""

      // Remove ObservableObject from conformances
      let conformances = conformancesStr.split(separator: ",")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { $0 != "ObservableObject" }

      // Rebuild declaration as @Observable class
      let accessPrefix = access.isEmpty ? "" : "\(access) "
      let confSuffix = conformances.isEmpty ? "" : ": \(conformances.joined(separator: ", "))"
      let attrLine = "\(indent)@Observable"
      let declLine = "\(indent)\(accessPrefix)class \(typeName)\(confSuffix) {\(afterBrace)"
      lines[i] = "\(attrLine)\n\(declLine)"
      i += 1
    }

    var result = lines.joined(separator: "\n")

    // Remove @Published (tracked automatically by @Observable)
    result = result.replacingOccurrences(of: "@Published ", with: "")

    // Remove Combine import if only used for ObservableObject/@Published
    if result.contains("import Combine") && !result.contains("AnyCancellable")
        && !result.contains("Publisher") && !result.contains("Subscriber")
        && !result.contains("CurrentValueSubject") && !result.contains("PassthroughSubject") {
      result = result.replacingOccurrences(of: "import Combine\n", with: "")
      result = result.replacingOccurrences(of: "import Combine", with: "")
    }

    return result
  }

  /// @Observable + @Published are mutually exclusive.
  /// If both present, remove @Published (the @Observable version tracks automatically).
  private func fixObservablePublished(_ content: String) -> String {
    guard content.contains("@Observable") && content.contains("@Published") else { return content }
    // Remove @Published annotations, preserving the rest of the line
    var lines = content.components(separatedBy: "\n")
    for i in 0..<lines.count {
      if lines[i].contains("@Published") {
        lines[i] = lines[i].replacingOccurrences(of: "@Published ", with: "")
        lines[i] = lines[i].replacingOccurrences(of: "@Published\n", with: "\n")
      }
    }
    // Also remove Combine import if it was only used for @Published
    var result = lines.joined(separator: "\n")
    if result.contains("import Combine") && !result.contains("AnyCancellable")
        && !result.contains("Publisher") && !result.contains("Subscriber")
        && !result.contains("CurrentValueSubject") && !result.contains("PassthroughSubject") {
      result = result.replacingOccurrences(of: "import Combine\n", with: "")
    }
    return result
  }

  /// NavigationView is deprecated — use NavigationStack.
  private func fixNavigationView(_ content: String) -> String {
    guard content.contains("NavigationView") else { return content }
    return content.replacingOccurrences(of: "NavigationView", with: "NavigationStack")
  }

  /// @StateObject is incompatible with @Observable — use @State instead.
  /// Only applies when the file doesn't use ObservableObject or Combine.
  private func fixStateObjectWithObservable(_ content: String) -> String {
    guard content.contains("@StateObject") else { return content }
    // @StateObject requires ObservableObject (Combine). If neither is present, use @State.
    if !content.contains("ObservableObject") && !content.contains("import Combine") {
      return content.replacingOccurrences(of: "@StateObject", with: "@State")
    }
    return content
  }

  /// Fix known hallucinated SwiftUI modifiers.
  private func fixHallucinatedModifiers(_ content: String) -> String {
    var result = content
    // .fontSize(N) → .font(.system(size: N))
    result = result.replacingOccurrences(
      of: #"\.fontSize\((\d+)\)"#,
      with: ".font(.system(size: $1))",
      options: .regularExpression
    )
    // Image(systemName: "x", style: .y) → Image(systemName: "x")
    result = result.replacingOccurrences(
      of: #"Image\(systemName:\s*"([^"]+)",\s*style:\s*[^)]+\)"#,
      with: #"Image(systemName: "$1")"#,
      options: .regularExpression
    )
    // .textColor(.x) → .foregroundStyle(.x)
    result = result.replacingOccurrences(
      of: #"\.textColor\(([^)]+)\)"#,
      with: ".foregroundStyle($1)",
      options: .regularExpression
    )
    // .foregroundColor(.x) → .foregroundStyle(.x) (deprecated in iOS 17+)
    result = result.replacingOccurrences(
      of: #"\.foregroundColor\(([^)]+)\)"#,
      with: ".foregroundStyle($1)",
      options: .regularExpression
    )
    // .backgroundColor(.x) → .background(.x)
    result = result.replacingOccurrences(
      of: #"\.backgroundColor\(([^)]+)\)"#,
      with: ".background($1)",
      options: .regularExpression
    )
    // .cornerRadius(N) → .clipShape(.rect(cornerRadius: N))
    result = result.replacingOccurrences(
      of: #"\.cornerRadius\(([^)]+)\)"#,
      with: ".clipShape(.rect(cornerRadius: $1))",
      options: .regularExpression
    )
    // .size(width: X, height: Y) → .frame(width: X, height: Y)
    result = result.replacingOccurrences(
      of: #"\.size\(width:\s*([^,]+),\s*height:\s*([^)]+)\)"#,
      with: ".frame(width: $1, height: $2)",
      options: .regularExpression
    )
    // .onTap { } → .onTapGesture { }
    result = result.replacingOccurrences(
      of: #"\.onTap\s*\{"#,
      with: ".onTapGesture {",
      options: .regularExpression
    )
    // .maxWidth(.infinity) → .frame(maxWidth: .infinity)
    result = result.replacingOccurrences(
      of: #"\.maxWidth\(([^)]+)\)"#,
      with: ".frame(maxWidth: $1)",
      options: .regularExpression
    )
    // .accessoryView { ... } → remove (doesn't exist)
    result = result.replacingOccurrences(
      of: #"\.accessoryView\s*\{[^}]*\}"#,
      with: "",
      options: .regularExpression
    )
    return result
  }

  /// Rewrite callback chimera patterns to proper async/await.
  /// Detects: `service.method(...) { result in self.x = result.y }` or `{ result in ... }`
  /// Rewrites to: `do { self.x = try await service.method(...) } catch { print(error) }`
  private func fixCallbackChimera(_ content: String) -> String {
    // Only apply to files with async functions (ViewModels, controllers)
    guard content.contains("async") else { return content }

    var lines = content.components(separatedBy: "\n")
    var i = 0
    while i < lines.count {
      let line = lines[i].trimmingCharacters(in: .whitespaces)

      // Pattern: `something.method(args) { result in` or `try await something.method(args) { result in`
      // Detect trailing closure after a method call
      if line.contains("{ result in") || line.contains("{ response in") || line.contains("{ data in"),
         let callRange = line.range(of: #"(try\s+await\s+)?(\S+\.\S+\([^)]*\))\s*\{"#, options: .regularExpression) {

        // Extract the method call (before the closure)
        let beforeClosure = line[callRange]
        let callStr = String(beforeClosure)
          .replacingOccurrences(of: #"\s*\{$"#, with: "", options: .regularExpression)
          .trimmingCharacters(in: .whitespaces)

        // Ensure it has try await
        let asyncCall: String
        if callStr.hasPrefix("try await") {
          asyncCall = callStr
        } else if callStr.hasPrefix("try") {
          asyncCall = callStr.replacingOccurrences(of: "try ", with: "try await ")
        } else {
          asyncCall = "try await \(callStr)"
        }

        // Find the closing brace of the callback and extract assignments
        var assignTarget: String?
        var closingBrace = -1
        for j in (i + 1)..<min(i + 15, lines.count) {
          let inner = lines[j].trimmingCharacters(in: .whitespaces)
          // Look for `self.x = result.y` or `self.x = result`
          if inner.hasPrefix("self.") && inner.contains("= result") {
            let parts = inner.split(separator: "=", maxSplits: 1)
            if parts.count >= 1 {
              assignTarget = String(parts[0]).trimmingCharacters(in: .whitespaces)
            }
          }
          if inner == "}" || inner.hasPrefix("}") {
            closingBrace = j
            break
          }
        }

        guard closingBrace > i else { i += 1; continue }

        let indent = String(lines[i].prefix(while: { $0 == " " || $0 == "\t" }))

        // Build replacement
        var replacement: [String] = []
        if let target = assignTarget {
          replacement.append("\(indent)do {")
          replacement.append("\(indent)    \(target) = \(asyncCall)")
          replacement.append("\(indent)} catch {")
          replacement.append("\(indent)    print(\"\\(error)\")")
          replacement.append("\(indent)}")
        } else {
          // No clear assignment — just call it
          replacement.append("\(indent)do {")
          replacement.append("\(indent)    _ = \(asyncCall)")
          replacement.append("\(indent)} catch {")
          replacement.append("\(indent)    print(\"\\(error)\")")
          replacement.append("\(indent)}")
        }

        // Also carry forward any lines after the assignment that aren't the closing brace
        // (like `self.isLoading = false`)
        for j in (i + 1)..<closingBrace {
          let inner = lines[j].trimmingCharacters(in: .whitespaces)
          if inner.hasPrefix("self.") && !inner.contains("= result") {
            replacement.append("\(indent)\(inner)")
          }
        }

        lines.replaceSubrange(i...closingBrace, with: replacement)
        i += replacement.count
        continue
      }
      i += 1
    }
    return lines.joined(separator: "\n")
  }

  /// Remove type declarations that duplicate existing project types.
  /// Called from Orchestrator with the set of known type names from the project snapshot.
  public func removeDuplicateTypes(_ content: String, existingTypeNames: Set<String>) -> String {
    guard !existingTypeNames.isEmpty else { return content }
    var lines = content.components(separatedBy: "\n")
    let declarationPattern = #"^(public\s+|private\s+|internal\s+|open\s+|fileprivate\s+)?(struct|class|actor|enum)\s+(\w+)"#
    let regex = try? NSRegularExpression(pattern: declarationPattern)

    // Find ranges of duplicate type declarations to remove
    var removeRanges: [(start: Int, end: Int)] = []
    var i = 0
    while i < lines.count {
      let line = lines[i]
      if let match = regex?.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)),
         let nameRange = Range(match.range(at: 3), in: line) {
        let typeName = String(line[nameRange])
        if existingTypeNames.contains(typeName) {
          // Find the matching closing brace
          var braceDepth = 0
          var end = i
          for j in i..<lines.count {
            for ch in lines[j] {
              if ch == "{" { braceDepth += 1 }
              if ch == "}" { braceDepth -= 1 }
            }
            end = j
            if braceDepth <= 0 && j > i { break }
          }
          removeRanges.append((start: i, end: end))
          i = end + 1
          continue
        }
      }
      i += 1
    }

    // Remove in reverse order to preserve indices
    for range in removeRanges.reversed() {
      lines.removeSubrange(range.start...range.end)
    }

    // Clean up consecutive blank lines left by removal
    var result = lines.joined(separator: "\n")
    while result.contains("\n\n\n") {
      result = result.replacingOccurrences(of: "\n\n\n", with: "\n\n")
    }
    return result
  }

  /// Add missing imports based on type usage.
  private func fixMissingImports(_ content: String) -> String {
    let result = content
    let lines = content.components(separatedBy: "\n")
    var insertIndex = 0 // After last import line
    for (i, line) in lines.enumerated() {
      if line.hasPrefix("import ") { insertIndex = i + 1 }
    }

    var missingImports: [String] = []

    // Framework markers — minimal unambiguous identifiers per framework.
    // API signatures are discovered at runtime via SwiftInterfaceIndex;
    // these markers just detect which import statement is needed.
    let frameworkMarkers: [(framework: String, markers: [String])] = [
      ("SwiftUI", ["View", "@State", "@Binding", "@Environment", "NavigationStack", "Text", "VStack"]),
      ("Foundation", ["URLSession", "JSONDecoder", "JSONEncoder", "FileManager", "URLComponents"]),
      ("SwiftData", ["@Model", "ModelContainer", "@Query", "FetchDescriptor"]),
      ("Testing", ["@Test", "#expect", "#require", "@Suite"]),
      ("AVFoundation", ["AVPlayer", "AVAudioSession", "AVPlayerItem"]),
      ("Observation", ["@Observable"]),
      ("Combine", ["AnyCancellable", "Publisher", "CurrentValueSubject"])
    ]

    for (framework, markers) in frameworkMarkers {
      let importStmt = "import \(framework)"
      guard !content.contains(importStmt) else { continue }
      // SwiftUI implicitly imports Foundation and Observation
      if framework == "Foundation" && content.contains("import SwiftUI") { continue }
      if framework == "Observation" && content.contains("import SwiftUI") { continue }
      for marker in markers {
        if content.contains(marker) {
          missingImports.append(importStmt)
          break
        }
      }
    }

    guard !missingImports.isEmpty else { return result }

    var mutableLines = lines
    for imp in missingImports.reversed() {
      // Don't duplicate
      if !mutableLines.contains(imp) {
        mutableLines.insert(imp, at: insertIndex)
      }
    }
    return mutableLines.joined(separator: "\n")
  }

  /// Replace XCTest patterns with Swift Testing.
  /// Only applies to NEW files (determined by caller — linter doesn't know file history).
  private func fixXCTestToSwiftTesting(_ content: String) -> String {
    guard content.contains("XCTest") else { return content }
    var result = content
    result = result.replacingOccurrences(of: "import XCTest", with: "import Testing")
    return result
  }

  /// Fix `let id = UUID()` in Codable types — decoder can't overwrite a `let` with initial value.
  /// Changes to `var id = UUID()` which allows the decoder to set the value from JSON.
  private func fixCodableLetId(_ content: String) -> String {
    guard content.contains("Codable"), content.contains("let id") else { return content }
    return content.replacingOccurrences(
      of: "let id = UUID()",
      with: "var id = UUID()"
    )
  }

  // MARK: - Brace Balancing

  /// Fix unbalanced braces in generated Swift code.
  /// AFM frequently generates code with extra trailing `}` or missing closing braces.
  /// This pass trims extraneous trailing braces or appends missing ones.
  private func balanceBraces(_ content: String) -> String {
    let lines = content.components(separatedBy: "\n")
    var opens = 0
    var closes = 0
    // Count braces outside string literals (rough but effective for generated code)
    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      // Skip string-heavy lines (likely string literals)
      if trimmed.hasPrefix("\"") || trimmed.hasPrefix("let ") && trimmed.contains("\"\"\"") { continue }
      for ch in trimmed {
        if ch == "{" { opens += 1 } else if ch == "}" { closes += 1 }
      }
    }

    if opens == closes { return content }

    var result = lines

    if closes > opens {
      // Too many closing braces — remove extraneous `}` from the end
      var excess = closes - opens
      while excess > 0 && !result.isEmpty {
        let lastTrimmed = result.last?.trimmingCharacters(in: .whitespaces) ?? ""
        if lastTrimmed == "}" || lastTrimmed.isEmpty {
          if lastTrimmed == "}" { excess -= 1 }
          result.removeLast()
        } else {
          break
        }
      }
      // If we couldn't remove enough from the end, return original
      if excess > 0 { return content }
    } else {
      // Too few closing braces — append missing `}` at the end
      let missing = opens - closes
      // Only fix small imbalances (1-2 braces) to avoid masking deeper issues
      if missing > 2 { return content }
      for _ in 0..<missing {
        result.append("}")
      }
    }

    var fixed = result.joined(separator: "\n")
    if !fixed.hasSuffix("\n") { fixed += "\n" }
    return fixed
  }

  // MARK: - Plain Text Output Cleanup

  /// Clean raw LLM output for file content.
  /// Strips markdown fences, leading prose, and normalizes whitespace.
  /// Called after adapter.generate() for create/write (plain text path).
  public func cleanPlainTextOutput(_ text: String, filePath: String) -> String {
    var result = text

    // Strip markdown code fences (model often wraps output in ```swift ... ```)
    for fence in ["```swift\n", "```Swift\n", "```\n"] {
      result = result.replacingOccurrences(of: fence, with: "")
    }
    result = result.replacingOccurrences(of: "\n```", with: "")

    // Strip leading explanation prose before actual code
    // Look for the first line that starts with code (import, struct, class, etc.)
    let codeStarters = ["import ", "struct ", "class ", "enum ", "actor ", "protocol ",
                        "func ", "let ", "var ", "//", "/*", "#!", "<?xml", "<!DOCTYPE",
                        "{", "name:", "FROM ", ".PHONY", "on:", "#"]
    let lines = result.components(separatedBy: "\n")
    var firstCodeLine = 0
    for (i, line) in lines.enumerated() {
      let trimmed = line.trimmingCharacters(in: .whitespaces)
      if codeStarters.contains(where: { trimmed.hasPrefix($0) }) {
        firstCodeLine = i
        break
      }
    }
    if firstCodeLine > 0 {
      // Check if lines before code are prose (contain "Here", "This", "Below", etc.)
      let preamble = lines[0..<firstCodeLine].joined(separator: " ")
      if preamble.contains("Here") || preamble.contains("This") || preamble.contains("Below")
          || preamble.contains("following") || preamble.contains("create") {
        result = lines[firstCodeLine...].joined(separator: "\n")
      }
    }

    // Trim whitespace and ensure trailing newline
    result = result.trimmingCharacters(in: .whitespacesAndNewlines)
    if !result.isEmpty && !result.hasSuffix("\n") { result += "\n" }

    // Apply Swift-specific lint if applicable
    if filePath.hasSuffix(".swift") {
      result = lint(content: result, filePath: filePath)
    }

    return result
  }
}
