// SignatureIndexTests.swift — Tests for API signature lookup (static fallback table)

import Foundation
import Testing
@testable import JuncoKit

@Suite("SignatureIndex")
struct SignatureIndexTests {

  // MARK: - Built-in Index

  @Test("builtIn index has signatures")
  func builtInNotEmpty() {
    let index = SignatureIndex.builtIn()
    #expect(index.count >= 4, "Should have at least the core fallback entries")
  }

  // MARK: - Stable Foundation Patterns (kept in static table)

  @Test("Looks up 'no member asyncData' on URLSession")
  func lookupAsyncData() {
    let index = SignatureIndex.builtIn()
    let hint = index.lookup(
      compilerError: "error: value of type 'URLSession' has no member 'asyncData'"
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

  @Test("Looks up 'no member fromString' on URL")
  func lookupURLFromString() {
    let index = SignatureIndex.builtIn()
    let hint = index.lookup(
      compilerError: "error: type 'URL' has no member 'fromString'"
    )
    #expect(hint != nil)
    #expect(hint!.contains("URL(string:"))
  }

  @Test("Returns nil for unknown errors")
  func lookupUnknown() {
    let index = SignatureIndex.builtIn()
    let hint = index.lookup(
      compilerError: "error: cannot find 'fooBarBaz' in scope"
    )
    #expect(hint == nil)
  }

  // MARK: - ObjC-Bridged Methods (not in swiftinterface)

  @Test("AVPlayer.play lookup works")
  func lookupAVPlayerPlay() {
    let index = SignatureIndex.builtIn()
    let hint = index.lookup(
      compilerError: "error: value of type 'AVPlayer' has no member 'start'"
    )
    #expect(hint != nil)
    #expect(hint!.contains("play()"))
  }

  // MARK: - Pattern Guidance

  @Test("@Observable pattern is indexed")
  func observablePattern() {
    let index = SignatureIndex.builtIn()
    let hint = index.lookup(
      compilerError: "error: value of type 'Observable' has no member 'ObservableObject'"
    )
    #expect(hint != nil)
    #expect(hint!.contains("@Observable"))
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

  // MARK: - Bare member fallback

  @Test("Bare 'no member' matches via commonMistakes scan")
  func bareMemberMatch() {
    let index = SignatureIndex.builtIn()
    let hint = index.lookup(
      compilerError: "error: has no member 'asyncData'"
    )
    #expect(hint != nil)
    #expect(hint!.contains("URLSession"))
  }

  // MARK: - Argument label pattern

  @Test("Matches incorrect argument label pattern")
  func incorrectArgumentLabel() {
    let index = SignatureIndex.builtIn()
    let hint = index.lookup(
      compilerError: "error: incorrect argument label in call (have 'url:', expected 'from:')"
    )
    if let hint {
      #expect(hint.contains("from:"))
    }
  }
}
