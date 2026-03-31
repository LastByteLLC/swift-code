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
    let name = (filePath as NSString).lastPathComponent.lowercased()
    return name == "package.swift"
      || name.hasSuffix(".entitlements")
      || name == "info.plist"
      || name.hasSuffix(".xcprivacy")
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
