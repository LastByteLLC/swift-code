// ReplayAdapterTests.swift — Tests for HAR-based record/replay adapter

import Foundation
import Testing
@testable import JuncoKit

/// Resolve a fixture path relative to this test file.
private func fixturePath(_ name: String) -> String {
  let thisFile = #filePath
  let dir = (thisFile as NSString).deletingLastPathComponent
  return (dir as NSString).appendingPathComponent("Fixtures/\(name)")
}

@Suite("ReplayAdapter")
struct ReplayAdapterTests {

  // MARK: - HAR File Format

  @Test("HARFile round-trips through Codable")
  func harFileCodable() throws {
    let entry = HAREntry(
      request: .init(prompt: "hello", system: "be brief", typeName: "String"),
      response: .init(json: "world", timeMs: 100)
    )
    var har = HARFile()
    har.log.entries.append(entry)

    let data = try JSONEncoder().encode(har)
    let decoded = try JSONDecoder().decode(HARFile.self, from: data)
    #expect(decoded.log.version == "1.2")
    #expect(decoded.log.creator.name == "junco-replay")
    #expect(decoded.log.entries.count == 1)
    #expect(decoded.log.entries[0].request.prompt == "hello")
    #expect(decoded.log.entries[0].response.json == "world")
  }

  @Test("HAREntry records options")
  func harEntryOptions() throws {
    let entry = HAREntry(
      request: .init(
        prompt: "test",
        system: nil,
        typeName: "CreateParams",
        options: .init(maximumResponseTokens: 2000, temperature: 0.7)
      ),
      response: .init(json: "{}", timeMs: 50)
    )
    let data = try JSONEncoder().encode(entry)
    let decoded = try JSONDecoder().decode(HAREntry.self, from: data)
    #expect(decoded.request.options?.maximumResponseTokens == 2000)
    #expect(decoded.request.options?.temperature == 0.7)
  }

  // MARK: - Record Mode

  @Test("Record mode captures generate calls and saves HAR")
  func recordAndSave() async throws {
    let mock = MockAdapter(fixedResponse: "recorded output")
    let tempPath = NSTemporaryDirectory() + "test_record_\(UUID().uuidString).har.json"
    defer { try? FileManager.default.removeItem(atPath: tempPath) }

    let replay = try ReplayAdapter(mode: .record(adapter: mock, outputPath: tempPath))

    let result = try await replay.generate(prompt: "hello", system: "be brief")
    #expect(result == "recorded output")

    let count = await replay.entryCount
    #expect(count == 1)

    try await replay.save()
    #expect(FileManager.default.fileExists(atPath: tempPath))

    // Verify saved HAR is valid
    let data = try Data(contentsOf: URL(fileURLWithPath: tempPath))
    let har = try JSONDecoder().decode(HARFile.self, from: data)
    #expect(har.log.entries.count == 1)
    #expect(har.log.entries[0].request.prompt == "hello")
    #expect(har.log.entries[0].response.json == "recorded output")
  }

  @Test("Record mode captures multiple calls in sequence")
  func recordMultipleCalls() async throws {
    let mock = MockAdapter(responses: ["first", "second", "third"])
    let tempPath = NSTemporaryDirectory() + "test_multi_\(UUID().uuidString).har.json"
    defer { try? FileManager.default.removeItem(atPath: tempPath) }

    let replay = try ReplayAdapter(mode: .record(adapter: mock, outputPath: tempPath))

    _ = try await replay.generate(prompt: "p1", system: nil)
    _ = try await replay.generate(prompt: "p2", system: "s2")
    _ = try await replay.generate(prompt: "p3", system: nil)

    try await replay.save()

    let data = try Data(contentsOf: URL(fileURLWithPath: tempPath))
    let har = try JSONDecoder().decode(HARFile.self, from: data)
    #expect(har.log.entries.count == 3)
    #expect(har.log.entries[0].response.json == "first")
    #expect(har.log.entries[1].response.json == "second")
    #expect(har.log.entries[2].response.json == "third")
  }

  // MARK: - Replay Mode

  @Test("Replay mode returns recorded responses in order")
  func replayInOrder() async throws {
    // First record
    let mock = MockAdapter(responses: ["alpha", "beta"])
    let tempPath = NSTemporaryDirectory() + "test_replay_\(UUID().uuidString).har.json"
    defer { try? FileManager.default.removeItem(atPath: tempPath) }

    let recorder = try ReplayAdapter(mode: .record(adapter: mock, outputPath: tempPath))
    _ = try await recorder.generate(prompt: "q1", system: nil)
    _ = try await recorder.generate(prompt: "q2", system: nil)
    try await recorder.save()

    // Then replay
    let replayer = try ReplayAdapter(mode: .replay(inputPath: tempPath))
    let r1 = try await replayer.generate(prompt: "anything", system: nil)
    let r2 = try await replayer.generate(prompt: "ignored", system: nil)
    #expect(r1 == "alpha")
    #expect(r2 == "beta")
  }

