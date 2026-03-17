// swiftlint:disable file_length
import Foundation
import Testing

@testable import Core

// MARK: - Helpers

private func makeTempDir() throws -> URL {
  let dir = FileManager.default.temporaryDirectory
    .appendingPathComponent("task-test-\(UUID().uuidString)")
  try FileManager.default.createDirectory(
    at: dir, withIntermediateDirectories: true
  )
  return dir
}

private func makeAgentInTempDir() throws -> (Agent, URL) {
  let dir = try makeTempDir()
  let (agent, _) = makeAgent(workingDirectory: dir.path)
  return (agent, dir)
}

private func decodeTask(_ json: String) throws -> AgentTask {
  try JSONDecoder().decode(AgentTask.self, from: Data(json.utf8))
}

private func taskToolUse(
  id: String, name: String, input: JSONValue
) -> APIResponse {
  makeResponse(
    content: [.toolUse(id: id, name: name, input: input)],
    stopReason: .toolUse
  )
}

private func cascadeUnblockResponses() -> [APIResponse] {
  [
    taskToolUse(id: "t1", name: "task_create", input: .object(["subject": .string("Task A")])),
    taskToolUse(id: "t2", name: "task_create", input: .object(["subject": .string("Task B")])),
    taskToolUse(
      id: "t3", name: "task_update",
      input: .object(["task_id": .int(1), "add_blocks": .array([.int(2)])])
    ),
    taskToolUse(
      id: "t4", name: "task_update",
      input: .object(["task_id": .int(1), "status": .string("completed")])
    ),
    taskToolUse(id: "t5", name: "task_list", input: .object([:])),
    makeResponse(content: [.text("done")])
  ]
}

// MARK: - Task tool handlers

@Suite("Task tool handlers")
struct TaskToolHandlerTests {

  // MARK: task_create

  @Test func taskCreateSuccess() async throws {
    let (agent, dir) = try makeAgentInTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let result = await agent.executeTool(
      name: "task_create",
      input: .object([
        "subject": .string("Setup project"),
        "description": .string("Initialize the repo")
      ])
    )

    guard case .success(let output) = result else {
      Issue.record("Expected success, got \(result)")
      return
    }
    let task = try decodeTask(output)

    #expect(task.subject == "Setup project")
    #expect(task.description == "Initialize the repo")
    #expect(task.status == .pending)
  }

  @Test func taskCreateWithoutDescription() async throws {
    let (agent, dir) = try makeAgentInTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let result = await agent.executeTool(
      name: "task_create",
      input: .object(["subject": .string("Quick task")])
    )

    guard case .success(let output) = result else {
      Issue.record("Expected success, got \(result)")
      return
    }
    let task = try decodeTask(output)
    #expect(task.subject == "Quick task")
    #expect(task.description.isEmpty)
  }

  @Test func taskCreateMissingSubject() async throws {
    let (agent, dir) = try makeAgentInTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let result = await agent.executeTool(
      name: "task_create",
      input: .object([:])
    )
    #expect(result == .failure(.missingParameter("subject")))
  }

  // MARK: task_get

  @Test func taskGetSuccess() async throws {
    let (agent, dir) = try makeAgentInTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    _ = await agent.executeTool(
      name: "task_create",
      input: .object(["subject": .string("My task")])
    )

    let result = await agent.executeTool(
      name: "task_get",
      input: .object(["task_id": .int(1)])
    )

    guard case .success(let output) = result else {
      Issue.record("Expected success, got \(result)")
      return
    }
    let task = try decodeTask(output)
    #expect(task.subject == "My task")
  }

  @Test func taskGetNonexistent() async throws {
    let (agent, dir) = try makeAgentInTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let result = await agent.executeTool(
      name: "task_get",
      input: .object(["task_id": .int(999)])
    )

    guard case .failure(.executionFailed(let msg)) = result else {
      Issue.record("Expected executionFailed, got \(result)")
      return
    }
    #expect(msg.contains("taskNotFound"))
  }

  @Test func taskGetMissingId() async throws {
    let (agent, dir) = try makeAgentInTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let result = await agent.executeTool(
      name: "task_get",
      input: .object([:])
    )
    #expect(result == .failure(.missingParameter("task_id")))
  }

