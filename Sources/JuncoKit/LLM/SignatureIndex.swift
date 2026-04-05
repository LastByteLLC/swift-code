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
  static let defaultSignatures: [APISignature] = [
    // MARK: URLSession / Networking
    APISignature(
      typeName: "URLSession",
      member: "data(from:)",
      signature: "URLSession.shared.data(from: URL) async throws -> (Data, URLResponse)",
      commonMistakes: ["asyncData", "fetchData", "getData", "download"]
    ),
    APISignature(
      typeName: "URLSession",
      member: "data(for:)",
      signature: "URLSession.shared.data(for: URLRequest) async throws -> (Data, URLResponse)",
      commonMistakes: ["send", "execute", "perform"]
    ),
    APISignature(
      typeName: "URLSession",
      member: "upload(for:from:)",
      signature: "URLSession.shared.upload(for: URLRequest, from: Data) async throws -> (Data, URLResponse)",
      commonMistakes: ["uploadData", "post"]
    ),

    // MARK: JSONDecoder / JSONEncoder
    APISignature(
      typeName: "JSONDecoder",
      member: "decode(_:from:)",
      signature: "JSONDecoder().decode(T.self, from: Data) throws -> T",
      commonMistakes: ["decodeJSON", "parse", "fromJSON"]
    ),
    APISignature(
      typeName: "JSONEncoder",
      member: "encode(_:)",
      signature: "JSONEncoder().encode(value) throws -> Data",
      commonMistakes: ["toJSON", "encodeJSON", "serialize"]
    ),

    // MARK: URL / URLComponents
    APISignature(
      typeName: "URL",
      member: "init(string:)",
      signature: "URL(string: String) -> URL?",
      commonMistakes: ["fromString", "parse", "create"]
    ),
    APISignature(
      typeName: "URLComponents",
      member: "queryItems",
      signature: "URLComponents.queryItems: [URLQueryItem]?  // URLQueryItem(name:value:)",
      commonMistakes: ["parameters", "params", "query"]
    ),

    // MARK: FileManager
    APISignature(
      typeName: "FileManager",
      member: "contentsOfDirectory(atPath:)",
      signature: "FileManager.default.contentsOfDirectory(atPath: String) throws -> [String]",
      commonMistakes: ["listFiles", "readDirectory", "ls"]
    ),
    APISignature(
      typeName: "FileManager",
      member: "contents(atPath:)",
      signature: "FileManager.default.contents(atPath: String) -> Data?",
      commonMistakes: ["readFile", "read", "fileContents"]
    ),
    APISignature(
      typeName: "FileManager",
      member: "createDirectory(atPath:withIntermediateDirectories:attributes:)",
      signature: "FileManager.default.createDirectory(atPath: String, withIntermediateDirectories: Bool, attributes: [FileAttributeKey: Any]?) throws",
      commonMistakes: ["mkdir", "makeDirectory", "createDir"]
    ),

    // MARK: String / Data
    APISignature(
      typeName: "String",
      member: "data(using:)",
      signature: "String.data(using: String.Encoding) -> Data?",
      commonMistakes: ["toData", "encode", "utf8Data"]
    ),
    APISignature(
      typeName: "Data",
      member: "init(contentsOf:)",
      signature: "Data(contentsOf: URL) throws",
      commonMistakes: ["fromURL", "load", "read"]
    ),

    // MARK: SwiftUI
    APISignature(
      typeName: "NavigationStack",
      member: "init(path:root:)",
      signature: "NavigationStack(path: Binding<NavigationPath>) { root }",
      commonMistakes: ["NavigationView", "navigationStack"]
    ),
    APISignature(
      typeName: "View",
      member: "task(_:)",
      signature: ".task { async work }  // or .task(id: value) { async work }",
      commonMistakes: ["onAppear", "onLoad", "asyncTask"]
    ),

    // MARK: Observable / SwiftData
    APISignature(
      typeName: "Observable",
      member: "@Observable",
      signature: "@Observable class MyModel { var property: Type }  // NO @Published with @Observable",
      commonMistakes: ["@Published", "ObservableObject", "StateObject"]
    ),

    // MARK: iTunes Search / Podcasts API
    APISignature(
      typeName: "iTunesSearchAPI",
      member: "search",
      signature: "GET https://itunes.apple.com/search?term={query}&media=podcast&limit={n} -> {resultCount: Int, results: [{trackName, artistName, feedUrl, artworkUrl600, ...}]}",
      commonMistakes: ["podcastSearch", "applePodcasts", "searchPodcasts"]
    ),
    APISignature(
      typeName: "iTunesSearchAPI",
      member: "lookup",
      signature: "GET https://itunes.apple.com/lookup?id={podcastId}&entity=podcastEpisode&limit={n} -> {resultCount: Int, results: [{trackName, releaseDate, episodeUrl, description, ...}]}",
      commonMistakes: ["podcastLookup", "getEpisodes", "fetchPodcast"]
    ),

    // MARK: Process / shell
    APISignature(
      typeName: "Process",
      member: "init()",
      signature: "let p = Process(); p.executableURL = URL(fileURLWithPath: \"/usr/bin/...\"); p.arguments = [...]; try p.run(); p.waitUntilExit()",
      commonMistakes: ["NSTask", "exec", "shell", "system"]
    ),
  ]
}