  @Test("Replay mode throws when entries exhausted")
  func replayExhausted() async throws {
    let mock = MockAdapter(fixedResponse: "only one")
    let tempPath = NSTemporaryDirectory() + "test_exhaust_\(UUID().uuidString).har.json"
    defer { try? FileManager.default.removeItem(atPath: tempPath) }

    let recorder = try ReplayAdapter(mode: .record(adapter: mock, outputPath: tempPath))
    _ = try await recorder.generate(prompt: "q", system: nil)
    try await recorder.save()

    let replayer = try ReplayAdapter(mode: .replay(inputPath: tempPath))
    _ = try await replayer.generate(prompt: "q", system: nil)

    await #expect(throws: LLMError.self) {
      _ = try await replayer.generate(prompt: "q2", system: nil)
    }
  }

  @Test("Replay reset restarts from beginning")
  func replayReset() async throws {
    let mock = MockAdapter(fixedResponse: "same")
    let tempPath = NSTemporaryDirectory() + "test_reset_\(UUID().uuidString).har.json"
    defer { try? FileManager.default.removeItem(atPath: tempPath) }

    let recorder = try ReplayAdapter(mode: .record(adapter: mock, outputPath: tempPath))
    _ = try await recorder.generate(prompt: "q", system: nil)
    try await recorder.save()

    let replayer = try ReplayAdapter(mode: .replay(inputPath: tempPath))
    _ = try await replayer.generate(prompt: "q", system: nil)
    let remaining = await replayer.remainingEntries
    #expect(remaining == 0)

    await replayer.reset()
    let afterReset = await replayer.remainingEntries
    #expect(afterReset == 1)

    let result = try await replayer.generate(prompt: "q", system: nil)
    #expect(result == "same")
  }

  // MARK: - Structured Replay

  @Test("Structured generation records and replays Codable types")
  func structuredRoundTrip() async throws {
    let intentJSON = """
    {"domain":"swift","taskType":"fix","complexity":"simple","mode":"build","targets":["file.swift"]}
    """
    let mock = MockAdapter(fixedResponse: intentJSON)
    let tempPath = NSTemporaryDirectory() + "test_structured_\(UUID().uuidString).har.json"
    defer { try? FileManager.default.removeItem(atPath: tempPath) }

    // Record
    let recorder = try ReplayAdapter(mode: .record(adapter: mock, outputPath: tempPath))
    let recorded = try await recorder.generateStructured(
      prompt: "classify: fix login bug",
      system: "classify intent",
      as: AgentIntent.self
    )
    #expect(recorded.domain == "swift")
    try await recorder.save()

    // Replay
    let replayer = try ReplayAdapter(mode: .replay(inputPath: tempPath))
    let replayed = try await replayer.generateStructured(
      prompt: "ignored prompt",
      system: "ignored system",
      as: AgentIntent.self
    )
    #expect(replayed.domain == "swift")
    #expect(replayed.taskType == "fix")
    #expect(replayed.targets == ["file.swift"])
  }

  // MARK: - Fixture File Loading

  @Test("Loads podcast search HAR fixture")
  func loadPodcastFixture() async throws {
    let path = fixturePath("podcast_search_good.har.json")
    let replayer = try ReplayAdapter(mode: .replay(inputPath: path))

    let result = try await replayer.generateStructured(
      prompt: "ignored",
      system: "ignored",
      as: CreateParams.self
    )
    #expect(result.filePath == "PodcastSearch.swift")
    #expect(result.content.contains("searchPodcasts"))
    #expect(result.content.contains("itunes.apple.com/search"))
    #expect(result.content.contains("URLSession.shared.data(from:"))
  }

  @Test("Podcast lookup pipeline replays full intent-plan-execute-reflect cycle")
  func podcastLookupPipeline() async throws {
    let path = fixturePath("podcast_lookup_episodes.har.json")
    let replayer = try ReplayAdapter(mode: .replay(inputPath: path))

    // Step 1: Intent classification
    let intent = try await replayer.generateStructured(
      prompt: "ignored", system: nil, as: AgentIntent.self
    )
    #expect(intent.domain == "swift")
    #expect(intent.taskType == "add")
    #expect(intent.agentMode == .build)

    // Step 2: Planning
    let plan = try await replayer.generateStructured(
      prompt: "ignored", system: nil, as: AgentPlan.self
    )
    #expect(plan.steps.count == 1)
    #expect(plan.steps[0].toolName == .create)
    #expect(plan.steps[0].target == "PodcastEpisodes.swift")

    // Step 3: Code generation
    let code = try await replayer.generateStructured(
      prompt: "ignored", system: nil, as: CreateParams.self
    )
    #expect(code.content.contains("itunes.apple.com/lookup"))
    #expect(code.content.contains("podcastEpisode"))
    #expect(code.content.contains("fetchEpisodes"))

    // Step 4: Reflection
    let reflection = try await replayer.generateStructured(
      prompt: "ignored", system: nil, as: AgentReflection.self
    )
    #expect(reflection.succeeded)

    // All entries consumed
    let remaining = await replayer.remainingEntries
    #expect(remaining == 0)
  }
}
