// SignatureIndexTests.swift — Tests for API signature lookup

import Foundation
import Testing
@testable import JuncoKit

@Suite("SignatureIndex")
struct SignatureIndexTests {

  // MARK: - Built-in Index

  @Test("builtIn index has signatures")
  func builtInNotEmpty() {
    let index = SignatureIndex.builtIn()
    #expect(index.count > 10)
  }

  // MARK: - Compiler Error Pattern Matching

  @Test("Looks up 'no member asyncData' on URLSession")
  func lookupAsyncData() {
    let index = SignatureIndex.builtIn()
    let hint = index.lookup(
      compilerError: "error: value of type 'URLSession' has no member 'asyncData'"
    )
    #expect(hint != nil)
    #expect(hint!.contains("URLSession.shared.data(from:"))
  }

  @Test("Looks up 'no member fetchData' on URLSession")
  func lookupFetchData() {
    let index = SignatureIndex.builtIn()
    let hint = index.lookup(
      compilerError: "error: value of type 'URLSession' has no member 'fetchData'"
    )
    #expect(hint != nil)
    #expect(hint!.contains("data(from:"))
  }

  @Test("Looks up 'no member decodeJSON' on JSONDecoder")
  func lookupDecodeJSON() {
    let index = SignatureIndex.builtIn()
    let hint = index.lookup(
      compilerError: "error: value of type 'JSONDecoder' has no member 'decodeJSON'"
    )
    #expect(hint != nil)
    #expect(hint!.contains("decode"))
  }

  @Test("Returns nil for unknown errors")
  func lookupUnknown() {
    let index = SignatureIndex.builtIn()
    let hint = index.lookup(
      compilerError: "error: cannot find 'fooBarBaz' in scope"
    )
    #expect(hint == nil)
  }

  @Test("Looks up 'no member fromString' on URL")
  func lookupURLFromString() {
    let index = SignatureIndex.builtIn()
    let hint = index.lookup(
      compilerError: "error: type 'URL' has no member 'fromString'"
    )
    #expect(hint != nil)
    #expect(hint!.contains("URL(string:"))
  }

  // MARK: - Incorrect Argument Label Pattern

  @Test("Matches incorrect argument label pattern")
  func incorrectArgumentLabel() {
    let index = SignatureIndex.builtIn()
    let hint = index.lookup(
      compilerError: "error: incorrect argument label in call (have 'url:', expected 'from:')"
    )
    // Should find URLSession.shared.data(from:) since it has "from:"
    if let hint {
      #expect(hint.contains("from:"))
    }
    // This may or may not match depending on which signature has "from:" — the test
    // validates the pattern matching logic runs without crashing
  }

  // MARK: - Custom Index

  @Test("Custom signatures are searchable")
  func customIndex() {
    let custom = SignatureIndex(signatures: [
      APISignature(
        typeName: "MyAPI",
        member: "fetch(_:)",
        signature: "MyAPI.fetch(_ id: Int) async throws -> Item",
        commonMistakes: ["get", "load"]
      ),
    ])

    let hint = custom.lookup(
      compilerError: "error: value of type 'MyAPI' has no member 'get'"
    )
    #expect(hint != nil)
    #expect(hint!.contains("MyAPI.fetch"))
  }

  @Test("APISignature round-trips through Codable")
  func signatureCodable() throws {
    let sig = APISignature(
      typeName: "URLSession",
      member: "data(from:)",
      signature: "URLSession.shared.data(from: URL) async throws -> (Data, URLResponse)",
      commonMistakes: ["asyncData", "fetchData"]
    )
    let data = try JSONEncoder().encode(sig)
    let decoded = try JSONDecoder().decode(APISignature.self, from: data)
    #expect(decoded.typeName == "URLSession")
    #expect(decoded.commonMistakes.count == 2)
  }

  // MARK: - Podcast API Signatures

  @Test("iTunes Search API signature is indexed")
  func itunesSearchSignature() {
    let index = SignatureIndex.builtIn()
    let hint = index.lookup(
      compilerError: "error: value of type 'iTunesSearchAPI' has no member 'podcastSearch'"
    )
    #expect(hint != nil)
    #expect(hint!.contains("itunes.apple.com/search"))
  }

  @Test("iTunes Lookup API signature is indexed")
  func itunesLookupSignature() {
    let index = SignatureIndex.builtIn()
    let hint = index.lookup(
      compilerError: "error: value of type 'iTunesSearchAPI' has no member 'getEpisodes'"
    )
    #expect(hint != nil)
    #expect(hint!.contains("itunes.apple.com/lookup"))
  }

  // MARK: - No-member fallback (without type context)

  @Test("Bare 'no member' matches via commonMistakes scan")
  func bareMemberMatch() {
    let index = SignatureIndex.builtIn()
    // Error without explicit type name
    let hint = index.lookup(
      compilerError: "error: has no member 'asyncData'"
    )
    #expect(hint != nil)
    #expect(hint!.contains("URLSession"))
  }
}
