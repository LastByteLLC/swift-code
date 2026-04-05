// EndToEndCandidateTests.swift — E2E tests with arbitrary APIs
//
// Tests the full CandidateGenerator + SignatureIndex + ReplayAdapter pipeline
// using the GitHub REST API, Weather API, and other real-world endpoints.
// Validates that swiftc catches hallucinated APIs and compile-select picks correctly.

import Foundation
import Testing
@testable import JuncoKit

@Suite("E2E CandidateGenerator")
struct EndToEndCandidateTests {

  // MARK: - GitHub API: Candidate Evaluation

  @Test("Valid GitHub API client compiles")
  func validGitHubClient() async {
    let shell = SafeShell(workingDirectory: NSTemporaryDirectory())
    let gen = CandidateGenerator(adapter: MockAdapter(fixedResponse: ""), shell: shell)

    let code = """
    import Foundation

    struct GitHubRepo: Codable {
      let name: String
      let fullName: String
      let description: String?
      let stargazersCount: Int
      let language: String?

      enum CodingKeys: String, CodingKey {
        case name
        case fullName = "full_name"
        case description
        case stargazersCount = "stargazers_count"
        case language
      }
    }

    struct GitHubSearchResult: Codable {
      let totalCount: Int
      let items: [GitHubRepo]

      enum CodingKeys: String, CodingKey {
        case totalCount = "total_count"
        case items
      }
    }

    func searchRepos(query: String, perPage: Int = 10) async throws -> [GitHubRepo] {
      var components = URLComponents(string: "https://api.github.com/search/repositories")!
      components.queryItems = [
        URLQueryItem(name: "q", value: query),
        URLQueryItem(name: "per_page", value: String(perPage)),
        URLQueryItem(name: "sort", value: "stars"),
      ]
      var request = URLRequest(url: components.url!)
      request.setValue("application/vnd.github.v3+json", forHTTPHeaderField: "Accept")
      let (data, _) = try await URLSession.shared.data(for: request)
      let result = try JSONDecoder().decode(GitHubSearchResult.self, from: data)
      return result.items
    }
    """

    let result = await gen.evaluate(code: code, filePath: "GitHubClient.swift")
    #expect(result.compiled, "Valid GitHub API code should compile. Errors: \(result.errors)")
    #expect(result.errorCount == 0)
  }

  @Test("GitHub client with hallucinated API fails compilation")
  func hallucinatedGitHubClient() async {
    let shell = SafeShell(workingDirectory: NSTemporaryDirectory())
    let gen = CandidateGenerator(adapter: MockAdapter(fixedResponse: ""), shell: shell)

    // Common model mistakes: .fetchJSON, .asyncData, wrong URLSession methods
    let code = """
    import Foundation

    struct GitHubRepo: Codable {
      let name: String
      let stars: Int
    }

    func searchRepos(query: String) async throws -> [GitHubRepo] {
      let url = URL(string: "https://api.github.com/search/repositories?q=\\(query)")!
      let data = try await URLSession.shared.fetchJSON(from: url)
      let repos = try JSONDecoder().fromJSON([GitHubRepo].self, data: data)
      return repos
    }
    """

    let result = await gen.evaluate(code: code, filePath: "GitHubClient.swift")
    #expect(!result.compiled, "Hallucinated APIs should fail compilation")
    #expect(result.errorCount > 0)
    #expect(result.errors.contains(where: { $0.contains("error:") }))
  }

  // MARK: - GitHub API: Multi-Sample Compile-Select via HAR

