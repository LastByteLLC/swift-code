import Foundation
import Testing

@testable import Core

// MARK: - compact tool

@Suite("compact tool")
struct CompactToolTests {
  @Test func compactToolDefinitionExistsInDefaultConfig() {
    let defaultTools = Agent.toolDefinitions
    let compactTool = defaultTools.first { $0.name == "compact" }
    #expect(compactTool != nil)
    #expect(defaultTools.count == 12)
  }

  @Test func compactToolAbsentFromSubagentConfig() {
    let subagentTools = Agent.toolDefinitions.filter {
      !Set(["agent", "todo", "compact", "task_create", "task_update"]).contains($0.name)
    }
    let compactTool = subagentTools.first { $0.name == "compact" }
    #expect(compactTool == nil)
    #expect(subagentTools.count == 7)
  }

  @Test func executeCompactReturnsSuccessMarker() async {
    let (agent, _) = makeAgent()
    let result = await agent.executeTool(
      name: "compact",
      input: .object([:])
    )
    #expect(result == .success("Compressing..."))
  }

}

// MARK: - Helpers

private let longContent = String(repeating: "x", count: 200)

private func makeTempDir() throws -> URL {
  let dir = FileManager.default.temporaryDirectory
    .appendingPathComponent("compact-test-\(UUID().uuidString)")
  try FileManager.default.createDirectory(
    at: dir, withIntermediateDirectories: true
  )
  return dir
}

private func bashToolUseResponse(
  id: String,
  command: String = "echo test"
) -> APIResponse {
  makeResponse(
    content: [
      .toolUse(
        id: id,
        name: "bash",
        input: .object(["command": .string(command)])
      )
    ],
    stopReason: .toolUse
  )
}

// MARK: - compact in agent loop

@Suite("compact in agent loop")
struct CompactInAgentLoopTests {
  @Test func microCompactRunsBeforeEachAPICall() async throws {
    let mock = MockAPIClient()

    // 5 bash tool uses that produce long output, then end_turn
    let longEcho = "echo '\(longContent)'"
    for i in 0..<5 {
      mock.responses.append(
        bashToolUseResponse(id: "t\(i)", command: longEcho)
      )
    }
    mock.responses.append(makeResponse(content: [.text("done")]))

    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let (agent, _) = makeAgent(mock: mock, workingDirectory: dir.path)
    _ = try await agent.run(query: "test")

    // After 4+ tool results, microCompact should replace old ones.
    // The 6th request (index 5) should have oldest tool results compacted.
    let lastRequest = mock.requests[5]
    let allContent = lastRequest.messages.flatMap(\.content)
    let compactedResults = allContent.filter {
      if case .toolResult(_, let content, _) = $0 {
        return content.contains("[Previous: used bash]")
      }
      return false
    }
    #expect(compactedResults.count >= 1)

    // The most recent 3 tool results should still have original content
    let recentResults = allContent.compactMap { block -> String? in
      if case .toolResult(_, let content, _) = block,
        !content.contains("[Previous:") {
        return content
      }
      return nil
    }
    #expect(recentResults.count == 3)
  }

  @Test func autoCompactTriggersWhenThresholdExceeded() async throws {
    let mock = MockAPIClient()

    // Summarization response (from autoCompact)
    mock.responses.append(
      makeResponse(content: [.text("Summary of conversation.")])
    )
    // Final end_turn after compaction
    mock.responses.append(
      makeResponse(content: [.text("ok")])
    )

    // Use very low threshold so auto_compact triggers immediately
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let (agent, _) = makeAgent(
      mock: mock, workingDirectory: dir.path, tokenThreshold: 10
    )
    let result = try await agent.run(query: "test query")
    #expect(result == "ok")

    // First request is the summarization (autoCompact), second is normal
    #expect(mock.requests.count == 2)

    // Summarization request should have no tools and maxTokens=2000
    let summarizationRequest = mock.requests[0]
    #expect(summarizationRequest.tools == nil)
    #expect(summarizationRequest.maxTokens == 2000)

    // The second request should have compressed messages
    let normalRequest = mock.requests[1]
    let firstMsgContent = normalRequest.messages[0].content.textContent
    #expect(firstMsgContent.contains("[Conversation compressed."))
  }

  @Test func compactToolTriggersManualCompaction() async throws {
    let mock = MockAPIClient()

    // 1. Agent calls compact tool
    mock.responses.append(
      makeResponse(
        content: [
          .toolUse(id: "c1", name: "compact", input: .object([:]))
        ],
        stopReason: .toolUse
      )
    )
    // 2. Summarization response (from manual compact via autoCompact)
    mock.responses.append(
      makeResponse(content: [.text("Compressed summary.")])
    )
    // 3. Final end_turn
    mock.responses.append(
      makeResponse(content: [.text("continuing")])
    )

    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let (agent, _) = makeAgent(mock: mock, workingDirectory: dir.path)
    let result = try await agent.run(query: "do something")
    #expect(result == "continuing")

    // Verify summarization request is at index 1
    #expect(mock.requests.count == 3)
    let summarizationRequest = mock.requests[1]
    #expect(summarizationRequest.tools == nil)
    #expect(summarizationRequest.maxTokens == 2000)
  }

  @Test func compactToolWithFocusParam() async throws {
    let mock = MockAPIClient()

    // 1. Agent calls compact with focus
    mock.responses.append(
      makeResponse(
        content: [
          .toolUse(
            id: "c1",
            name: "compact",
            input: .object(["focus": .string("file paths edited")])
          )
        ],
        stopReason: .toolUse
      )
    )
    // 2. Summarization response
    mock.responses.append(
      makeResponse(content: [.text("Summary with focus.")])
    )
    // 3. Final end_turn
    mock.responses.append(
      makeResponse(content: [.text("done")])
    )

    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let (agent, _) = makeAgent(mock: mock, workingDirectory: dir.path)
    _ = try await agent.run(query: "test")

    // Verify focus text appears in summarization prompt
    let summarizationRequest = mock.requests[1]
    let promptContent = summarizationRequest.messages[0].content.textContent
    #expect(promptContent.contains("Focus on: file paths edited."))
  }

  @Test func shortConversationPassesThroughUnchanged() async throws {
    let mock = MockAPIClient()

    // 3 tool uses (at threshold, not over) then end_turn
    for i in 0..<3 {
      mock.responses.append(bashToolUseResponse(id: "t\(i)"))
    }
    mock.responses.append(makeResponse(content: [.text("done")]))

    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let (agent, _) = makeAgent(mock: mock, workingDirectory: dir.path)
    _ = try await agent.run(query: "test")

    // With only 3 tool results (<= keepRecent), no compaction should occur
    let lastRequest = mock.requests[3]
    let allContent = lastRequest.messages.flatMap(\.content)
    let compactedResults = allContent.filter {
      if case .toolResult(_, let content, _) = $0 {
        return content.contains("[Previous:")
      }
      return false
    }
    #expect(compactedResults.isEmpty)
  }
}
