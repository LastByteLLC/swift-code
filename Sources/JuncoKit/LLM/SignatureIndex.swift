// SignatureIndex.swift — API signature lookup for compiler-error-driven fix injection
//
// Lightweight index of common Swift API signatures. When the compiler reports
// "no member X" or "incorrect argument label", this index provides the correct
// signature to inject into fix prompts — giving the small model the exact info
// it needs without wasting context on full documentation.

import Foundation

/// A known API signature with its corrected usage.
public struct APISignature: Codable, Sendable {
  /// The type that owns this API (e.g., "URLSession").
  public var typeName: String
  /// The method or property name (e.g., "data(from:)").
  public var member: String
  /// The full correct signature (e.g., "URLSession.shared.data(from: URL) async throws -> (Data, URLResponse)").
  public var signature: String
  /// Common wrong names the model generates for this API.
  public var commonMistakes: [String]

  public init(typeName: String, member: String, signature: String, commonMistakes: [String] = []) {
    self.typeName = typeName
    self.member = member
    self.signature = signature
    self.commonMistakes = commonMistakes
  }
}

/// Index of Swift API signatures for compiler-error-to-fix injection.
public struct SignatureIndex: Sendable {
  private let signatures: [APISignature]
  /// Map from (lowercase type, lowercase member/mistake) → signature
  private let lookupTable: [String: APISignature]

  /// Create an index from a list of signatures.
  public init(signatures: [APISignature]) {
    self.signatures = signatures
    var table: [String: APISignature] = [:]
    for sig in signatures {
      let typeKey = sig.typeName.lowercased()
      // Index by correct member name
      table["\(typeKey).\(sig.member.lowercased())"] = sig
      // Index by common mistakes
      for mistake in sig.commonMistakes {
        table["\(typeKey).\(mistake.lowercased())"] = sig
      }
    }
    self.lookupTable = table
  }

  /// Load the built-in signature index covering common Foundation/SwiftUI/SwiftData APIs.
  public static func builtIn() -> SignatureIndex {
    SignatureIndex(signatures: Self.defaultSignatures)
  }

  /// Load from a JSON file.
  public static func load(from path: String) throws -> SignatureIndex {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let sigs = try JSONDecoder().decode([APISignature].self, from: data)
    return SignatureIndex(signatures: sigs)
  }

  /// Look up the correct API signature from a compiler error message.
  /// Returns a human-readable hint suitable for injection into a fix prompt.
  ///
  /// Parses patterns like:
  /// - `value of type 'URLSession' has no member 'asyncData'`
  /// - `incorrect argument label in call (have 'url:', expected 'from:')`
  /// - `type 'URL' has no member 'contents'`
  public func lookup(compilerError: String) -> String? {
    // Pattern 1: "value of type 'X' has no member 'Y'"
    if let match = compilerError.firstMatch(of: /type '(\w+)' has no member '(\w+)'/) {
      let typeName = String(match.1).lowercased()
      let member = String(match.2).lowercased()
      if let sig = lookupTable["\(typeName).\(member)"] {
        return "Correct API: \(sig.signature)"
      }
    }

    // Pattern 2: "has no member 'X'" (without explicit type)
    if let match = compilerError.firstMatch(of: /has no member '(\w+)'/) {
      let member = String(match.1).lowercased()
      // Search all entries for this member name
      for sig in signatures {
        if sig.commonMistakes.contains(where: { $0.lowercased() == member }) {
          return "Correct API: \(sig.signature)"
        }
      }
    }

    // Pattern 3: "incorrect argument label" with type context
    if let match = compilerError.firstMatch(of: /incorrect argument label.*have '(\w+):'.*expected '(\w+):'/) {
      let _ = String(match.1) // wrong label (unused, kept for future diagnostics)
      let correct = String(match.2).lowercased()
      // Find a signature that mentions the correct label
      for sig in signatures where sig.signature.lowercased().contains("\(correct):") {
        return "Correct API: \(sig.signature)"
      }
    }

    return nil
  }

  /// Number of indexed signatures.
  public var count: Int { signatures.count }
}

// MARK: - Built-in Signatures

extension SignatureIndex {
  // Static fallback table — Tier 3 in the TieredAPISurfaceProvider.
  //
  // ONLY contains entries that:
  //   1. Cannot be discovered from .swiftinterface files at runtime
  //   2. Have been stable in Swift/Apple SDKs for 3+ years
  //
  // Foundation, SwiftUI, and other SDK signatures are discovered at runtime
  // via SwiftInterfaceIndex. Do NOT add SDK types here — add them to the
  // runtime discovery path instead.
  static let defaultSignatures: [APISignature] = [

    // MARK: - Stable Foundation patterns (since Swift 5.5 / iOS 15, 2021)
    // These are in swiftinterface but kept as fallback for when SDK isn't available.
    APISignature(
      typeName: "URLSession",
      member: "data(from:)",
      signature: "URLSession.shared.data(from: URL) async throws -> (Data, URLResponse)",
      commonMistakes: ["asyncData", "fetchData", "getData", "download"]
    ),
    APISignature(
      typeName: "JSONDecoder",
      member: "decode(_:from:)",
      signature: "JSONDecoder().decode(T.self, from: Data) throws -> T",
      commonMistakes: ["decodeJSON", "parse", "fromJSON"]
    ),
    APISignature(
      typeName: "URL",
      member: "init(string:)",
      signature: "URL(string: String) -> URL?",
      commonMistakes: ["fromString", "parse", "create"]
    ),
    APISignature(
      typeName: "FileManager",
      member: "contentsOfDirectory(atPath:)",
      signature: "FileManager.default.contentsOfDirectory(atPath: String) throws -> [String]",
      commonMistakes: ["listFiles", "readDirectory", "ls"]
    ),

    // MARK: - ObjC-bridged methods (NOT in .swiftinterface, stable since iOS 4+)
    APISignature(
      typeName: "AVPlayer",
      member: "play()",
      signature: "player.play()  // player.pause() to stop",
      commonMistakes: ["start", "resume", "begin", "playAudio"]
    ),
    APISignature(
      typeName: "AVAudioSession",
      member: "setCategory(_:)",
      signature: "try AVAudioSession.sharedInstance().setCategory(.playback)",
      commonMistakes: ["setAudioCategory", "configureAudio", "audioSetup"]
    ),
    APISignature(
      typeName: "Process",
      member: "init()",
      signature: "let p = Process(); p.executableURL = URL(fileURLWithPath: path); p.arguments = [...]; try p.run()",
      commonMistakes: ["NSTask", "exec", "shell", "system"]
    ),

    // MARK: - Pattern guidance (not signatures — migration/deprecation knowledge)
    APISignature(
      typeName: "Observable",
      member: "@Observable",
      signature: "@Observable class MyModel { var property: Type }  // NO @Published with @Observable",
      commonMistakes: ["@Published", "ObservableObject", "StateObject"]
    ),
  ]
}
