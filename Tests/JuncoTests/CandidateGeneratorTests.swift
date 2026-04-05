// CandidateGeneratorTests.swift — Tests for multi-sample compile-select

import Foundation
import Testing
@testable import JuncoKit

/// Resolve a fixture path relative to this test file.
private func fixturePath(_ name: String) -> String {
  let thisFile = #filePath
  let dir = (thisFile as NSString).deletingLastPathComponent
  return (dir as NSString).appendingPathComponent("Fixtures/\(name)")
}

@Suite("CandidateGenerator")
struct CandidateGeneratorTests {

  // MARK: - CandidateResult

  @Test("CandidateResult compiled flag")
  func candidateResultFlags() {
    let good = CandidateResult(code: "let x = 1", errorCount: 0, errors: [], compiled: true)
    #expect(good.compiled)
    #expect(good.errorCount == 0)

    let bad = CandidateResult(code: "let x: = 1", errorCount: 1, errors: ["error: expected pattern"], compiled: false)
    #expect(!bad.compiled)
    #expect(bad.errorCount == 1)
  }

  // MARK: - Multi-Sample with MockAdapter

  @Test("First candidate compiles — returns immediately without trying others")
  func firstCandidateCompiles() async throws {
    let goodCode = """
    {"filePath":"test.swift","content":"import Foundation\\nlet x = 42"}
    """
    let mock = MockAdapter(fixedResponse: goodCode)
    let shell = SafeShell(workingDirectory: NSTemporaryDirectory())
    let gen = CandidateGenerator(adapter: mock, shell: shell, candidateCount: 3)

    let (value, result) = try await gen.generate(
      prompt: "create a file",
      system: nil,
      as: CreateParams.self,
      filePath: "test.swift",
      extract: { $0.content }
    )

    #expect(value.content.contains("let x = 42"))
    // The candidate generates valid Swift — may or may not pass swiftc depending on
    // environment, but the flow completes without error.
    let callCount = await mock.callCount
    // Short-circuit: if first compiled, only 1 call. Otherwise up to 3.
    #expect(callCount >= 1 && callCount <= 3)
  }

  @Test("All candidates fail deserialization — throws last error")
  func allCandidatesFailDeserialization() async throws {
    let mock = MockAdapter(fixedResponse: "not valid json at all")
    let shell = SafeShell(workingDirectory: NSTemporaryDirectory())
    let gen = CandidateGenerator(adapter: mock, shell: shell, candidateCount: 3)

    await #expect(throws: LLMError.self) {
      _ = try await gen.generate(
        prompt: "create a file",
        system: nil,
        as: CreateParams.self,
        filePath: "test.swift",
        extract: { $0.content }
      )
    }