  // MARK: task_update

  @Test func taskUpdateStatus() async throws {
    let (agent, dir) = try makeAgentInTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    _ = await agent.executeTool(
      name: "task_create",
      input: .object(["subject": .string("Task A")])
    )

    let result = await agent.executeTool(
      name: "task_update",
      input: .object([
        "task_id": .int(1),
        "status": .string("in_progress")
      ])
    )

    guard case .success(let output) = result else {
      Issue.record("Expected success, got \(result)")
      return
    }
    let task = try decodeTask(output)
    #expect(task.status == .inProgress)
  }

  @Test func taskUpdateAddBlocks() async throws {
    let (agent, dir) = try makeAgentInTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    _ = await agent.executeTool(
      name: "task_create",
      input: .object(["subject": .string("Task A")])
    )
    _ = await agent.executeTool(
      name: "task_create",
      input: .object(["subject": .string("Task B")])
    )

    let result = await agent.executeTool(
      name: "task_update",
      input: .object([
        "task_id": .int(1),
        "add_blocks": .array([.int(2)])
      ])
    )

    guard case .success(let output) = result else {
      Issue.record("Expected success, got \(result)")
      return
    }
    let task1 = try decodeTask(output)
    #expect(task1.blocks == [2])

    // Verify task 2 now has blockedBy [1]
    let task2Result = await agent.executeTool(
      name: "task_get",
      input: .object(["task_id": .int(2)])
    )
    guard case .success(let task2Output) = task2Result else {
      Issue.record("Expected success for task 2")
      return
    }
    let task2 = try decodeTask(task2Output)
    #expect(task2.blockedBy == [1])
  }

  @Test func taskUpdateAddBlockedBy() async throws {
    let (agent, dir) = try makeAgentInTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    _ = await agent.executeTool(
      name: "task_create",
      input: .object(["subject": .string("Blocker")])
    )
    _ = await agent.executeTool(
      name: "task_create",
      input: .object(["subject": .string("Blocked")])
    )

    let result = await agent.executeTool(
      name: "task_update",
      input: .object([
        "task_id": .int(2),
        "add_blocked_by": .array([.int(1)])
      ])
    )

    guard case .success(let output) = result else {
      Issue.record("Expected success, got \(result)")
      return
    }
    let task2 = try decodeTask(output)
    #expect(task2.blockedBy == [1])

    // Verify reverse wiring: task 1 should have blocks [2]
    let task1Result = await agent.executeTool(
      name: "task_get",
      input: .object(["task_id": .int(1)])
    )
    guard case .success(let task1Output) = task1Result else {
      Issue.record("Expected success for task 1")
      return
    }
    let task1 = try decodeTask(task1Output)
    #expect(task1.blocks == [2])
  }

  @Test func taskUpdateMissingId() async throws {
    let (agent, dir) = try makeAgentInTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let result = await agent.executeTool(
      name: "task_update",
      input: .object(["status": .string("completed")])
    )
    #expect(result == .failure(.missingParameter("task_id")))
  }

  @Test func taskUpdateNonexistent() async throws {
    let (agent, dir) = try makeAgentInTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let result = await agent.executeTool(
      name: "task_update",
      input: .object([
        "task_id": .int(999),
        "status": .string("completed")
      ])
    )

    guard case .failure(.executionFailed(let msg)) = result else {
      Issue.record("Expected executionFailed, got \(result)")
      return
    }
    #expect(msg.contains("taskNotFound"))
  }

  // MARK: task_list

  @Test func taskListEmpty() async throws {
    let (agent, dir) = try makeAgentInTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let result = await agent.executeTool(
      name: "task_list",
      input: .object([:])
    )
    #expect(result == .success("No tasks."))
  }

  @Test func taskListWithTasks() async throws {
    let (agent, dir) = try makeAgentInTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    _ = await agent.executeTool(
      name: "task_create",
      input: .object(["subject": .string("First")])
    )
    _ = await agent.executeTool(
      name: "task_create",
      input: .object(["subject": .string("Second")])
    )

    let result = await agent.executeTool(
      name: "task_list",
      input: .object([:])
    )

    guard case .success(let output) = result else {
      Issue.record("Expected success, got \(result)")
      return
    }
    #expect(output.contains("[ ] 1: First"))
    #expect(output.contains("[ ] 2: Second"))
  }
}

