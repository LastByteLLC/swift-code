// SwiftInterfaceIndex.swift — Runtime API discovery from macOS SDK
//
// Parses .swiftinterface files from the SDK to build a type→members index.
// Replaces hardcoded API signatures with runtime discovery.
// Lazy-loads per framework, caches to disk between sessions.

import Foundation

// MARK: - Types

/// A single member (method, property, initializer) of a Swift type.
public struct APIMemberInfo: Codable, Sendable {
  public let typeName: String     // "URLSession"
  public let memberName: String   // "data" or "data(from:delegate:)"
  public let signature: String    // Full one-line signature from swiftinterface
  public let kind: APIMemberKind

  public init(typeName: String, memberName: String, signature: String, kind: APIMemberKind) {
    self.typeName = typeName
    self.memberName = memberName
    self.signature = signature
    self.kind = kind
  }
}

public enum APIMemberKind: String, Codable, Sendable {
  case function, property, initializer
}

/// Parsed API surface of a single framework.
struct FrameworkSurface: Codable, Sendable {
  let framework: String
  let types: [String: [APIMemberInfo]]  // typeName → members
  let sdkVersion: String
}

// MARK: - SwiftInterfaceIndex

/// Discovers and indexes Swift API signatures from SDK .swiftinterface files.
/// Provides fuzzy matching to correct hallucinated API names.
public actor SwiftInterfaceIndex {
  private var frameworkCache: [String: FrameworkSurface] = [:]
  private var typeToFramework: [String: String] = [:]
  private var sdkPath: String?
  private var sdkPathResolved = false
  private let cacheDirectory: String

  public init(cacheDirectory: String, sdkPath: String? = nil) {
    self.sdkPath = sdkPath
    self.sdkPathResolved = sdkPath != nil
    self.cacheDirectory = cacheDirectory
  }

  /// Lazily resolve SDK path on first framework load.
  private func ensureSDKPath() {
    guard !sdkPathResolved else { return }
    sdkPathResolved = true
    sdkPath = Self.discoverSDKPath()
    try? FileManager.default.createDirectory(atPath: cacheDirectory, withIntermediateDirectories: true)
  }

  /// Discover SDK path without spawning a Process (safe for test environments).
  /// Falls back to known Xcode paths.
  private static func discoverSDKPathWithoutProcess() -> String? {
    let knownPaths = [
      "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk",
      "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk",
    ]
    return knownPaths.first(where: { FileManager.default.fileExists(atPath: $0) })
  }

  // MARK: - Public API

  /// Get all members of a type. Lazy-loads the framework if needed.
  public func members(of type: String, in framework: String? = nil) async -> [APIMemberInfo] {
    if let fw = framework {
      let surface = await loadOrParse(fw)
      return surface?.types[type] ?? []
    }
    // Search across all loaded frameworks
    for (_, surface) in frameworkCache {
      if let members = surface.types[type] { return members }
    }
    // Try to find by reverse lookup
    if let fw = typeToFramework[type] {
      let surface = await loadOrParse(fw)
      return surface?.types[type] ?? []
    }
    return []
  }

  /// Fuzzy-match a hallucinated member name to the closest real member.
  public func closestMember(to hallucinated: String, on type: String) async -> APIMemberInfo? {
    let typeMembers = await members(of: type)
    guard !typeMembers.isEmpty else { return nil }
    return fuzzyMatch(hallucinated, in: typeMembers)
  }

  /// Which framework provides this type?
  public func typeBelongsTo(_ typeName: String) async -> String? {
    if let cached = typeToFramework[typeName] { return cached }
    // Search loaded frameworks
    for (_, surface) in frameworkCache {
      if surface.types[typeName] != nil { return surface.framework }
    }
    // Try common frameworks
    for fw in Self.commonFrameworks {
      let surface = await loadOrParse(fw)
      if surface?.types[typeName] != nil { return fw }
    }
    return nil
  }

  /// All type names in a framework.
  public func allTypes(in framework: String) async -> Set<String> {
    guard let surface = await loadOrParse(framework) else { return [] }
    return Set(surface.types.keys)
  }

  /// Preload a framework into the cache.
  public func preload(_ framework: String) async {
    _ = await loadOrParse(framework)
  }

  // MARK: - SDK Discovery

  static func discoverSDKPath() -> String? {
    // Use known paths to avoid spawning Process (which triggers assertions in test environments)
    let knownPaths = [
      "/Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk",
      "/Library/Developer/CommandLineTools/SDKs/MacOSX.sdk",
    ]
    if let found = knownPaths.first(where: { FileManager.default.fileExists(atPath: $0) }) {
      return found
    }

    // Fallback: try xcrun (requires Xcode CLI tools)
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["--show-sdk-path"]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      process.waitUntilExit()
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      if let path = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
         FileManager.default.fileExists(atPath: path) {
        return path
      }
    } catch {}

    return nil
  }

  // MARK: - Interface File Resolution

  private func interfacePath(for framework: String) -> String? {
    guard let sdk = sdkPath else { return nil }

    // Architecture: prefer arm64e, fall back to x86_64
    let archs = ["arm64e-apple-macos", "x86_64-apple-macos"]

    for arch in archs {
      // Framework-style (SwiftUI, Foundation, etc.)
      let fwPath = "\(sdk)/System/Library/Frameworks/\(framework).framework/Modules/\(framework).swiftmodule/\(arch).swiftinterface"
      if FileManager.default.fileExists(atPath: fwPath) { return fwPath }

      // Library-style (AVFoundation, Observation, etc.)
      let libPath = "\(sdk)/usr/lib/swift/\(framework).swiftmodule/\(arch).swiftinterface"
      if FileManager.default.fileExists(atPath: libPath) { return libPath }
    }

    return nil
  }

  // MARK: - Parsing

  private func loadOrParse(_ framework: String) async -> FrameworkSurface? {
    ensureSDKPath()
    // In-memory cache
    if let cached = frameworkCache[framework] { return cached }

    // Disk cache
    let cachePath = "\(cacheDirectory)/\(framework).json"
    let currentSDKVersion = sdkVersionString()
    if let data = try? Data(contentsOf: URL(fileURLWithPath: cachePath)),
       let surface = try? JSONDecoder().decode(FrameworkSurface.self, from: data),
       surface.sdkVersion == currentSDKVersion {
      frameworkCache[framework] = surface
      buildReverseMap(surface)
      return surface
    }

    // Parse from .swiftinterface
    guard let surface = parseFramework(framework) else { return nil }
    frameworkCache[framework] = surface
    buildReverseMap(surface)

    // Persist cache (best effort)
    let encoder = JSONEncoder()
    if let data = try? encoder.encode(surface) {
      try? data.write(to: URL(fileURLWithPath: cachePath))
    }

    return surface
  }

  private func parseFramework(_ name: String) -> FrameworkSurface? {
    guard let path = interfacePath(for: name) else { return nil }
    guard let content = try? String(contentsOfFile: path, encoding: .utf8) else { return nil }

    var types: [String: [APIMemberInfo]] = [:]
    var currentType: String?
    var braceDepth = 0

    let lines = content.components(separatedBy: "\n")

    for line in lines {
      let trimmed = line.trimmingCharacters(in: .whitespaces)

      // Skip comments and compiler flags
      if trimmed.hasPrefix("//") || trimmed.isEmpty { continue }

      // Track brace depth to know when we exit a type
      let opens = trimmed.filter { $0 == "{" }.count
      let closes = trimmed.filter { $0 == "}" }.count

      // Detect type declarations and extensions at depth 0
      if braceDepth == 0, let typeName = extractTypeName(trimmed, moduleName: name) {
        currentType = typeName
        if types[typeName] == nil { types[typeName] = [] }
      }

      braceDepth += opens - closes
      braceDepth = max(0, braceDepth)

      // Reset type when we return to depth 0
      if braceDepth == 0 { currentType = nil }

      // Extract members at depth 1 (inside a type body)
      if braceDepth == 1, let type = currentType {
        if let member = extractMember(trimmed, typeName: type) {
          types[type, default: []].append(member)
        }
      }
    }

    return FrameworkSurface(
      framework: name,
      types: types,
      sdkVersion: sdkVersionString()
    )
  }

  /// Extract a type name from a declaration line, stripping module prefixes.
  private func extractTypeName(_ line: String, moduleName: String) -> String? {
    let patterns: [(String, Bool)] = [
      // extension Foundation.URLSession {
      ("extension \(moduleName).", true),
      // extension URLSession {
      ("extension ", true),
      // open class AVPlayer : NSObject {
      ("open class ", false), ("public class ", false),
      ("public struct ", false), ("open struct ", false),
      ("public enum ", false),
      ("public protocol ", false),
      ("public actor ", false),
    ]

    for (prefix, isExtension) in patterns {
      guard line.hasPrefix(prefix) else { continue }
      let rest = line.dropFirst(prefix.count)
      // Extract the type name (up to : or { or <)
      let name = rest.prefix(while: { $0 != ":" && $0 != "{" && $0 != "<" && $0 != " " && $0 != "," })
      let nameStr = String(name).trimmingCharacters(in: .whitespaces)
      guard !nameStr.isEmpty else { continue }

      if isExtension {
        // Strip module prefix if present: "Foundation.URLSession" → "URLSession"
        let components = nameStr.split(separator: ".")
        return String(components.last ?? Substring(nameStr))
      }
      return nameStr
    }
    return nil
  }

  /// Extract a member (function/property) from a line within a type body.
  private func extractMember(_ line: String, typeName: String) -> APIMemberInfo? {
    let trimmed = line.trimmingCharacters(in: .whitespaces)

    // Functions: public func data(from url: ...) async throws -> ...
    if trimmed.contains("func ") {
      guard let funcRange = trimmed.range(of: "func ") else { return nil }
      let nameAndParams = String(trimmed[funcRange.upperBound...])
      let name = nameAndParams.prefix(while: { $0 != "(" && $0 != " " && $0 != "<" })
      guard !name.isEmpty else { return nil }
      let sig = String(trimmed.prefix(120))
      return APIMemberInfo(
        typeName: typeName,
        memberName: String(name),
        signature: sig,
        kind: trimmed.contains("init(") ? .initializer : .function
      )
    }

    // Properties: public var currentItem: AVPlayerItem? { get }
    if (trimmed.hasPrefix("public var ") || trimmed.hasPrefix("open var ") ||
        trimmed.hasPrefix("public let ") || trimmed.hasPrefix("open let ")) {
      let declStart = trimmed.range(of: "var ") ?? trimmed.range(of: "let ")
      guard let start = declStart?.upperBound else { return nil }
      let name = String(trimmed[start...]).prefix(while: { $0 != ":" && $0 != " " && $0 != "(" })
      let sig = String(trimmed.prefix(100))
      return APIMemberInfo(
        typeName: typeName,
        memberName: String(name),
        signature: sig,
        kind: .property
      )
    }

    return nil
  }

  // MARK: - Fuzzy Matching

  private func fuzzyMatch(_ hallucinated: String, in members: [APIMemberInfo]) -> APIMemberInfo? {
    let query = hallucinated.lowercased()
    // Strip common hallucinatory prefixes
    let stripped = Self.stripPrefixes(query)

    var bestMatch: APIMemberInfo?
    var bestScore = 0

    for member in members {
      let name = member.memberName.lowercased()

      var score = 0
      if name == query || name == stripped { score = 100 }
      else if name.contains(stripped) && stripped.count >= 3 { score = 70 }
      else if stripped.contains(name) && name.count >= 3 { score = 60 }
      else if query.hasSuffix(name) || name.hasSuffix(stripped) { score = 55 }
      else {
        let dist = Self.levenshtein(name, stripped)
        if dist <= 3 { score = 40 - dist * 10 }
      }

      if score > bestScore { bestScore = score; bestMatch = member }
    }

    return bestScore >= 20 ? bestMatch : nil
  }

  static func stripPrefixes(_ name: String) -> String {
    let prefixes = ["async", "fetch", "get", "load", "set", "on", "perform", "execute"]
    for prefix in prefixes {
      if name.hasPrefix(prefix) && name.count > prefix.count {
        let stripped = String(name.dropFirst(prefix.count))
        if let first = stripped.first, first.isUppercase {
          return stripped.lowercased()
        }
        return stripped
      }
    }
    return name
  }

  static func levenshtein(_ s1: String, _ s2: String) -> Int {
    let a = Array(s1), b = Array(s2)
    var dp = Array(repeating: Array(repeating: 0, count: b.count + 1), count: a.count + 1)
    for i in 0...a.count { dp[i][0] = i }
    for j in 0...b.count { dp[0][j] = j }
    for i in 1...a.count {
      for j in 1...b.count {
        let cost = a[i-1] == b[j-1] ? 0 : 1
        dp[i][j] = min(dp[i-1][j] + 1, dp[i][j-1] + 1, dp[i-1][j-1] + cost)
      }
    }
    return dp[a.count][b.count]
  }

  // MARK: - Helpers

  private func buildReverseMap(_ surface: FrameworkSurface) {
    for typeName in surface.types.keys {
      typeToFramework[typeName] = surface.framework
    }
  }

  private func sdkVersionString() -> String {
    guard let sdk = sdkPath else { return "unknown" }
    let versionFile = "\(sdk)/SDKSettings.json"
    if let data = try? Data(contentsOf: URL(fileURLWithPath: versionFile)),
       let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
       let version = json["Version"] as? String {
      return version
    }
    // Fallback: use SDK path as version key
    return sdk.components(separatedBy: "/").last ?? "unknown"
  }

  // Note: Foundation.swiftinterface (22K lines) can trigger runtime assertions
  // in some SDK versions. It's loaded on-demand but not in commonFrameworks.
  private static let commonFrameworks = [
    "Observation", "Combine", "SwiftData",
  ]
}
