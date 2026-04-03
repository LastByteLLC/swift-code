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

// MARK: - Swift Test File

@Generable
public struct SwiftTestIntent: Codable, Sendable {
  @Guide(description: "Name of the module being tested") public var moduleName: String
  @Guide(description: "Names of types to test") public var typeNames: [String]
  @Guide(description: "Test function names without the test prefix") public var testNames: [String]
  @Guide(description: "Brief description of what each test checks") public var testDescriptions: [String]
}

// MARK: - Code Fragment (for targeted retry)

@Generable
public struct CodeFragment: Codable, Sendable {
  @Guide(description: "The corrected code") public var content: String
}

// MARK: - Renderer

public struct TemplateRenderer: Sendable {

  public init() {}

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
    }
    return nil
  }

  /// Generate template content by dispatching to the appropriate intent type and renderer.
  /// Returns nil if the file path doesn't match any template.
  public func resolveTemplate(
    filePath: String,
    prompt: String,
    adapter: any LLMAdapter
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
    // swift-tools-version: 6.0
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
      "CFBundlePackageType": "APPL",
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
      "NSPrivacyTracking": intent.tracking,
    ]

    if !intent.accessedAPITypes.isEmpty {
      var apiEntries: [[String: Any]] = []
      for (i, apiType) in intent.accessedAPITypes.enumerated() {
        let reason = i < intent.accessedAPIReasons.count ? intent.accessedAPIReasons[i] : "C617.1"
        apiEntries.append([
          "NSPrivacyAccessedAPIType": apiType,
          "NSPrivacyAccessedAPITypeReasons": [reason],
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

  // MARK: - Swift Test File

  public func renderSwiftTest(_ intent: SwiftTestIntent) -> String {
    var lines = [
      "import Testing",
      "@testable import \(intent.moduleName)",
      "",
    ]
    for (i, testName) in intent.testNames.enumerated() {
      let desc = i < intent.testDescriptions.count ? intent.testDescriptions[i] : testName
      lines.append("@Test func \(testName)() {")
      lines.append("    // \(desc)")
      lines.append("}")
      lines.append("")
    }
    return lines.joined(separator: "\n")
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
