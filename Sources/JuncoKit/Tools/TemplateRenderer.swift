// TemplateRenderer.swift — Intent-based file generation for structured formats
//
// Instead of asking the 3B model to generate raw XML/DSL, the model fills
// in simple @Generable intents (booleans, strings) and this renderer
// produces syntactically-perfect output using proper APIs (XMLDocument/PropertyListSerialization).

import Foundation
import FoundationModels

// MARK: - Entitlements

@Generable
public struct EntitlementsIntent: Codable, Sendable {
  @Guide(description: "Enable app sandbox") public var sandbox: Bool
  @Guide(description: "Allow outbound network connections") public var networkClient: Bool
  @Guide(description: "Allow inbound network connections") public var networkServer: Bool
  @Guide(description: "Allow user-selected file read-write access") public var userFileAccess: Bool
  @Guide(description: "Allow camera access") public var camera: Bool
  @Guide(description: "Allow microphone access") public var microphone: Bool
  @Guide(description: "Allow USB device access") public var usb: Bool
  @Guide(description: "Allow Bluetooth access") public var bluetooth: Bool
  @Guide(description: "Allow location access") public var location: Bool
  @Guide(description: "App group identifiers, empty if none") public var appGroups: [String]
}

// MARK: - Package.swift

@Generable
public struct PackageIntent: Codable, Sendable {
  @Guide(description: "Package name") public var name: String
  @Guide(description: "Product type: library or executable") public var productType: String
  @Guide(description: "Target names") public var targets: [String]
  @Guide(description: "Test target names") public var testTargets: [String]
  @Guide(description: "Dependency URLs like https://github.com/apple/swift-argument-parser") public var dependencies: [String]
  @Guide(description: "Minimum macOS version number like 15") public var macOS: String
  @Guide(description: "Minimum iOS version number like 18") public var iOS: String
}

// MARK: - Info.plist

@Generable
public struct PlistIntent: Codable, Sendable {
  @Guide(description: "App display name") public var displayName: String
  @Guide(description: "Bundle identifier like com.example.myapp") public var bundleIdentifier: String
  @Guide(description: "Camera usage description, empty if not needed") public var cameraUsage: String
  @Guide(description: "Microphone usage description, empty if not needed") public var microphoneUsage: String
  @Guide(description: "Location usage description, empty if not needed") public var locationUsage: String
  @Guide(description: "Photo library usage description, empty if not needed") public var photoUsage: String
  @Guide(description: "Additional Info.plist keys as key=value pairs") public var additionalKeys: [String]
}

// MARK: - Privacy Manifest (.xcprivacy)

@Generable
public struct PrivacyManifestIntent: Codable, Sendable {
  @Guide(description: "Accessed API types like NSPrivacyAccessedAPICategoryFileTimestamp") public var accessedAPITypes: [String]
  @Guide(description: "Reasons for each API type like C617.1") public var accessedAPIReasons: [String]
  @Guide(description: "Whether the app collects tracking data") public var tracking: Bool
  @Guide(description: "Collected data types like NSPrivacyCollectedDataTypeName") public var collectedDataTypes: [String]
}

// MARK: - Gitignore

@Generable
public struct GitignoreIntent: Codable, Sendable {
  @Guide(description: "Include Swift package patterns (.build, .swiftpm)") public var swiftPackage: Bool
  @Guide(description: "Include Xcode patterns (DerivedData, xcuserdata)") public var xcode: Bool
  @Guide(description: "Include CocoaPods patterns (Pods/)") public var cocoapods: Bool
  @Guide(description: "Include macOS system files (.DS_Store)") public var macOS: Bool
  @Guide(description: "Additional custom patterns to ignore, one per entry") public var custom: [String]
}

// MARK: - Xcconfig

@Generable
public struct XcconfigIntent: Codable, Sendable {
  @Guide(description: "Configuration name like Debug or Release") public var name: String
  @Guide(description: "Build settings as KEY = VALUE pairs") public var settings: [String]
}

// MARK: - SwiftUI App Entry Point

@Generable
public struct AppEntryPointIntent: Codable, Sendable {
  @Guide(description: "App struct name like MyApp") public var appName: String
  @Guide(description: "Root view type name like ContentView") public var rootView: String
  @Guide(description: "State properties or empty") public var stateProperties: [String]
}

// MARK: - Swift Test File

@Generable
public struct SwiftTestIntent: Codable, Sendable {
  @Guide(description: "Name of the module being tested") public var moduleName: String
  @Guide(description: "Names of types to test") public var typeNames: [String]
  @Guide(description: "Test function names without the test prefix") public var testNames: [String]
  @Guide(description: "Brief description of what each test checks") public var testDescriptions: [String]
}

// MARK: - Model File (flat schema — no nested arrays)

@Generable
public struct ModelFlatIntent: Codable, Sendable {
  @Guide(description: "Type name like Item") public var typeName: String
  @Guide(description: "First property like let title: String") public var property1: String
  @Guide(description: "Second property like let subtitle: String") public var property2: String
  @Guide(description: "Third property like let imageURL: String?") public var property3: String
  @Guide(description: "Fourth property or blank") public var property4: String
  @Guide(description: "Conformances like Codable, Identifiable") public var conformances: String
}

// MARK: - Service File (flat schema — no nested arrays)

