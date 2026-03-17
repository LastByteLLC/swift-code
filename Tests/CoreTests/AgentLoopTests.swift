import Foundation
import Testing

@testable import Core

// MARK: - Agent loop

@Suite("Agent loop")
struct AgentLoopTests {
  @Test func returnsTextOnEndTurn() async throws {
    let mock = MockAPIClient()
    mock.responses = [
      makeResponse(content: [.text("the answer")])
    ]
    let (agent, _) = makeAgent(mock: mock)

    let result = try await agent.run(query: "question")

    #expect(result == "the answer")
    #expect(mock.requests.count == 1)
    #expect(mock.requests[0].model == "test-model")
  }

  @Test func executesToolThenReturnsText() async throws {
    let mock = MockAPIClient()
    mock.responses = [
      // First response: ask to run a tool
      makeResponse(
        content: [
          .text("Let me check."),
          .toolUse(id: "t1", name: "bash", input: .object(["command": "echo hi"]))
        ],
        stopReason: .toolUse
      ),
      // Second response: final answer after seeing tool result
      makeResponse(content: [.text("done")])
    ]
    let (agent, _) = makeAgent(mock: mock)

    let result = try await agent.run(query: "do something")

    #expect(result == "done")
    #expect(mock.requests.count == 2)

    // Second request should contain the tool result
    let secondMessages = mock.requests[1].messages
    let lastMessage = try #require(secondMessages.last)
    #expect(lastMessage.role == .user)
    #expect(
      lastMessage.content.contains(where: {
        if case .toolResult = $0 { true } else { false }
      })
    )
  }
}

// MARK: - Background notification drain

@Suite("Background notification drain")
struct BackgroundNotificationDrainTests {
  @Test func emptyNotificationsReturnsUnchanged() async {
    let (agent, _) = makeAgent()
    let messages: [Message] = [.user("hello"), .assistant("hi")]

    let result = await agent.drainBackgroundNotifications(messages)

    #expect(result == messages)
  }

  @Test func notificationsAppendUserAssistantPair() async throws {
    let (agent, _) = makeAgent()

    // Start a background job and wait for it to complete
    let confirmation = await agent.backgroundManager.run(command: "echo done")
    let jobId = try extractJobId(confirmation)
    await agent.backgroundManager.awaitCompletion(jobId: jobId)

    let messages: [Message] = [.assistant("thinking")]

    let result = await agent.drainBackgroundNotifications(messages)

    // Should have original + user (background-results) + assistant (noted)
    #expect(result.count == 3)
    #expect(result[0] == messages[0])
    #expect(result[1].role == .user)
    #expect(result[2].role == .assistant)
    #expect(result[2] == .assistant("Noted background results."))
  }

  @Test func notificationFormatMatchesPattern() async throws {
    let (agent, _) = makeAgent()

    let confirmation = await agent.backgroundManager.run(command: "echo test-output")
    let jobId = try extractJobId(confirmation)
    await agent.backgroundManager.awaitCompletion(jobId: jobId)

    let messages: [Message] = [.assistant("ok")]
    let result = await agent.drainBackgroundNotifications(messages)

    try #require(result.count >= 2, "Expected at least 2 messages, got \(result.count)")

    let userMessage = result[1]
    let text = userMessage.content.textContent
    #expect(text.contains("<background-results>"))
    #expect(text.contains("[bg:\(jobId)]"))
    #expect(text.contains("completed:"))
    #expect(text.contains("</background-results>"))
  }

  @Test func multipleNotificationsDrainedAtOnce() async throws {
    let (agent, _) = makeAgent()

    var jobIds: [String] = []
    for i in 0..<3 {
      let confirmation = await agent.backgroundManager.run(command: "echo job\(i)")
      jobIds.append(try extractJobId(confirmation))
    }
    for jobId in jobIds {
      await agent.backgroundManager.awaitCompletion(jobId: jobId)
    }

    let messages: [Message] = [.assistant("ok")]
    let result = await agent.drainBackgroundNotifications(messages)

    try #require(result.count >= 2, "Expected at least 2 messages, got \(result.count)")

    let text = result[1].content.textContent
    for jobId in jobIds {
      #expect(text.contains("[bg:\(jobId)]"))
    }
  }

  @Test func appendsToExistingUserMessage() async throws {
    let (agent, _) = makeAgent()

    let confirmation = await agent.backgroundManager.run(command: "echo x")
    let jobId = try extractJobId(confirmation)
    await agent.backgroundManager.awaitCompletion(jobId: jobId)

    // Last message is user — should append, not add new user message
    let messages: [Message] = [.user("my query")]
    let result = await agent.drainBackgroundNotifications(messages)

    // Should be: updated user message + assistant "Noted"
    #expect(result.count == 2)
    #expect(result[0].role == .user)
    #expect(result[0].content.count == 2)  // original text + background-results
    #expect(result[0].content.textContent.contains("my query"))
    #expect(result[0].content.textContent.contains("<background-results>"))
    #expect(result[1] == .assistant("Noted background results."))
  }
}

// MARK: - Background integration