// MARK: - Task tools in agent loop

@Suite("Task tools in agent loop")
struct TaskToolIntegrationTests {
  @Test func taskCreateViaAgentLoop() async throws {
    let mock = MockAPIClient()
    mock.responses = [
      makeResponse(
        content: [
          .toolUse(
            id: "t1",
            name: "task_create",
            input: .object(["subject": .string("Build feature")])
          )
        ],
        stopReason: .toolUse
      ),
      makeResponse(content: [.text("done")])
    ]

    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let (agent, _) = makeAgent(mock: mock, workingDirectory: dir.path)
    let result = try await agent.run(query: "create a task")

    #expect(result == "done")

    // Verify tool_result in the second request contains task JSON
    let secondRequest = mock.requests[1]
    let lastMessage = try #require(secondRequest.messages.last)
    let hasTaskResult = lastMessage.content.contains {
      isToolResult($0) { id, content, isError in
        id == "t1" && content.contains("\"subject\" : \"Build feature\"") && !isError
      }
    }
    #expect(hasTaskResult)
  }

  @Test func completingTaskCascadesUnblock() async throws {
    let mock = MockAPIClient()
    mock.responses = cascadeUnblockResponses()

    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let (agent, _) = makeAgent(mock: mock, workingDirectory: dir.path)
    _ = try await agent.run(query: "setup tasks")

    // The task_list result (in request 5) should show task 2 unblocked
    let listRequest = mock.requests[5]
    let lastMessage = try #require(listRequest.messages.last)
    let hasListResult = lastMessage.content.contains {
      isToolResult($0) { id, content, isError in
        id == "t5" && !content.contains("blocked by") && !isError
      }
    }
    #expect(hasListResult)
  }

  @Test func subagentReceivesReadOnlyTaskTools() async throws {
    let mock = MockAPIClient()
    mock.responses = [
      // Parent: spawn subagent
      makeResponse(
        content: [
          .toolUse(
            id: "t1",
            name: "agent",
            input: .object(["prompt": "list tasks"])
          )
        ],
        stopReason: .toolUse
      ),
      // Subagent: returns text
      makeResponse(content: [.text("subagent done")]),
      // Parent: final
      makeResponse(content: [.text("all done")])
    ]

    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let (agent, _) = makeAgent(mock: mock, workingDirectory: dir.path)
    _ = try await agent.run(query: "go")

    // Subagent request (index 1) should have 7 tools
    let subagentTools = mock.requests[1].tools ?? []
    let toolNames = Set(subagentTools.map(\.name))
    #expect(toolNames.count == 7)
    #expect(toolNames.contains("task_list"))
    #expect(toolNames.contains("task_get"))
    #expect(!toolNames.contains("task_create"))
    #expect(!toolNames.contains("task_update"))
  }

  @Test func subagentTaskCreateRejected() async throws {
    let mock = MockAPIClient()
    mock.responses = [
      // Parent: spawn subagent
      makeResponse(
        content: [
          .toolUse(
            id: "t1",
            name: "agent",
            input: .object(["prompt": "create a task"])
          )
        ],
        stopReason: .toolUse
      ),
      // Subagent: tries to call task_create (hallucinated)
      makeResponse(
        content: [
          .toolUse(
            id: "t2",
            name: "task_create",
            input: .object(["subject": .string("sneaky")])
          )
        ],
        stopReason: .toolUse
      ),
      // Subagent: gets rejection, returns text
      makeResponse(content: [.text("subagent done")]),
      // Parent: final
      makeResponse(content: [.text("all done")])
    ]

    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }

    let (agent, _) = makeAgent(mock: mock, workingDirectory: dir.path)
    _ = try await agent.run(query: "go")

    // Subagent's second request should have rejection
    let subagentMessages = mock.requests[2].messages
    let lastMessage = try #require(subagentMessages.last)
    let hasRejection = lastMessage.content.contains {
      isToolResult($0) { _, content, isError in
        content.contains("not allowed") && isError
      }
    }
    #expect(hasRejection)
  }
}