@Generable
public struct ServiceFlatIntent: Codable, Sendable {
  @Guide(description: "Actor name like DataService") public var actorName: String
  @Guide(description: "Method name like fetchItems") public var methodName: String
  @Guide(description: "Parameters like query: String") public var methodParams: String
  @Guide(description: "Return type like [Item]") public var returnType: String
  @Guide(description: "API base URL") public var baseURL: String
  @Guide(description: "Query parameter names comma-separated") public var queryParamNames: String
  @Guide(description: "Fixed query values like type=json, or blank") public var fixedParams: String
}

// MARK: - ViewModel File (flat schema — no nested arrays)

@Generable
public struct ViewModelFlatIntent: Codable, Sendable {
  @Guide(description: "Class name like ItemViewModel") public var className: String
  @Guide(description: "Main collection property like var items: [Item] = []") public var property1: String
  @Guide(description: "Second state property or blank") public var property2: String
  @Guide(description: "Third state property or blank") public var property3: String
  @Guide(description: "Service type name") public var serviceName: String
  @Guide(description: "Async method name like load or search") public var methodName: String
  @Guide(description: "Service call like fetchItems(query: searchText)") public var serviceCall: String
  @Guide(description: "Property to assign result to") public var targetProperty: String
}

// MARK: - ListView File (flat schema)

@Generable
public struct ListViewFlatIntent: Codable, Sendable {
  @Guide(description: "View struct name like ItemListView") public var viewName: String
  @Guide(description: "ViewModel type name") public var viewModelType: String
  @Guide(description: "List data property name") public var listProperty: String
  @Guide(description: "Item type name") public var itemType: String
  @Guide(description: "Primary text property name like title") public var titleProperty: String
  @Guide(description: "Secondary text property or blank") public var subtitleProperty: String
  @Guide(description: "Search binding property or blank") public var searchProperty: String
  @Guide(description: "Async load method name") public var loadMethod: String
  @Guide(description: "Navigation bar title") public var navigationTitle: String
}

// MARK: - Reduced Intents (snapshot-driven, ≤4 fields for reliable 3B output)

@Generable
public struct ViewModelReducedIntent: Codable, Sendable {
  @Guide(description: "Class name like ItemViewModel") public var className: String
  @Guide(description: "Main collection property") public var property1: String
  @Guide(description: "Second state property or blank") public var property2: String
  @Guide(description: "Async method name like load") public var methodName: String
}

@Generable
public struct ListViewReducedIntent: Codable, Sendable {
  @Guide(description: "View name like ItemListView") public var viewName: String
  @Guide(description: "Navigation bar title") public var navigationTitle: String
  @Guide(description: "Item type name") public var itemType: String
}

// MARK: - KV-Line Initializers
// These allow intent structs to be constructed from key-value dictionaries
// parsed from plain text LLM output (the KV-line generation path).

extension ModelFlatIntent {
  static let kvFields: [(key: String, hint: String)] = [
    ("typeName", "struct name"), ("property1", "first property like let title: String"),
    ("property2", "second property"), ("property3", "third property or blank"),
    ("property4", "fourth property or blank"), ("conformances", "like Codable, Identifiable")
  ]
  init(fromKV d: [String: String]) {
    self.init(typeName: d["typeName"] ?? "Item", property1: d["property1"] ?? "",
              property2: d["property2"] ?? "", property3: d["property3"] ?? "",
              property4: d["property4"] ?? "", conformances: d["conformances"] ?? "Codable")
  }
}

extension ServiceFlatIntent {
  static let kvFields: [(key: String, hint: String)] = [
    ("actorName", "service actor name"), ("methodName", "method name like fetchItems"),
    ("methodParams", "parameters like query: String"), ("returnType", "like [Item] or Item"),
    ("baseURL", "API base URL"), ("queryParamNames", "param names comma-separated"),
    ("fixedParams", "fixed values like type=json, or blank")
  ]
  init(fromKV d: [String: String]) {
    self.init(actorName: d["actorName"] ?? "DataService", methodName: d["methodName"] ?? "fetch",
              methodParams: d["methodParams"] ?? "", returnType: d["returnType"] ?? "String",
              baseURL: d["baseURL"] ?? "", queryParamNames: d["queryParamNames"] ?? "",
              fixedParams: d["fixedParams"] ?? "")
  }
}

extension ViewModelFlatIntent {
  static let kvFields: [(key: String, hint: String)] = [
    ("className", "ViewModel class name"), ("property1", "main collection property like var items: [Item] = []"),
    ("property2", "second state property or blank"), ("property3", "third property or blank"),
    ("serviceName", "service type name"), ("methodName", "async method name"),
    ("serviceCall", "service method call like fetchItems(query: searchText)"),
    ("targetProperty", "property to assign result to")
  ]
  init(fromKV d: [String: String]) {
    self.init(className: d["className"] ?? "ViewModel", property1: d["property1"] ?? "",
              property2: d["property2"] ?? "", property3: d["property3"] ?? "",
              serviceName: d["serviceName"] ?? "", methodName: d["methodName"] ?? "load",
              serviceCall: d["serviceCall"] ?? "", targetProperty: d["targetProperty"] ?? "items")
  }
}

extension ViewModelReducedIntent {
  static let kvFields: [(key: String, hint: String)] = [
    ("className", "ViewModel class name"), ("property1", "main collection property"),
    ("property2", "second state property or blank"), ("methodName", "async method name")
  ]
  init(fromKV d: [String: String]) {
    self.init(className: d["className"] ?? "ViewModel", property1: d["property1"] ?? "",
              property2: d["property2"] ?? "", methodName: d["methodName"] ?? "load")
  }
}