  @Test("Multi-sample selects compiling GitHub client over hallucinated one")
  func gitHubMultiSample() async throws {
    // Build a HAR with 3 candidates: bad, bad, good
    let bad1 = """
    {"filePath":"GitHubClient.swift","content":"import Foundation\\nstruct Repo: Codable { let name: String }\\nfunc search(_ q: String) async throws -> [Repo] {\\n  let url = URL(string: \\"https://api.github.com/search/repositories?q=\\\\(q)\\")!\\n  let data = try await URLSession.shared.fetchJSON(from: url)\\n  return try JSONDecoder().fromJSON([Repo].self, data: data)\\n}"}
    """
    let bad2 = """
    {"filePath":"GitHubClient.swift","content":"import Foundation\\nstruct Repo: Codable { let name: String }\\nfunc search(_ q: String) async throws -> [Repo] {\\n  let url = URL(string: \\"https://api.github.com/search/repositories?q=\\\\(q)\\")!\\n  let response = try await URLSession.shared.asyncData(url: url)\\n  return try JSONDecoder().decode([Repo].self, from: response.data)\\n}"}
    """
    let good = """
    {"filePath":"GitHubClient.swift","content":"import Foundation\\nstruct Repo: Codable { let name: String }\\nfunc search(_ q: String) async throws -> [Repo] {\\n  let url = URL(string: \\"https://api.github.com/search/repositories?q=\\\\(q)\\")!\\n  let (data, _) = try await URLSession.shared.data(from: url)\\n  return try JSONDecoder().decode([Repo].self, from: data)\\n}"}
    """

    let mock = MockAdapter(responses: [bad1, bad2, good])
    let tempHAR = NSTemporaryDirectory() + "github_e2e_\(UUID().uuidString).har.json"
    defer { try? FileManager.default.removeItem(atPath: tempHAR) }

    // Record
    let recorder = try ReplayAdapter(mode: .record(adapter: mock, outputPath: tempHAR))
    for _ in 0..<3 {
      _ = try await recorder.generateStructured(
        prompt: "Create a GitHub repo search client",
        system: "Generate Swift code.",
        as: CreateParams.self
      )
    }
    try await recorder.save()

    // Replay through CandidateGenerator
    let replayer = try ReplayAdapter(mode: .replay(inputPath: tempHAR))
    let shell = SafeShell(workingDirectory: NSTemporaryDirectory())
    let gen = CandidateGenerator(adapter: replayer, shell: shell, candidateCount: 3)

    let (value, result) = try await gen.generate(
      prompt: "Create a GitHub repo search client",
      system: "Generate Swift code.",
      as: CreateParams.self,
      filePath: "GitHubClient.swift",
      extract: { $0.content }
    )

    // The generator should have selected the 3rd candidate (the only one that compiles)
    #expect(result.compiled, "Should select the compiling candidate. Errors: \(result.errors)")
    #expect(value.content.contains("URLSession.shared.data(from:"))
    #expect(!value.content.contains("fetchJSON"))
    #expect(!value.content.contains("asyncData"))
  }

  // MARK: - Weather API: Candidate Evaluation

  @Test("Valid weather API client compiles")
  func validWeatherClient() async {
    let shell = SafeShell(workingDirectory: NSTemporaryDirectory())
    let gen = CandidateGenerator(adapter: MockAdapter(fixedResponse: ""), shell: shell)

    let code = """
    import Foundation

    struct WeatherResponse: Codable {
      let main: MainWeather
      let name: String
    }

    struct MainWeather: Codable {
      let temp: Double
      let humidity: Int
    }

    func fetchWeather(city: String, apiKey: String) async throws -> WeatherResponse {
      var components = URLComponents(string: "https://api.openweathermap.org/data/2.5/weather")!
      components.queryItems = [
        URLQueryItem(name: "q", value: city),
        URLQueryItem(name: "appid", value: apiKey),
        URLQueryItem(name: "units", value: "metric"),
      ]
      let (data, _) = try await URLSession.shared.data(from: components.url!)
      return try JSONDecoder().decode(WeatherResponse.self, from: data)
    }
    """

    let result = await gen.evaluate(code: code, filePath: "WeatherClient.swift")
    #expect(result.compiled, "Valid weather client should compile. Errors: \(result.errors)")
  }

  @Test("Weather client with wrong API methods fails")
  func hallucinatedWeatherClient() async {
    let shell = SafeShell(workingDirectory: NSTemporaryDirectory())
    let gen = CandidateGenerator(adapter: MockAdapter(fixedResponse: ""), shell: shell)

    let code = """
    import Foundation

    struct WeatherResponse: Codable {
      let temp: Double
      let city: String
    }

    func fetchWeather(city: String) async throws -> WeatherResponse {
      let url = URL.create("https://api.openweathermap.org/data/2.5/weather?q=\\(city)")
      let json = try await url.downloadJSON()
      return try WeatherResponse.fromJSON(json)
    }
    """

    let result = await gen.evaluate(code: code, filePath: "WeatherClient.swift")
    #expect(!result.compiled)
    #expect(result.errorCount >= 1)
  }

  // MARK: - SignatureIndex Integration: Real Compiler Errors

