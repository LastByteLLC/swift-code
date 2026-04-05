// ProjectAnalyzer.swift — Extracts structured project context for prompt enrichment
//
// Walks the tree-sitter index to identify models, views, services, navigation
// patterns, and test patterns. Outputs a compact ProjectSnapshot that fits
// in ~400 tokens for LLM prompt injection.

import Foundation

/// A type summary extracted from the project index.
public struct TypeSummary: Sendable {
  public let name: String
  public let file: String
  public let kind: String         // "struct", "class", "actor", "enum", "protocol"
  public let properties: [String] // "let name: String", "var count: Int"
  public let methods: [String]    // "func fetchAll() async throws"
  public let conformances: [String] // "View", "Codable", "Identifiable"

  public init(name: String, file: String, kind: String,
              properties: [String] = [], methods: [String] = [],
              conformances: [String] = []) {
    self.name = name
    self.file = file
    self.kind = kind
    self.properties = properties
    self.methods = methods
    self.conformances = conformances
  }
}

/// A structured snapshot of the project for prompt enrichment.
public struct ProjectSnapshot: Sendable {
  /// Data types (structs with stored properties, Codable/Identifiable types)
  public let models: [TypeSummary]
  /// SwiftUI views (types conforming to View)
  public let views: [TypeSummary]
  /// Services and managers (actors, singletons, managers)
  public let services: [TypeSummary]
  /// Detected navigation pattern ("NavigationStack", "TabView", etc.)
  public let navigationPattern: String?
  /// Detected test pattern ("Swift Testing @Test" or "XCTest")
  public let testPattern: String?
  /// Key files by role
  public let keyFiles: [String: String] // role → path

  /// Compact description for prompt injection, within token budget.
  public func compactDescription(budget: Int = 400) -> String {
    var parts: [String] = []

    if !models.isEmpty {
      let modelDescs = models.prefix(5).map { m in
        let props = m.properties.prefix(6).joined(separator: ", ")
        return "\(m.name)(\(props))"
      }
      parts.append("Models: \(modelDescs.joined(separator: "; "))")
    }

    if !views.isEmpty {
      let viewNames = views.prefix(8).map(\.name)
      parts.append("Views: \(viewNames.joined(separator: ", "))")
    }

    if !services.isEmpty {
      let svcDescs = services.prefix(4).map { s in
        let methods = s.methods.prefix(4).joined(separator: ", ")
        return "\(s.name) (\(s.kind): \(methods))"
      }
      parts.append("Services: \(svcDescs.joined(separator: "; "))")
    }

    if let nav = navigationPattern {
      parts.append("Navigation: \(nav)")
    }

    if let test = testPattern {
      parts.append("Tests: \(test)")
    }

    let result = parts.joined(separator: "\n")
    return TokenBudget.truncate(result, toTokens: budget)
  }

  /// Condensed type signatures for injection into create prompts.
  /// Gives the LLM exact property/method names to reference and a do-not-redeclare instruction.
  /// At step 4+, compresses to just type names (the model has seen full signatures earlier).
  public func typeSignatureBlock(budget: Int = 150, stepIndex: Int = 0) -> String {
    let allTypes = models + services + views
    guard !allTypes.isEmpty else { return "" }

    // At later steps, compress to just names to save ~120 tokens
    if stepIndex >= 3 {
      let names = allTypes.map { "\($0.kind) \($0.name)" }
      return "// Known types: \(names.joined(separator: ", "))"
    }

    var lines: [String] = ["// EXISTING TYPES — reference these, do NOT redeclare:"]
    for t in allTypes {
      let conformances = t.conformances.isEmpty ? "" : ": \(t.conformances.joined(separator: ", "))"
      let props = t.properties.map { $0.trimmingCharacters(in: .whitespaces) }
      let meths = t.methods.map { $0.trimmingCharacters(in: .whitespaces) }
      let members = (props + meths).joined(separator: "; ")
      let body = members.isEmpty ? "" : " { \(members) }"
      lines.append("// \(t.kind) \(t.name)\(conformances)\(body)")
    }

    let result = lines.joined(separator: "\n")
    return TokenBudget.truncate(result, toTokens: budget)
  }