extension ListViewFlatIntent {
  static let kvFields: [(key: String, hint: String)] = [
    ("viewName", "view struct name"), ("viewModelType", "ViewModel type"),
    ("listProperty", "list data property"), ("itemType", "item type name"),
    ("titleProperty", "primary text property like title"), ("subtitleProperty", "secondary text or blank"),
    ("searchProperty", "search property or blank"), ("loadMethod", "async load method"),
    ("navigationTitle", "navigation bar title")
  ]
  init(fromKV d: [String: String]) {
    self.init(viewName: d["viewName"] ?? "ListView", viewModelType: d["viewModelType"] ?? "",
              listProperty: d["listProperty"] ?? "items", itemType: d["itemType"] ?? "Item",
              titleProperty: d["titleProperty"] ?? "name", subtitleProperty: d["subtitleProperty"] ?? "",
              searchProperty: d["searchProperty"] ?? "", loadMethod: d["loadMethod"] ?? "load",
              navigationTitle: d["navigationTitle"] ?? "Items")
  }
}

extension ListViewReducedIntent {
  static let kvFields: [(key: String, hint: String)] = [
    ("viewName", "view struct name"), ("navigationTitle", "navigation bar title"),
    ("itemType", "item type name")
  ]
  init(fromKV d: [String: String]) {
    self.init(viewName: d["viewName"] ?? "ListView", navigationTitle: d["navigationTitle"] ?? "",
              itemType: d["itemType"] ?? "Item")
  }
}

extension AppEntryPointIntent {
  static let kvFields: [(key: String, hint: String)] = [
    ("appName", "App struct name"), ("rootView", "root view type")
  ]
  init(fromKV d: [String: String]) {
    self.init(appName: d["appName"] ?? "MyApp", rootView: d["rootView"] ?? "ContentView",
              stateProperties: [])
  }
}

// MARK: - Code Fragment (for targeted retry)

@Generable
public struct CodeFragment: Codable, Sendable {
  @Guide(description: "The corrected code") public var content: String
}

// MARK: - Renderer

public struct TemplateRenderer: Sendable {

  public init() {}

  // MARK: - Swift Toolchain Version

  /// Detected swift-tools-version, cached for the session.
  /// Runs `xcrun swift --version` once, parses "Swift version X.Y".
  /// Falls back to Config.defaultSwiftToolsVersion if detection fails.
  nonisolated(unsafe) private static var _cachedVersion: String?

  public static var swiftToolsVersion: String {
    if let cached = _cachedVersion { return cached }
    let version = detectSwiftVersion()
    _cachedVersion = version
    return version
  }