  @Test("SignatureIndex provides fix hints for GitHub API hallucinations")
  func signatureHintsForGitHub() async {
    let shell = SafeShell(workingDirectory: NSTemporaryDirectory())
    let gen = CandidateGenerator(adapter: MockAdapter(fixedResponse: ""), shell: shell)
    let index = SignatureIndex.builtIn()

    let code = """
    import Foundation
    func fetch() async throws -> Data {
      let url = URL(string: "https://api.github.com/repos")!
      return try await URLSession.shared.fetchData(from: url)
    }
    """

    let (result, hints) = await gen.evaluateAndSuggestFix(
      code: code, filePath: "test.swift", signatureIndex: index
    )

    #expect(!result.compiled)
    // The compiler error should mention "fetchData" → SignatureIndex maps to data(from:)
    if result.errors.contains(where: { $0.contains("fetchData") }) {
      #expect(!hints.isEmpty, "SignatureIndex should provide a hint for 'fetchData'")
      #expect(hints.first?.contains("data(from:") == true)
    }
  }

  @Test("SignatureIndex provides fix hints for URL hallucinations")
  func signatureHintsForURL() async {
    let shell = SafeShell(workingDirectory: NSTemporaryDirectory())
    let gen = CandidateGenerator(adapter: MockAdapter(fixedResponse: ""), shell: shell)
    let index = SignatureIndex.builtIn()

    let code = """
    import Foundation
    let url = URL.fromString("https://example.com")
    """

    let (result, hints) = await gen.evaluateAndSuggestFix(
      code: code, filePath: "test.swift", signatureIndex: index
    )

    #expect(!result.compiled)
    if result.errors.contains(where: { $0.contains("fromString") }) {
      #expect(!hints.isEmpty, "SignatureIndex should provide a hint for 'fromString'")
      #expect(hints.first?.contains("URL(string:") == true)
    }
  }

  // MARK: - Record → Replay Round-Trip with Real Evaluation

  @Test("Full record-replay-evaluate cycle with weather API")
  func fullRecordReplayEvaluate() async throws {
    let goodWeatherJSON = """
    {"filePath":"Weather.swift","content":"import Foundation\\nstruct Weather: Codable { let temp: Double }\\nfunc fetch(city: String) async throws -> Weather {\\n  var c = URLComponents(string: \\"https://api.openweathermap.org/data/2.5/weather\\")!\\n  c.queryItems = [URLQueryItem(name: \\"q\\", value: city)]\\n  let (data, _) = try await URLSession.shared.data(from: c.url!)\\n  return try JSONDecoder().decode(Weather.self, from: data)\\n}"}
    """
    let mock = MockAdapter(fixedResponse: goodWeatherJSON)
    let harPath = NSTemporaryDirectory() + "weather_e2e_\(UUID().uuidString).har.json"
    defer { try? FileManager.default.removeItem(atPath: harPath) }

    // Step 1: Record
    let recorder = try ReplayAdapter(mode: .record(adapter: mock, outputPath: harPath))
    let recorded = try await recorder.generateStructured(
      prompt: "Create weather fetch function",
      system: "Generate Swift code.",
      as: CreateParams.self
    )
    try await recorder.save()

    // Step 2: Replay
    let replayer = try ReplayAdapter(mode: .replay(inputPath: harPath))
    let replayed = try await replayer.generateStructured(
      prompt: "ignored", system: "ignored", as: CreateParams.self
    )
    #expect(replayed.content == recorded.content)

    // Step 3: Evaluate the replayed code with real swiftc
    let shell = SafeShell(workingDirectory: NSTemporaryDirectory())
    let gen = CandidateGenerator(adapter: MockAdapter(fixedResponse: ""), shell: shell)
    let result = await gen.evaluate(code: replayed.content, filePath: "Weather.swift")

    #expect(result.compiled, "Replayed weather code should compile. Errors: \(result.errors)")
    #expect(result.errorCount == 0)
  }

  // MARK: - FileManager API: Common Hallucination

  @Test("FileManager hallucination detected and hinted")
  func fileManagerHallucination() async {
    let shell = SafeShell(workingDirectory: NSTemporaryDirectory())
    let gen = CandidateGenerator(adapter: MockAdapter(fixedResponse: ""), shell: shell)
    let index = SignatureIndex.builtIn()

    let code = """
    import Foundation
    func listFiles(in dir: String) throws -> [String] {
      return try FileManager.default.listFiles(at: dir)
    }
    """

    let (result, hints) = await gen.evaluateAndSuggestFix(
      code: code, filePath: "test.swift", signatureIndex: index
    )

    #expect(!result.compiled)
    // "listFiles" is a common mistake for contentsOfDirectory
    if result.errors.contains(where: { $0.contains("listFiles") }) {
      #expect(!hints.isEmpty)
      #expect(hints.first?.contains("contentsOfDirectory") == true)
    }
  }
}