@Suite("Background loop integration")
struct BackgroundLoopIntegrationTests {
  @Test func backgroundResultsAppearInAPIRequest() async throws {
    let mock = MockAPIClient()
    mock.responses = [
      // First: model asks to run a fast background command
      backgroundRunResponse(id: "t1", command: "echo bg-done"),
      // Second: model does something else (by this time bg job completes)
      makeResponse(
        content: [
          .toolUse(
            id: "t2",
            name: "bash",
            input: .object(["command": .string("echo foreground")])
          )
        ],
        stopReason: .toolUse
      ),
      // Third: final answer
      makeResponse(content: [.text("all done")])
    ]
    let (agent, _) = makeAgent(mock: mock)

    // Await the background job between mock responses to ensure determinism
    let result = try await agent.run(query: "run bg and fg")

    #expect(result == "all done")
    #expect(mock.requests.count == 3)

    // After the background_run tool returns and before the next API call,
    // the drain should pick up the completed job. "echo bg-done" completes
    // near-instantly, so by the second API call the notification is ready.
    let allMessageTexts = mock.requests.dropFirst().flatMap { request in
      request.messages.flatMap { message in
        message.content.compactMap { block -> String? in
          if case .text(let text) = block {
            return text
          }
          return nil
        }
      }
    }

    let hasBackgroundResults = allMessageTexts.contains { $0.contains("<background-results>") }
    #expect(hasBackgroundResults)
  }

  @Test func noBackgroundResultsWhenNoJobs() async throws {
    let mock = MockAPIClient()
    mock.responses = [
      makeResponse(
        content: [
          .toolUse(
            id: "t1",
            name: "bash",
            input: .object(["command": .string("echo hi")])
          )
        ],
        stopReason: .toolUse
      ),
      makeResponse(content: [.text("done")])
    ]
    let (agent, _) = makeAgent(mock: mock)

    _ = try await agent.run(query: "just echo")

    // No background jobs — no background-results should appear
    for request in mock.requests {
      for message in request.messages {
        let text = message.content.textContent
        #expect(!text.contains("<background-results>"))
      }
    }
  }
}

// MARK: - Todo reminder

@Suite("Todo reminder")
struct TodoReminderTests {
  private static func bashToolUseResponse(id: String) -> APIResponse {
    makeResponse(
      content: [
        .toolUse(id: id, name: "bash", input: .object(["command": "echo ok"]))
      ],
      stopReason: .toolUse
    )
  }

  private static func todoToolUseResponse(id: String) -> APIResponse {
    makeResponse(
      content: [
        .toolUse(
          id: id,
          name: "todo",
          input: .object([
            "items": .array([
              .object([
                "id": "1",
                "text": "task",
                "status": "pending"
              ])
            ])
          ])
        )
      ],
      stopReason: .toolUse
    )
  }

  private static let endResponse = makeResponse(content: [.text("done")])

  private func userMessages(from mock: MockAPIClient) throws -> [[ContentBlock]] {
    try mock.requests.dropFirst().map { request in
      let lastMessage = try #require(request.messages.last)
      return lastMessage.content
    }
  }

  private func containsReminder(_ content: [ContentBlock]) -> Bool {
    content.contains(where: {
      if case .text("Update your todos.") = $0 { true } else { false }
    })
  }

  @Test func noReminderWithoutActiveTodos() async throws {
    let mock = MockAPIClient()
    mock.responses = [
      Self.bashToolUseResponse(id: "t1"),
      Self.bashToolUseResponse(id: "t2"),
      Self.bashToolUseResponse(id: "t3"),
      Self.bashToolUseResponse(id: "t4"),
      Self.endResponse
    ]
    let (agent, _) = makeAgent(mock: mock)

    _ = try await agent.run(query: "go")

    let userMsgs = try userMessages(from: mock)
    #expect(userMsgs.count == 4)
    for content in userMsgs {
      #expect(!containsReminder(content))
    }
  }

  @Test func reminderInjectedAtThreshold() async throws {
    let mock = MockAPIClient()
    mock.responses = [
      Self.todoToolUseResponse(id: "t0"),  // creates pending todo, counter -> 0
      Self.bashToolUseResponse(id: "t1"),  // counter -> 1
      Self.bashToolUseResponse(id: "t2"),  // counter -> 2
      Self.bashToolUseResponse(id: "t3"),  // counter -> 3
      Self.endResponse
    ]
    let (agent, _) = makeAgent(mock: mock)

    _ = try await agent.run(query: "go")

    let userMsgs = try userMessages(from: mock)
    #expect(userMsgs.count == 4)
    // Turns 1–3 should NOT have the reminder
    #expect(!containsReminder(userMsgs[0]))
    #expect(!containsReminder(userMsgs[1]))
    #expect(!containsReminder(userMsgs[2]))
    // Turn 4 (counter == 3, active todos exist) should have the reminder
    #expect(containsReminder(userMsgs[3]))
    let lastBlock = try #require(userMsgs[3].last)
    #expect(lastBlock == .text("Update your todos."))
  }

  @Test func counterResetsOnTodoCall() async throws {
    let mock = MockAPIClient()
    mock.responses = [
      Self.bashToolUseResponse(id: "t1"),  // counter -> 1
      Self.bashToolUseResponse(id: "t2"),  // counter -> 2
      Self.todoToolUseResponse(id: "t3"),  // counter -> 0
      Self.bashToolUseResponse(id: "t4"),  // counter -> 1
      Self.bashToolUseResponse(id: "t5"),  // counter -> 2
      Self.endResponse
    ]
    let (agent, _) = makeAgent(mock: mock)

    _ = try await agent.run(query: "go")

    let userMsgs = try userMessages(from: mock)
    #expect(userMsgs.count == 5)
    for content in userMsgs {
      #expect(!containsReminder(content))
    }
  }
}