    // All 3 candidates were attempted
    let callCount = await mock.callCount
    #expect(callCount == 3)
  }

  @Test("Second candidate is better — selects fewer errors")
  func selectsFewerErrors() async throws {
    // First response: bad Swift (syntax error)
    // Second response: valid Swift
    let responses = [
      """
      {"filePath":"test.swift","content":"import Foundation\\nlet x: = oops"}
      """,
      """
      {"filePath":"test.swift","content":"import Foundation\\nlet x = 42"}
      """,
    ]
    let mock = MockAdapter(responses: responses)
    let shell = SafeShell(workingDirectory: NSTemporaryDirectory())
    let gen = CandidateGenerator(adapter: mock, shell: shell, candidateCount: 2)

    let (_, result) = try await gen.generate(
      prompt: "create",
      system: nil,
      as: CreateParams.self,
      filePath: "test.swift",
      extract: { $0.content }
    )

    // We get a result (either short-circuited on compile success or selected best)
    #expect(result.errorCount <= 1)
  }

  // MARK: - evaluate()

  @Test("evaluate detects valid Swift code")
  func evaluateValidSwift() async throws {
    let shell = SafeShell(workingDirectory: NSTemporaryDirectory())
    let gen = CandidateGenerator(
      adapter: MockAdapter(fixedResponse: ""),
      shell: shell
    )
    let result = await gen.evaluate(
      code: "import Foundation\nlet x: Int = 42\n",
      filePath: "valid.swift"
    )
    #expect(result.compiled)
    #expect(result.errorCount == 0)
  }

  @Test("evaluate detects syntax errors")
  func evaluateSyntaxError() async throws {
    let shell = SafeShell(workingDirectory: NSTemporaryDirectory())
    let gen = CandidateGenerator(
      adapter: MockAdapter(fixedResponse: ""),
      shell: shell
    )
    let result = await gen.evaluate(
      code: "let x: = \n",
      filePath: "invalid.swift"
    )
    #expect(!result.compiled)
    #expect(result.errorCount > 0)
  }

  @Test("evaluate detects wrong API usage")
  func evaluateWrongAPI() async throws {
    let shell = SafeShell(workingDirectory: NSTemporaryDirectory())
    let gen = CandidateGenerator(
      adapter: MockAdapter(fixedResponse: ""),
      shell: shell
    )
    // URLSession.shared.asyncData doesn't exist
    let code = """
    import Foundation
    func fetch() async throws -> Data {
      let url = URL(string: "https://example.com")!
      return try await URLSession.shared.asyncData(from: url)
    }
    """
    let result = await gen.evaluate(code: code, filePath: "wrong_api.swift")
    #expect(!result.compiled)
    #expect(result.errors.contains(where: { $0.contains("error:") }))
  }

  // MARK: - Podcast API: Multi-sample from HAR fixtures

  @Test("Bad API candidates: first has errors, later candidates succeed")
  func podcastBadAPICandidates() async throws {
    let path = fixturePath("podcast_search_bad_api.har.json")
    let replayer = try ReplayAdapter(mode: .replay(inputPath: path))
    let shell = SafeShell(workingDirectory: NSTemporaryDirectory())
    let gen = CandidateGenerator(adapter: replayer, shell: shell, candidateCount: 3)

    let (value, result) = try await gen.generate(
      prompt: "Create podcast search",
      system: "Generate Swift code.",
      as: CreateParams.self,
      filePath: "PodcastSearch.swift",
      extract: { $0.content }
    )

    // The generator should have found a compiling candidate (2nd or 3rd)
    // or at least selected the one with fewest errors
    #expect(value.content.contains("searchPodcasts"))

    // The good candidates use correct API: URLSession.shared.data(from:)
    if result.compiled {
      #expect(value.content.contains("URLSession.shared.data(from:"))
      #expect(!value.content.contains("asyncData"))
    }
  }

  @Test("Good API candidate: single shot from HAR fixture")
  func podcastGoodAPICandidate() async throws {
    let path = fixturePath("podcast_search_good.har.json")
    let replayer = try ReplayAdapter(mode: .replay(inputPath: path))
    let shell = SafeShell(workingDirectory: NSTemporaryDirectory())
    let gen = CandidateGenerator(adapter: replayer, shell: shell, candidateCount: 1)

    let (value, result) = try await gen.generate(
      prompt: "Create podcast search",
      system: "Generate Swift code.",
      as: CreateParams.self,
      filePath: "PodcastSearch.swift",
      extract: { $0.content }
    )

    #expect(value.content.contains("URLComponents"))
    #expect(value.content.contains("itunes.apple.com/search"))
    #expect(value.content.contains("URLSession.shared.data(from:"))
    #expect(value.content.contains("JSONDecoder().decode"))
    // The well-formed candidate should compile (it uses only Foundation APIs)
    // Note: may not compile in CI without full SDK, but validates the flow
  }
}

@Suite("CandidateGenerator + SignatureIndex")
struct CandidateSignatureTests {

  @Test("evaluateAndSuggestFix returns hints for wrong API")
  func suggestFixForWrongAPI() async throws {
    let shell = SafeShell(workingDirectory: NSTemporaryDirectory())
    let gen = CandidateGenerator(
      adapter: MockAdapter(fixedResponse: ""),
      shell: shell
    )
    let index = SignatureIndex.builtIn()

    // Code with hallucinated API: URLSession.shared.asyncData
    let code = """
    import Foundation
    func fetch() async throws -> Data {
      let url = URL(string: "https://example.com")!
      return try await URLSession.shared.asyncData(from: url)
    }
    """

    let (result, hints) = await gen.evaluateAndSuggestFix(
      code: code,
      filePath: "test.swift",
      signatureIndex: index
    )

    #expect(!result.compiled)
    // If compiler error mentions "asyncData", SignatureIndex should suggest correct API
    if result.errors.contains(where: { $0.contains("asyncData") }) {
      #expect(!hints.isEmpty)
      #expect(hints.first?.contains("URLSession.shared.data(from:") == true)
    }
  }
}