  /// Merge new types into an existing snapshot, replacing any from the same file.
  /// Used to keep the snapshot current after creating/editing files mid-pipeline.
  public func merging(
    typesFromFile filePath: String,
    newModels: [TypeSummary],
    newViews: [TypeSummary],
    newServices: [TypeSummary]
  ) -> ProjectSnapshot {
    // Remove any existing types from this file, then append new ones
    let filteredModels = models.filter { $0.file != filePath } + newModels
    let filteredViews = views.filter { $0.file != filePath } + newViews
    let filteredServices = services.filter { $0.file != filePath } + newServices

    return ProjectSnapshot(
      models: filteredModels,
      views: filteredViews,
      services: filteredServices,
      navigationPattern: navigationPattern,
      testPattern: testPattern,
      keyFiles: keyFiles
    )
  }

  /// Empty snapshot for projects with no analyzable code.
  public static let empty = ProjectSnapshot(
    models: [], views: [], services: [],
    navigationPattern: nil, testPattern: nil, keyFiles: [:]
  )
}

/// Analyzes project structure from the tree-sitter index.
public struct ProjectAnalyzer: Sendable {

  public init() {}

  /// Build a structured snapshot from the project index.
  /// Zero LLM calls — purely deterministic analysis.
  public func analyze(
    index: [IndexEntry],
    domain: DomainConfig,
    files: FileTools
  ) -> ProjectSnapshot {
    // Group entries by file
    let typeEntries = index.filter { $0.kind == .type }
    let funcEntries = index.filter { $0.kind == .function }
    let propEntries = index.filter { $0.kind == .property }

    // Build type summaries by reading snippets and inferring roles
    var models: [TypeSummary] = []
    var views: [TypeSummary] = []
    var services: [TypeSummary] = []
    var keyFiles: [String: String] = [:]

    for typeEntry in typeEntries {
      // Skip extensions and imports
      if typeEntry.symbolName.hasPrefix("extension ") { continue }

      // Gather properties and methods for this type
      let typeProps = propEntries.filter { $0.filePath == typeEntry.filePath }
        .map(\.symbolName)
      let typeMethods = funcEntries.filter { $0.filePath == typeEntry.filePath }
        .map(\.symbolName)

      // Try to read the type declaration line for conformances and kind
      let snippet = typeEntry.snippet
      let (kind, conformances) = parseTypeDeclaration(snippet, name: typeEntry.symbolName)

      let summary = TypeSummary(
        name: typeEntry.symbolName,
        file: typeEntry.filePath,
        kind: kind,
        properties: typeProps,
        methods: typeMethods,
        conformances: conformances
      )

      // Classify by role
      if conformances.contains("View") || typeEntry.filePath.contains("View") {
        views.append(summary)
      } else if kind == "actor" || typeEntry.symbolName.hasSuffix("Service") ||
                  typeEntry.symbolName.hasSuffix("Manager") ||
                  typeEntry.symbolName.hasSuffix("Store") {
        services.append(summary)
      } else if !typeProps.isEmpty || conformances.contains("Codable") ||
                  conformances.contains("Identifiable") || conformances.contains("Hashable") {
        models.append(summary)
      }
    }

    // Detect navigation pattern from view files
    let navigationPattern = detectNavigationPattern(views: views, files: files)

    // Detect test pattern
    let testPattern = detectTestPattern(files: files)

    // Identify key files
    let allFiles = index.filter { $0.kind == .file }
    for entry in allFiles {
      let name = (entry.filePath as NSString).lastPathComponent
      if name.hasSuffix("App.swift") || entry.snippet.contains("@main") {
        keyFiles["entry"] = entry.filePath
      } else if name == "Package.swift" {
        keyFiles["package"] = entry.filePath
      }
    }

    return ProjectSnapshot(
      models: models,
      views: views,
      services: services,
      navigationPattern: navigationPattern,
      testPattern: testPattern,
      keyFiles: keyFiles
    )
  }

  // MARK: - Incremental Updates

