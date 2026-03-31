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
    result = fixObservablePublished(result)
    result = fixNavigationView(result)
    result = fixMissingImports(result)
    result = fixXCTestToSwiftTesting(result)
    return result
  }

  // MARK: - Rules

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

  /// Add missing imports based on type usage.
  private func fixMissingImports(_ content: String) -> String {
    var result = content
    let lines = content.components(separatedBy: "\n")
    var insertIndex = 0 // After last import line
    for (i, line) in lines.enumerated() {
      if line.hasPrefix("import ") { insertIndex = i + 1 }
    }

    var missingImports: [String] = []

    // SwiftUI types
    let swiftUITypes = ["View", "@State", "@Binding", "@Environment", "NavigationStack",
                        "TabView", "List", "Form", "TextField", "Toggle", "Picker",
                        "Stepper", "Button", "Text", "Image", "VStack", "HStack",
                        "ZStack", "ScrollView", "LazyVGrid", "LazyHGrid", "Color",
                        "GeometryReader", "@Observable", "@Query", "ContentUnavailableView",
                        "@ScaledMetric", "ProgressView", "Label", "Section",
                        "AsyncImage", "Chart", "BarMark", "LineMark"]
    if !content.contains("import SwiftUI") {
      for t in swiftUITypes {
        if content.contains(t) {
          missingImports.append("import SwiftUI")
          break
        }
      }
    }

    // Foundation types
    let foundationTypes = ["URL", "Data", "Date", "UUID", "JSONEncoder", "JSONDecoder",
                           "URLSession", "URLRequest", "URLError", "FileManager",
                           "ProcessInfo", "UserDefaults", "ISO8601DateFormatter",
                           "RelativeDateTimeFormatter", "Timer", "Notification"]
    if !content.contains("import Foundation") && !content.contains("import SwiftUI") {
      for t in foundationTypes {
        // Check for the type as a word boundary (not substring of another word)
        let pattern = "\\b\(t)\\b"
        if content.range(of: pattern, options: .regularExpression) != nil {
          missingImports.append("import Foundation")
          break
        }
      }
    }

    // SwiftData
    if !content.contains("import SwiftData") {
      if content.contains("@Model") || content.contains("ModelContainer") || content.contains("ModelContext")
          || content.contains("@Query") || content.contains("FetchDescriptor") {
        missingImports.append("import SwiftData")
      }
    }

    // Testing
    if !content.contains("import Testing") {
      if content.contains("@Test") || content.contains("#expect") || content.contains("#require") || content.contains("@Suite") {
        missingImports.append("import Testing")
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
    // Don't try to transform XCTAssert → #expect automatically — too many variants.
    // The micro-skill already tells the model to use Swift Testing.
    return result
  }
}
