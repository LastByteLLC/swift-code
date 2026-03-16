import Foundation
import Testing

@testable import Core

@Suite("load_skill tool")
struct AgentLoadSkillTests {
  @Test func missingNameReturnsError() async {
    let (agent, _) = makeAgent()
    let result = await agent.executeTool(
      name: "load_skill",
      input: .object([:])
    )
    #expect(result == .failure(.missingParameter("name")))
  }

  @Test func validSkillReturnsContent() async throws {
    let tempDir = NSTemporaryDirectory() + "skill-test-\(UUID().uuidString)"
    let skillDir = "\(tempDir)/greeting"

    try FileManager.default.createDirectory(
      atPath: skillDir,
      withIntermediateDirectories: true
    )

    try """
    ---
    name: greeting
    description: Say hello
    ---
    Hello, world!
    """.write(toFile: "\(skillDir)/SKILL.md", atomically: true, encoding: .utf8)

    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let (agent, _) = makeAgent(skillsDirectory: tempDir)
    let result = await agent.executeTool(
      name: "load_skill",
      input: .object(["name": "greeting"])
    )

    #expect(result == .success("<skill name=\"greeting\">\nHello, world!\n</skill>"))
  }

  @Test func unknownSkillListsAvailable() async throws {
    let tempDir = NSTemporaryDirectory() + "skill-test-\(UUID().uuidString)"
    let skillDir = "\(tempDir)/greeting"

    try FileManager.default.createDirectory(
      atPath: skillDir,
      withIntermediateDirectories: true
    )

    try """
    ---
    name: greeting
    description: Say hello
    ---
    Hello!
    """.write(toFile: "\(skillDir)/SKILL.md", atomically: true, encoding: .utf8)

    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let (agent, _) = makeAgent(skillsDirectory: tempDir)
    let result = await agent.executeTool(
      name: "load_skill",
      input: .object(["name": "nonexistent"])
    )
    let output = try result.get()

    #expect(output.contains("Unknown skill"))
    #expect(output.contains("greeting"))
  }

  @Test func loadSkillDispatchInAgentLoop() async throws {
    let tempDir = NSTemporaryDirectory() + "skill-test-\(UUID().uuidString)"
    let skillDir = "\(tempDir)/coding"

    try FileManager.default.createDirectory(
      atPath: skillDir,
      withIntermediateDirectories: true
    )

    try """
    ---
    name: coding
    description: Coding best practices
    ---
    Write clean code.
    """.write(toFile: "\(skillDir)/SKILL.md", atomically: true, encoding: .utf8)

    let mock = MockAPIClient()
    mock.responses = [
      makeResponse(
        content: [
          .toolUse(
            id: "t1",
            name: "load_skill",
            input: .object(["name": "coding"])
          )
        ],
        stopReason: .toolUse
      ),
      makeResponse(content: [.text("got it")])
    ]
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let (agent, _) = makeAgent(mock: mock, skillsDirectory: tempDir)

    let result = try await agent.run(query: "load coding skill")

    #expect(result == "got it")
    #expect(mock.requests.count == 2)

    let toolResultMessage = try #require(mock.requests[1].messages.last)
    let hasSkillContent = toolResultMessage.content.contains {
      isToolResult($0) { _, content, isError in
        content.contains("Write clean code.") && !isError
      }
    }
    #expect(hasSkillContent)
  }
}

@Suite("buildSystemPrompt with skills")
struct BuildSystemPromptSkillTests {
  @Test func withoutSkillDescriptions() {
    let prompt = Agent.buildSystemPrompt(cwd: "/tmp")
    #expect(!prompt.contains("load_skill"))
    #expect(!prompt.contains("Skills available"))
  }

  @Test func withSkillDescriptions() {
    let descriptions = "  - pdf: Process PDF files\n  - code-review: Review code"
    let prompt = Agent.buildSystemPrompt(cwd: "/tmp", skillDescriptions: descriptions)
    #expect(prompt.contains("load_skill"))
    #expect(prompt.contains("Skills available:"))
    #expect(prompt.contains("pdf: Process PDF files"))
    #expect(prompt.contains("code-review: Review code"))
  }

  @Test func skillDescriptionsInAPIRequest() async throws {
    let tempDir = NSTemporaryDirectory() + "skill-test-\(UUID().uuidString)"
    let skillDir = "\(tempDir)/testing"

    try FileManager.default.createDirectory(
      atPath: skillDir,
      withIntermediateDirectories: true
    )

    try """
    ---
    name: testing
    description: Testing best practices
    ---
    Always write tests.
    """.write(toFile: "\(skillDir)/SKILL.md", atomically: true, encoding: .utf8)

    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let mock = MockAPIClient()
    mock.responses = [
      makeResponse(content: [.text("hello")])
    ]
    let agent = Agent(
      apiClient: mock,
      model: "test-model",
      skillsDirectory: tempDir
    )

    _ = try await agent.run(query: "hi")

    let systemPrompt = mock.requests[0].system
    #expect(systemPrompt?.contains("Skills available:") == true)
    #expect(systemPrompt?.contains("testing: Testing best practices") == true)
    #expect(systemPrompt?.contains("load_skill") == true)
  }

  @Test func noSkillsNoSkillSection() async throws {
    let tempDir = NSTemporaryDirectory() + "skill-test-\(UUID().uuidString)"
    defer { try? FileManager.default.removeItem(atPath: tempDir) }

    let mock = MockAPIClient()
    mock.responses = [
      makeResponse(content: [.text("hello")])
    ]
    let agent = Agent(
      apiClient: mock,
      model: "test-model",
      skillsDirectory: tempDir
    )

    _ = try await agent.run(query: "hi")

    let systemPrompt = mock.requests[0].system
    #expect(systemPrompt?.contains("Skills available:") != true)
  }
}