  /// Update a snapshot after creating or editing a single file.
  /// Re-indexes the file via TreeSitter and merges its types into the snapshot.
  public func updateSnapshot(
    _ snapshot: ProjectSnapshot,
    afterWriting filePath: String,
    content: String,
    extractor: TreeSitterExtractor
  ) -> ProjectSnapshot {
    let entries = extractor.extract(from: content, file: filePath)
    let typeEntries = entries.filter { $0.kind == .type }
    let funcEntries = entries.filter { $0.kind == .function }
    let propEntries = entries.filter { $0.kind == .property }

    var newModels: [TypeSummary] = []
    var newViews: [TypeSummary] = []
    var newServices: [TypeSummary] = []

    for typeEntry in typeEntries {
      if typeEntry.symbolName.hasPrefix("extension ") { continue }

      let typeProps = propEntries.map(\.symbolName)
      let typeMethods = funcEntries.map(\.symbolName)
      let (kind, conformances) = parseTypeDeclaration(typeEntry.snippet, name: typeEntry.symbolName)

      let summary = TypeSummary(
        name: typeEntry.symbolName, file: filePath, kind: kind,
        properties: typeProps, methods: typeMethods, conformances: conformances
      )

      if conformances.contains("View") || filePath.contains("View") {
        newViews.append(summary)
      } else if kind == "actor" || typeEntry.symbolName.hasSuffix("Service") ||
                  typeEntry.symbolName.hasSuffix("Manager") ||
                  typeEntry.symbolName.hasSuffix("Store") {
        newServices.append(summary)
      } else if !typeProps.isEmpty || conformances.contains("Codable") ||
                  conformances.contains("Identifiable") || conformances.contains("Hashable") {
        newModels.append(summary)
      }
    }

    return snapshot.merging(
      typesFromFile: filePath,
      newModels: newModels, newViews: newViews, newServices: newServices
    )
  }

  // MARK: - Helpers

  /// Parse type kind and conformances from the snippet's first line.
  private func parseTypeDeclaration(_ snippet: String, name: String) -> (kind: String, conformances: [String]) {
    let firstLine = snippet.components(separatedBy: "\n").first ?? ""

    // Determine kind
    let kind: String
    if firstLine.contains("actor ") { kind = "actor" }
    else if firstLine.contains("class ") { kind = "class" }
    else if firstLine.contains("enum ") { kind = "enum" }
    else if firstLine.contains("protocol ") { kind = "protocol" }
    else { kind = "struct" }

    // Extract conformances from ": Protocol1, Protocol2" or ": Superclass, Protocol"
    var conformances: [String] = []
    if let colonRange = firstLine.range(of: ":") {
      let afterColon = firstLine[colonRange.upperBound...]
      // Take everything up to the opening brace
      let upToBrace = afterColon.split(separator: "{").first ?? afterColon[...]
      let parts = upToBrace.split(separator: ",")
      for part in parts {
        let trimmed = part.trimmingCharacters(in: .whitespaces)
        // Skip generic constraints (where clauses)
        if trimmed.lowercased().hasPrefix("where") { break }
        // Take just the type name (not generic params)
        let typeName = trimmed.split(separator: "<").first.map(String.init) ?? trimmed
        if !typeName.isEmpty && typeName != name {
          conformances.append(typeName)
        }
      }
    }

    return (kind, conformances)
  }

  /// Detect navigation pattern by searching view files for NavigationStack/TabView/etc.
  private func detectNavigationPattern(views: [TypeSummary], files: FileTools) -> String? {
    let patterns = ["NavigationStack", "NavigationSplitView", "TabView", "NavigationView"]
    for view in views.prefix(10) {
      guard let content = try? files.read(path: view.file, maxTokens: 400) else { continue }
      for pattern in patterns {
        if content.contains(pattern) {
          return "\(pattern) in \(view.file)"
        }
      }
    }
    return nil
  }

  /// Detect test pattern by checking for @Test or XCTestCase in test files.
  private func detectTestPattern(files: FileTools) -> String? {
    let testFiles = files.listFiles(extensions: ["swift"]).filter {
      $0.contains("Tests/") || $0.contains("Test")
    }
    guard !testFiles.isEmpty else { return nil }

    let count = testFiles.count
    for file in testFiles.prefix(5) {
      guard let content = try? files.read(path: file, maxTokens: 200) else { continue }
      if content.contains("@Test") {
        return "Swift Testing @Test (\(count) test files)"
      } else if content.contains("XCTestCase") {
        return "XCTest (\(count) test files)"
      }
    }
    return "\(count) test files"
  }
}