  /// Check that `xcrun swift --version` succeeds. Returns false if
  /// Xcode/Swift toolchain is not installed.
  public static func isSwiftAvailable() -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["swift", "--version"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      process.waitUntilExit()
      return process.terminationStatus == 0
    } catch {
      return false
    }
  }

  private static func detectSwiftVersion() -> String {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["swift", "--version"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      return Config.defaultSwiftToolsVersion
    }

    guard process.terminationStatus == 0 else {
      return Config.defaultSwiftToolsVersion
    }

    let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
    // Parse "Swift version 6.3" or "Apple Swift version 6.3"
    if let match = output.firstMatch(of: /Swift version (\d+\.\d+)/) {
      return String(match.1)
    }
    return Config.defaultSwiftToolsVersion
  }

  /// Detect if a file path should use template-based generation.
  public func shouldUseTemplate(filePath: String) -> Bool {
    templateSystemPrompt(for: filePath) != nil
  }

  /// Returns the system prompt for template-based generation, or nil if not a template file.
  /// Used by `resolveTemplate` to determine intent and render.
  public func templateSystemPrompt(for filePath: String) -> String? {
    let name = (filePath as NSString).lastPathComponent.lowercased()
    if name.hasSuffix(".entitlements") {
      return "Determine which entitlements this app needs based on the user's request."
    } else if name.hasSuffix("package.swift") {
      return "Determine the SPM package configuration: name, targets, dependencies, platforms."
    } else if name == "info.plist" || name.hasSuffix(".plist") {
      return "Determine the Info.plist configuration: display name, bundle ID, privacy permissions needed."
    } else if name.hasSuffix(".xcprivacy") {
      return "Determine the privacy manifest: accessed API types, reasons, tracking, collected data."
    } else if name == ".gitignore" {
      return "Determine which patterns to ignore. For Swift projects, include swiftPackage and xcode. Always include macOS."
    } else if name.hasSuffix(".xcconfig") {
      return "Generate xcconfig build settings as KEY = VALUE pairs."
    } else if name.hasSuffix("app.swift") {
      return "Determine the app name and root view for this SwiftUI app entry point."
    } else if name.contains("model") && name.hasSuffix(".swift") {
      return "Extract the model types, their properties (with types), and protocol conformances from the request."
    } else if name.contains("service") && name.hasSuffix(".swift") {
      return "Extract the service actor name and its methods with signatures, URLs, and return types."
    } else if name.contains("viewmodel") && name.hasSuffix(".swift") {
      return "Extract the ViewModel class name, state properties, private dependencies, and async loading methods."
    } else if name.contains("view") && name.hasSuffix(".swift") && !name.contains("preview") {
      return "Extract the view name, ViewModel type, list data property, item type, title/subtitle properties, search property, load method, and navigation title."
    }
    return nil
  }

  /// Generate KV-line output from the LLM and parse into a dictionary.
  /// Falls back to JSON parsing if KV parsing yields too few fields.
  /// Returns nil if parsed values are too malformed for safe rendering.
  private func generateKV(
    fields: [(key: String, hint: String)],
    prompt: String,
    system: String,
    adapter: any LLMAdapter
  ) async throws -> [String: String]? {
    let kvHeader = KVLineParser.promptHeader(fields: fields)
    let fullPrompt = "\(kvHeader)\n\n\(prompt)"
    let raw = try await adapter.generate(prompt: fullPrompt, system: system)
    var dict = KVLineParser.parseWithFallback(raw, expectedFields: fields.count)
    let (sanitized, malformedCount) = Self.sanitizeKVValues(dict, fields: fields)
    // If more than half the fields are malformed, bail out to plain generation
    if malformedCount > fields.count / 2 { return nil }
    dict = sanitized
    return dict
  }

  /// Sanitize KV values: detect and fix values that contain raw Swift code fragments,
  /// multi-line content, or structural characters that would break template rendering.
  static func sanitizeKVValues(
    _ dict: [String: String],
    fields: [(key: String, hint: String)]
  ) -> (sanitized: [String: String], malformedCount: Int) {
    var result = dict
    var malformed = 0
    // Swift declaration keywords that should never appear in a simple KV value
    let declKeywords = ["func ", "class ", "struct ", "enum ", "actor ", "protocol ",
                        "import ", "@Observable", "@main", "var body"]
    for (key, value) in dict {
      let trimmed = value.trimmingCharacters(in: .whitespaces)
      // Multi-line values (embedded newlines) are malformed
      if trimmed.contains("\n") {
        result[key] = trimmed.components(separatedBy: "\n").first ?? ""
        malformed += 1
        continue
      }
      // Values containing Swift declarations are malformed
      if declKeywords.contains(where: { trimmed.contains($0) }) {
        // Try to extract just the identifier/value portion
        result[key] = extractSimpleValue(trimmed, for: key)
        malformed += 1
        continue
      }
      // Values with unbalanced braces are malformed
      let opens = trimmed.filter { $0 == "{" }.count
      let closes = trimmed.filter { $0 == "}" }.count
      if opens != closes {
        result[key] = trimmed.filter { $0 != "{" && $0 != "}" }
        malformed += 1
        continue
      }
      // Values that are just the hint text echoed back
      let fieldHint = fields.first(where: { $0.key == key })?.hint ?? ""
      if !fieldHint.isEmpty && trimmed == "(\(fieldHint))" {
        result[key] = ""
        malformed += 1
        continue
      }
    }
    return (result, malformed)
  }

  /// Extract a simple identifier from a malformed KV value containing Swift code.
  private static func extractSimpleValue(_ value: String, for key: String) -> String {
    // "func fetchItems(query: String)" → "fetchItems"
    if value.contains("func "), let name = value.firstMatch(of: /func\s+(\w+)/) {
      return String(name.1)
    }
    // "class PodcastViewModel" → "PodcastViewModel"
    for keyword in ["class ", "struct ", "actor ", "enum "] {
      if value.contains(keyword), let range = value.range(of: keyword) {
        let after = value[range.upperBound...]
        return String(after.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" }))
      }
    }
    // "var items: [Item] = []" → "var items: [Item] = []" (property values are ok for property fields)
    if key.hasPrefix("property") { return value }
    // Fallback: take first word
    return String(value.prefix(while: { $0.isLetter || $0.isNumber || $0 == "_" }))
  }

  /// Generate template content by dispatching to the appropriate intent type and renderer.
  /// Returns nil if the file path doesn't match any template.
  public func resolveTemplate(
    filePath: String,
    prompt: String,
    adapter: any LLMAdapter,
    snapshot: ProjectSnapshot = .empty
  ) async throws -> String? {
    let name = (filePath as NSString).lastPathComponent.lowercased()
    guard let system = templateSystemPrompt(for: filePath) else { return nil }

    if name.hasSuffix(".entitlements") {
      let intent = try await adapter.generateStructured(prompt: prompt, system: system, as: EntitlementsIntent.self, options: nil)
      return renderEntitlements(intent)
    } else if name.hasSuffix("package.swift") {
      let intent = try await adapter.generateStructured(prompt: prompt, system: system, as: PackageIntent.self, options: nil)
      return renderPackage(intent)
    } else if name == "info.plist" || name.hasSuffix(".plist") {
      let intent = try await adapter.generateStructured(prompt: prompt, system: system, as: PlistIntent.self, options: nil)
      return renderPlist(intent)
    } else if name.hasSuffix(".xcprivacy") {
      let intent = try await adapter.generateStructured(prompt: prompt, system: system, as: PrivacyManifestIntent.self, options: nil)
      return renderPrivacyManifest(intent)
    } else if name == ".gitignore" {
      let intent = try await adapter.generateStructured(prompt: prompt, system: system, as: GitignoreIntent.self, options: nil)
      return renderGitignore(intent)
    } else if name.hasSuffix(".xcconfig") {
      let intent = try await adapter.generateStructured(prompt: prompt, system: system, as: XcconfigIntent.self, options: nil)
      return renderXcconfig(intent)
    } else if name.hasSuffix("app.swift") {
      // KV-line path for App entry point (2 fields)
      guard let dict = try await generateKV(fields: AppEntryPointIntent.kvFields, prompt: prompt, system: system, adapter: adapter) else { return nil }
      var intent = AppEntryPointIntent(fromKV: dict)
      if let firstView = snapshot.views.first, intent.rootView == "ContentView" || intent.rootView.isEmpty {
        intent.rootView = firstView.name
      }
      return renderAppEntryPoint(intent)

    } else if name.contains("model") && name.hasSuffix(".swift") && !name.contains("viewmodel") {
      // KV-line path for Model (6 fields)
      guard let dict = try await generateKV(fields: ModelFlatIntent.kvFields, prompt: prompt, system: system, adapter: adapter) else { return nil }
      let intent = ModelFlatIntent(fromKV: dict)
      return renderModelFlat(intent)

    } else if name.contains("service") && name.hasSuffix(".swift") {
      // KV-line path for Service (7 fields)
      guard let dict = try await generateKV(fields: ServiceFlatIntent.kvFields, prompt: prompt, system: system, adapter: adapter) else { return nil }
      let intent = ServiceFlatIntent(fromKV: dict)
      let rendered = renderServiceFlat(intent)
      if let error = validateTemplateOutput(rendered, filePath: filePath) {
        throw PipelineError.validationFailed(file: filePath, error: "Template: \(error)")
      }
      return rendered

    } else if name.contains("viewmodel") && name.hasSuffix(".swift") {
      let deriver = SnapshotDeriver()
      // Snapshot-driven KV-line path (4 fields) when service data is available
      if !snapshot.services.isEmpty {
        if let dict = try await generateKV(fields: ViewModelReducedIntent.kvFields, prompt: prompt, system: system, adapter: adapter) {
          let reduced = ViewModelReducedIntent(fromKV: dict)
          if let full = deriver.deriveViewModel(reduced: reduced, snapshot: snapshot) {
            let rendered = renderViewModelFlat(full)
            if let error = validateTemplateOutput(rendered, filePath: filePath) {
              throw PipelineError.validationFailed(file: filePath, error: "Template: \(error)")
            }
            return rendered
          }
        }
      }
      // Fallback: KV-line with full 8 fields
      guard let dict = try await generateKV(fields: ViewModelFlatIntent.kvFields, prompt: prompt, system: system, adapter: adapter) else { return nil }
      let intent = ViewModelFlatIntent(fromKV: dict)
      let rendered = renderViewModelFlat(intent)
      if let error = validateTemplateOutput(rendered, filePath: filePath) {
        throw PipelineError.validationFailed(file: filePath, error: "Template: \(error)")
      }
      return rendered

    } else if name.contains("view") && name.hasSuffix(".swift") && !name.contains("preview") {
      let deriver = SnapshotDeriver()
      let hasVM = (snapshot.services + snapshot.models).contains(where: { $0.name.contains("ViewModel") })
      let hasModel = snapshot.models.contains(where: { !$0.name.contains("ViewModel") })
      // Snapshot-driven KV-line path (3 fields) when ViewModel + Model data available
      if hasVM && hasModel {
        if let dict = try await generateKV(fields: ListViewReducedIntent.kvFields, prompt: prompt, system: system, adapter: adapter) {
          let reduced = ListViewReducedIntent(fromKV: dict)
          if let full = deriver.deriveListView(reduced: reduced, snapshot: snapshot) {
            let rendered = renderListView(full)
            if let error = validateTemplateOutput(rendered, filePath: filePath) {
              throw PipelineError.validationFailed(file: filePath, error: "Template: \(error)")
            }
            return rendered
          }
        }
      }
      // Fallback: KV-line with full 9 fields
      guard let dict = try await generateKV(fields: ListViewFlatIntent.kvFields, prompt: prompt, system: system, adapter: adapter) else { return nil }
      let intent = ListViewFlatIntent(fromKV: dict)
      let rendered = renderListView(intent)
      if let error = validateTemplateOutput(rendered, filePath: filePath) {
        throw PipelineError.validationFailed(file: filePath, error: "Template: \(error)")
      }
      return rendered
    }
    return nil
  }

  // MARK: - Template Output Validation

  /// Validate rendered template output for critical issues.
  /// Returns nil if valid, or an error description if the output is broken.
  public func validateTemplateOutput(_ content: String, filePath: String) -> String? {
    guard filePath.hasSuffix(".swift") else { return nil }

    let nonBlankLines = content.components(separatedBy: "\n")
      .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    if nonBlankLines.count < 3 {
      return "Template output too short (\(nonBlankLines.count) non-blank lines)"
    }

    let opens = content.filter { $0 == "{" }.count
    let closes = content.filter { $0 == "}" }.count
    if opens != closes {
      return "Unbalanced braces: \(opens) open, \(closes) close"
    }

    let name = (filePath as NSString).lastPathComponent.lowercased()
    if name.contains("viewmodel") {
      if !content.contains("class ") && !content.contains("@Observable") {
        return "ViewModel missing class declaration or @Observable"
      }
    } else if name.contains("view") && !name.contains("preview") {
      if !content.contains("View") || !content.contains("body") {
        return "View missing View conformance or body property"
      }
    }
    if name.contains("service") {
      if !content.contains("actor ") && !content.contains("class ") && !content.contains("struct ") {
        return "Service missing type declaration"
      }
    }

    return nil
  }

  // MARK: - Entitlements

  public func renderEntitlements(_ intent: EntitlementsIntent) -> String {
    var dict: [String: Any] = [:]

    if intent.sandbox { dict["com.apple.security.app-sandbox"] = true }
    if intent.networkClient { dict["com.apple.security.network.client"] = true }
    if intent.networkServer { dict["com.apple.security.network.server"] = true }
    if intent.userFileAccess { dict["com.apple.security.files.user-selected.read-write"] = true }
    if intent.camera { dict["com.apple.security.device.camera"] = true }
    if intent.microphone { dict["com.apple.security.device.audio-input"] = true }
    if intent.usb { dict["com.apple.security.device.usb"] = true }
    if intent.bluetooth { dict["com.apple.security.device.bluetooth"] = true }
    if intent.location { dict["com.apple.security.personal-information.location"] = true }

    let groups = intent.appGroups.filter { !$0.isEmpty }
    if !groups.isEmpty {
      dict["com.apple.security.application-groups"] = groups
    }

    return serializePlist(dict)
  }

  // MARK: - Package.swift

  public func renderPackage(_ intent: PackageIntent) -> String {
    var platforms: [String] = []
    if !intent.macOS.isEmpty { platforms.append(".macOS(.v\(intent.macOS))") }
    if !intent.iOS.isEmpty { platforms.append(".iOS(.v\(intent.iOS))") }
    let platformsLine = platforms.isEmpty ? "" : "\n    platforms: [\(platforms.joined(separator: ", "))],"

    let mainTargets = intent.targets.isEmpty ? [intent.name] : intent.targets
    let productName = mainTargets.first ?? intent.name
    let productLine: String
    if intent.productType == "executable" {
      productLine = ".executableProduct(name: \"\(productName)\", targets: [\(mainTargets.map { "\"\($0)\"" }.joined(separator: ", "))])"
    } else {
      productLine = ".library(name: \"\(productName)\", targets: [\(mainTargets.map { "\"\($0)\"" }.joined(separator: ", "))])"
    }

    var deps: [String] = []
    for url in intent.dependencies where !url.isEmpty {
      deps.append("        .package(url: \"\(url)\", from: \"1.0.0\")")
    }
    let depsBlock = deps.isEmpty ? "" : "\n\(deps.joined(separator: ",\n"))\n    "

    var targets: [String] = []
    for t in mainTargets {
      targets.append("        .target(name: \"\(t)\")")
    }
    for t in intent.testTargets where !t.isEmpty {
      let dep = mainTargets.first ?? intent.name
      targets.append("        .testTarget(name: \"\(t)\", dependencies: [\"\(dep)\"])")
    }

    return """
    // swift-tools-version: \(Self.swiftToolsVersion)
    import PackageDescription

    let package = Package(
        name: "\(intent.name)",\(platformsLine)
        products: [
            \(productLine)
        ],
        dependencies: [\(depsBlock)],
        targets: [
    \(targets.joined(separator: ",\n"))
        ]
    )
    """
  }

  // MARK: - Info.plist

  public func renderPlist(_ intent: PlistIntent) -> String {
    var dict: [String: Any] = [
      "CFBundleName": intent.displayName,
      "CFBundleIdentifier": intent.bundleIdentifier,
      "CFBundleVersion": "1",
      "CFBundleShortVersionString": "1.0",
      "CFBundlePackageType": "APPL"
    ]
    if !intent.cameraUsage.isEmpty {
      dict["NSCameraUsageDescription"] = intent.cameraUsage
    }
    if !intent.microphoneUsage.isEmpty {
      dict["NSMicrophoneUsageDescription"] = intent.microphoneUsage
    }
    if !intent.locationUsage.isEmpty {
      dict["NSLocationWhenInUseUsageDescription"] = intent.locationUsage
    }
    if !intent.photoUsage.isEmpty {
      dict["NSPhotoLibraryUsageDescription"] = intent.photoUsage
    }
    for kv in intent.additionalKeys where kv.contains("=") {
      let parts = kv.split(separator: "=", maxSplits: 1)
      if parts.count == 2 {
        dict[String(parts[0])] = String(parts[1])
      }
    }
    return serializePlist(dict)
  }

  // MARK: - Privacy Manifest

  public func renderPrivacyManifest(_ intent: PrivacyManifestIntent) -> String {
    var dict: [String: Any] = [
      "NSPrivacyTracking": intent.tracking
    ]

    if !intent.accessedAPITypes.isEmpty {
      var apiEntries: [[String: Any]] = []
      for (i, apiType) in intent.accessedAPITypes.enumerated() {
        let reason = i < intent.accessedAPIReasons.count ? intent.accessedAPIReasons[i] : "C617.1"
        apiEntries.append([
          "NSPrivacyAccessedAPIType": apiType,
          "NSPrivacyAccessedAPITypeReasons": [reason]
        ])
      }
      dict["NSPrivacyAccessedAPITypes"] = apiEntries
    }

    if !intent.collectedDataTypes.isEmpty {
      dict["NSPrivacyCollectedDataTypes"] = intent.collectedDataTypes
    }

    return serializePlist(dict)
  }

  // MARK: - Gitignore

  public func renderGitignore(_ intent: GitignoreIntent) -> String {
    var lines: [String] = ["# Generated by junco"]
    if intent.swiftPackage {
      lines += ["", "# Swift Package Manager", ".build/", ".swiftpm/", "Package.resolved"]
    }
    if intent.xcode {
      lines += ["", "# Xcode", "DerivedData/", "xcuserdata/", "*.xcodeproj/xcuserdata/", "*.xcodeproj/project.xcworkspace/xcshareddata/IDEWorkspaceChecks.plist"]
    }
    if intent.cocoapods {
      lines += ["", "# CocoaPods", "Pods/", "Podfile.lock"]
    }
    if intent.macOS {
      lines += ["", "# macOS", ".DS_Store", "._*", "*.swp", "*~"]
    }
    for pattern in intent.custom where !pattern.isEmpty {
      lines.append(pattern)
    }
    return lines.joined(separator: "\n") + "\n"
  }

  // MARK: - Xcconfig

  public func renderXcconfig(_ intent: XcconfigIntent) -> String {
    var lines = ["// \(intent.name).xcconfig", "// Generated by junco", ""]
    for setting in intent.settings where !setting.isEmpty {
      lines.append(setting)
    }
    return lines.joined(separator: "\n") + "\n"
  }

  // MARK: - SwiftUI App Entry Point

  public func renderAppEntryPoint(_ intent: AppEntryPointIntent) -> String {
    let props = intent.stateProperties.filter { !$0.isEmpty }
    return SwiftCode {
      Import("SwiftUI")
      Blank()
      Struct(intent.appName, attributes: ["@main"], conformances: ["App"]) {
        for prop in props {
          Property(prop)
        }
        if !props.isEmpty { Blank() }
        ComputedVar("body", type: "some Scene") {
          Line("WindowGroup {")
          Line("    \(intent.rootView)()")
          Line("}")
        }
      }
    }.render()
  }

  // MARK: - Models File (flat)

  public func renderModelFlat(_ intent: ModelFlatIntent) -> String {
    let rawProps = [intent.property1, intent.property2, intent.property3, intent.property4]
      .filter { !$0.isEmpty }
    let conformances = intent.conformances.split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .filter { !$0.isEmpty }
    let isCodable = conformances.contains("Codable")
    let needsId = conformances.contains("Identifiable") && !rawProps.contains(where: { $0.contains("id") })

    // Pre-sanitize properties outside the builder
    let props: [String] = rawProps.map { prop in
      let decl = prop.hasPrefix("let ") || prop.hasPrefix("var ") ? prop : "let \(prop)"
      // Fix Codable: `let name = ""` → `let name: String` (decoder can't overwrite let initial)
      if isCodable, decl.hasPrefix("let "), decl.contains(" = ") {
        let parts = decl.split(separator: "=", maxSplits: 1)
        let nameAndType = parts[0].trimmingCharacters(in: .whitespaces)
        if !nameAndType.contains(":") {
          let defaultVal = parts.count > 1 ? parts[1].trimmingCharacters(in: .whitespaces) : ""
          let inferredType: String
          if defaultVal.hasPrefix("\"") { inferredType = "String" } else if defaultVal == "0" || defaultVal == "0.0" { inferredType = "Int" } else if defaultVal == "true" || defaultVal == "false" { inferredType = "Bool" } else if defaultVal == "[]" { inferredType = "[String]" } else { inferredType = "String" }
          return "\(nameAndType): \(inferredType)"
        } else {
          return String(nameAndType)
        }
      }
      return decl
    }

    return SwiftCode {
      Import("Foundation")
      Blank()
      Struct(intent.typeName, conformances: conformances) {
        if needsId { Property("var id = UUID()") }
        for prop in props { Property(prop) }
      }
    }.render()
  }

  // MARK: - Service File

  public func renderServiceFlat(_ intent: ServiceFlatIntent) -> String {
    // Build query items from param names
    let paramNames = intent.queryParamNames.split(separator: ",")
      .map { $0.trimmingCharacters(in: .whitespaces) }
      .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "=")) }
    let fixedPairs = intent.fixedParams.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    let dynamicParams = paramNames.filter { name in
      !fixedPairs.contains(where: { $0.hasPrefix(name + "=") })
    }

    // Use methodParams for the function signature (friendly names), fall back to query param names.
    // Sanitize: strip parentheses, ensure name: Type format, reject malformed input.
    let rawParams = intent.methodParams
      .trimmingCharacters(in: .whitespaces)
      .trimmingCharacters(in: CharacterSet(charactersIn: "()"))
    let paramSig: String
    if rawParams.isEmpty || !rawParams.contains(":") || rawParams.contains(")(") {
      paramSig = dynamicParams.map { "\($0): String" }.joined(separator: ", ")
    } else {
      paramSig = rawParams
    }
    let sig = "func \(intent.methodName)(\(paramSig)) async throws -> \(intent.returnType)"

    // Map friendly param names → query param names for URLQueryItem values
    let friendlyNames = paramSig.split(separator: ",").compactMap { part -> String? in
      let trimmed = part.trimmingCharacters(in: .whitespaces)
      return trimmed.split(separator: ":").first.map { String($0).trimmingCharacters(in: .whitespaces) }
    }

    return SwiftCode {
      Import("Foundation")
      Blank()
      Actor(intent.actorName) {
        Function(sig) {
          Line("var components = URLComponents(string: \"\(intent.baseURL)\")!")
          Line("components.queryItems = [")
          for name in paramNames {
            if let fixed = fixedPairs.first(where: { $0.hasPrefix(name + "=") }) {
              let value = String(fixed.split(separator: "=", maxSplits: 1).last ?? "")
              Line("    URLQueryItem(name: \"\(name)\", value: \"\(value)\"),")
            } else {
              // Use the friendly parameter name if available, otherwise the query param name
              let dynamicIndex = dynamicParams.firstIndex(of: name) ?? 0
              let varName = dynamicIndex < friendlyNames.count ? friendlyNames[dynamicIndex] : name
              Line("    URLQueryItem(name: \"\(name)\", value: \(varName)),")
            }
          }
          Line("]")
          Line("let (data, _) = try await URLSession.shared.data(from: components.url!)")
          if intent.returnType.hasPrefix("[") {
            // Array decode — need a wrapper struct
            Line("struct SearchResult: Codable { let results: \(intent.returnType) }")
            Line("let decoded = try JSONDecoder().decode(SearchResult.self, from: data)")
            Line("return decoded.results")
          } else {
            Line("return try JSONDecoder().decode(\(intent.returnType).self, from: data)")
          }
        }
      }
    }.render()
  }

  // MARK: - ViewModel File (flat)

  public func renderViewModelFlat(_ intent: ViewModelFlatIntent) -> String {
    let props = [intent.property1, intent.property2, intent.property3].filter { !$0.isEmpty }

    // Sanitize serviceCall: strip `service.` prefix and default value syntax from arguments
    var sanitizedCall = intent.serviceCall.hasPrefix("service.")
      ? String(intent.serviceCall.dropFirst(8)) : intent.serviceCall
    sanitizedCall = sanitizedCall.replacingOccurrences(
      of: #"\s*=\s*"[^"]*""#, with: "", options: .regularExpression
    )
    sanitizedCall = sanitizedCall.replacingOccurrences(
      of: #"\s*=\s*\[\]"#, with: "", options: .regularExpression
    )
    // Also strip `= someDefault` patterns (but not `=` that's part of a comparison)
    sanitizedCall = sanitizedCall.replacingOccurrences(
      of: #":\s*(\w+)\s*=\s*\w+"#, with: ": $1", options: .regularExpression
    )

    return SwiftCode {
      Import("Foundation")
      Blank()
      Class(intent.className, attributes: ["@Observable"]) {
        for prop in props {
          Property(prop.hasPrefix("var ") ? prop : "var \(prop)")
        }
        if !props.isEmpty { Blank() }
        Property("private let service = \(intent.serviceName)()")
        Blank()
        Function("func \(intent.methodName)() async") {
          Line("do {")
          Line("    \(intent.targetProperty) = try await service.\(sanitizedCall)")
          Line("} catch {")
          Line("    print(\"\\(error)\")")
          Line("}")
        }
      }
    }.render()
  }

  // MARK: - ListView File

  public func renderListView(_ intent: ListViewFlatIntent) -> String {
    // Sanitize field values — strip quotes, parens, special chars that break interpolation
    let sanitize: (String) -> String = { $0.filter { $0.isLetter || $0.isNumber || $0 == "_" } }
    let isPropertyName: (String) -> Bool = { s in
      guard let first = s.first else { return false }
      return first.isLowercase  // Property names are camelCase, type names are PascalCase
    }
    let viewName = sanitize(intent.viewName).isEmpty ? "ListView" : sanitize(intent.viewName)
    let vmType = sanitize(intent.viewModelType).isEmpty ? "ViewModel" : sanitize(intent.viewModelType)
    let listProp = sanitize(intent.listProperty).isEmpty ? "items" : sanitize(intent.listProperty)
    // Guard: reject type names (PascalCase) in property fields — fall back to "name"
    let rawTitle = sanitize(intent.titleProperty)
    let titleProp = rawTitle.isEmpty || !isPropertyName(rawTitle) ? "name" : rawTitle
    let rawSubtitle = sanitize(intent.subtitleProperty)
    let subtitleProp = !isPropertyName(rawSubtitle) ? "" : rawSubtitle
    let searchProp = sanitize(intent.searchProperty)
    let loadMethod = sanitize(intent.loadMethod).isEmpty ? "load" : sanitize(intent.loadMethod)
    let navTitle = intent.navigationTitle.filter { $0 != "\"" }

    let hasSearch = !searchProp.isEmpty
    let hasSubtitle = !subtitleProp.isEmpty

    return SwiftCode {
      Import("SwiftUI")
      Blank()
      Struct(viewName, conformances: ["View"]) {
        Property("@State var viewModel = \(vmType)()")
        Blank()
        ComputedVar("body", type: "some View") {
          Line("NavigationStack {")
          Line("    List(viewModel.\(listProp)) { item in")
          if hasSubtitle {
            Line("        VStack(alignment: .leading) {")
            Line("            Text(item.\(titleProp))")
            Line("            Text(item.\(subtitleProp))")
            Line("                .font(.caption)")
            Line("                .foregroundStyle(.secondary)")
            Line("        }")
          } else {
            Line("        Text(item.\(titleProp))")
          }
          Line("    }")
          Line("    .navigationTitle(\"\(navTitle)\")")
          if hasSearch {
            Line("    .searchable(text: $viewModel.\(searchProp))")
          }
          Line("    .task { await viewModel.\(loadMethod)() }")
          Line("}")
        }
      }
    }.render()
  }

  // MARK: - Swift Test File

  public func renderSwiftTest(_ intent: SwiftTestIntent) -> String {
    SwiftCode {
      Import("Testing")
      Line("@testable import \(intent.moduleName)")
      Blank()
      for (i, testName) in intent.testNames.enumerated() {
        let desc = i < intent.testDescriptions.count ? intent.testDescriptions[i] : testName
        Function("@Test func \(testName)()") {
          Comment(desc)
        }
        Blank()
      }
    }.render()
  }

  // MARK: - Plist Serialization

  /// Serialize a dictionary to Apple plist XML format using PropertyListSerialization.
  private func serializePlist(_ dict: [String: Any]) -> String {
    guard let data = try? PropertyListSerialization.data(
      fromPropertyList: dict,
      format: .xml,
      options: 0
    ) else {
      // Fallback: shouldn't happen with valid dict, but return empty plist
      return "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<!DOCTYPE plist PUBLIC \"-//Apple//DTD PLIST 1.0//EN\" \"http://www.apple.com/DTDs/PropertyList-1.0.dtd\">\n<plist version=\"1.0\">\n<dict/>\n</plist>"
    }
    return String(data: data, encoding: .utf8) ?? ""
  }
}
