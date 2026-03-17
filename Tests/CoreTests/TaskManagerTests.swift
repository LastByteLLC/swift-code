import Foundation
import Testing

@testable import Core

private func makeTempTaskManager() -> (TaskManager, String) {
  let dir = FileManager.default.temporaryDirectory
    .appendingPathComponent("tasks-test-\(UUID().uuidString)")
    .path
  let manager = TaskManager(directory: dir)
  return (manager, dir)
}

private func decodeTask(_ json: String) throws -> AgentTask {
  try JSONDecoder().decode(AgentTask.self, from: Data(json.utf8))
}

// MARK: - TaskStatus

@Suite("TaskStatus")
struct TaskStatusTests {
  @Test(arguments: [
    (TaskStatus.pending, "[ ]"),
    (TaskStatus.inProgress, "[>]"),
    (TaskStatus.completed, "[x]")
  ])
  func markerDisplay(status: TaskStatus, expected: String) {
    #expect(status.marker == expected)
  }
}

// MARK: - TaskManager CRUD

@Suite("TaskManager")
struct TaskManagerTests {
  @Test func createReturnsTask() throws {
    let (manager, dir) = makeTempTaskManager()
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let task = try decodeTask(try manager.create(subject: "Setup project"))
    #expect(task.subject == "Setup project")
    #expect(task.id == 1)
    #expect(task.status == .pending)
  }

  @Test func createIncrementsId() throws {
    let (manager, dir) = makeTempTaskManager()
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let first = try decodeTask(try manager.create(subject: "First"))
    let second = try decodeTask(try manager.create(subject: "Second"))
    #expect(first.id == 1)
    #expect(second.id == 2)
  }

  @Test func getReturnsTask() throws {
    let (manager, dir) = makeTempTaskManager()
    defer { try? FileManager.default.removeItem(atPath: dir) }

    _ = try manager.create(subject: "Test task", description: "A description")
    let task = try decodeTask(try manager.get(taskId: 1))
    #expect(task.subject == "Test task")
    #expect(task.description == "A description")
  }

  @Test func getNonexistentThrows() {
    let (manager, dir) = makeTempTaskManager()
    defer { try? FileManager.default.removeItem(atPath: dir) }

    #expect(throws: TaskManager.TaskError.taskNotFound(99)) {
      try manager.get(taskId: 99)
    }
  }

  @Test func updateStatus() throws {
    let (manager, dir) = makeTempTaskManager()
    defer { try? FileManager.default.removeItem(atPath: dir) }

    _ = try manager.create(subject: "Task")
    let task = try decodeTask(try manager.update(taskId: 1, status: "in_progress"))
    #expect(task.status == .inProgress)
  }

  @Test func updateInvalidStatusThrows() throws {
    let (manager, dir) = makeTempTaskManager()
    defer { try? FileManager.default.removeItem(atPath: dir) }

    _ = try manager.create(subject: "Task")
    #expect(throws: TaskManager.TaskError.invalidStatus("bogus")) {
      try manager.update(taskId: 1, status: "bogus")
    }
  }

  @Test func updateNonexistentThrows() {
    let (manager, dir) = makeTempTaskManager()
    defer { try? FileManager.default.removeItem(atPath: dir) }

    #expect(throws: TaskManager.TaskError.taskNotFound(42)) {
      try manager.update(taskId: 42, status: "completed")
    }
  }

  @Test func listAllRendersTasksWithMarkers() throws {
    let (manager, dir) = makeTempTaskManager()
    defer { try? FileManager.default.removeItem(atPath: dir) }

    _ = try manager.create(subject: "First")
    _ = try manager.create(subject: "Second")
    _ = try manager.update(taskId: 2, status: "in_progress")

    let output = manager.listAll()
    #expect(output.contains("[ ] 1: First"))
    #expect(output.contains("[>] 2: Second"))
  }

  @Test func listAllEmptyState() {
    let (manager, dir) = makeTempTaskManager()
    defer { try? FileManager.default.removeItem(atPath: dir) }

    #expect(manager.listAll() == "No tasks.")
  }
}

// MARK: - Dependencies

@Suite("TaskManager Dependencies")
struct TaskManagerDependencyTests {
  @Test func addBlocksBidirectionalWiring() throws {
    let (manager, dir) = makeTempTaskManager()
    defer { try? FileManager.default.removeItem(atPath: dir) }

    _ = try manager.create(subject: "Task 1")
    _ = try manager.create(subject: "Task 2")
    _ = try manager.update(taskId: 1, addBlocks: [2])

    let task1 = try decodeTask(try manager.get(taskId: 1))
    let task2 = try decodeTask(try manager.get(taskId: 2))
    #expect(task1.blocks == [2])
    #expect(task2.blockedBy == [1])
  }

  @Test func clearDependencyOnCompletion() throws {
    let (manager, dir) = makeTempTaskManager()
    defer { try? FileManager.default.removeItem(atPath: dir) }

    _ = try manager.create(subject: "Blocker")
    _ = try manager.create(subject: "Blocked A")
    _ = try manager.create(subject: "Blocked B")
    _ = try manager.update(taskId: 1, addBlocks: [2, 3])

    // Complete task 1 — should clear from dependents
    _ = try manager.update(taskId: 1, status: "completed")

    let task2 = try decodeTask(try manager.get(taskId: 2))
    let task3 = try decodeTask(try manager.get(taskId: 3))
    #expect(task2.blockedBy.isEmpty)
    #expect(task3.blockedBy.isEmpty)
  }

  @Test func partialUnblocking() throws {
    let (manager, dir) = makeTempTaskManager()
    defer { try? FileManager.default.removeItem(atPath: dir) }

    _ = try manager.create(subject: "Blocker A")
    _ = try manager.create(subject: "Blocker B")
    _ = try manager.create(subject: "Blocked")

    _ = try manager.update(taskId: 1, addBlocks: [3])
    _ = try manager.update(taskId: 2, addBlocks: [3])

    // Complete only blocker A
    _ = try manager.update(taskId: 1, status: "completed")

    let task3 = try decodeTask(try manager.get(taskId: 3))
    // Still blocked by task 2
    #expect(task3.blockedBy == [2])
  }

  @Test func taskThatBlocksNothing() throws {
    let (manager, dir) = makeTempTaskManager()
    defer { try? FileManager.default.removeItem(atPath: dir) }

    _ = try manager.create(subject: "Standalone")
    _ = try manager.update(taskId: 1, status: "completed")

    let task = try decodeTask(try manager.get(taskId: 1))
    #expect(task.status == .completed)
    #expect(task.blocks.isEmpty)
  }

  @Test func listAllShowsBlockedBy() throws {
    let (manager, dir) = makeTempTaskManager()
    defer { try? FileManager.default.removeItem(atPath: dir) }

    _ = try manager.create(subject: "Task 1")
    _ = try manager.create(subject: "Task 2")
    _ = try manager.update(taskId: 1, addBlocks: [2])

    let output = manager.listAll()
    #expect(output.contains("(blocked by: 1)"))
  }

  @Test func selfReferentialDependencyBlockedByThrows() throws {
    let (manager, dir) = makeTempTaskManager()
    defer { try? FileManager.default.removeItem(atPath: dir) }

    _ = try manager.create(subject: "Task")
    #expect(throws: TaskManager.TaskError.selfReferentialDependency(1)) {
      try manager.update(taskId: 1, addBlockedBy: [1])
    }
  }

  @Test func selfReferentialDependencyBlocksThrows() throws {
    let (manager, dir) = makeTempTaskManager()
    defer { try? FileManager.default.removeItem(atPath: dir) }

    _ = try manager.create(subject: "Task")
    #expect(throws: TaskManager.TaskError.selfReferentialDependency(1)) {
      try manager.update(taskId: 1, addBlocks: [1])
    }
  }
}

// MARK: - Persistence

@Suite("TaskManager Persistence")
struct TaskManagerPersistenceTests {
  @Test func nextIdRecoveryWithGap() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("tasks-test-\(UUID().uuidString)")
      .path
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let manager1 = TaskManager(directory: dir)
    _ = try manager1.create(subject: "Task 1")  // id 1
    _ = try manager1.create(subject: "Task 3")  // id 2... but rename to simulate gap

    // Manually rename task_2.json to task_3.json to create a gap
    let fm = FileManager.default
    let src = (dir as NSString).appendingPathComponent("task_2.json")
    let dst = (dir as NSString).appendingPathComponent("task_3.json")
    try fm.moveItem(atPath: src, toPath: dst)

    // New manager should recover nextId = 4
    let manager2 = TaskManager(directory: dir)
    let task = try decodeTask(try manager2.create(subject: "Task 4"))
    #expect(task.id == 4)
  }

  @Test func emptyDirStartsAtOne() throws {
    let (manager, dir) = makeTempTaskManager()
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let task = try decodeTask(try manager.create(subject: "First"))
    #expect(task.id == 1)
  }

  @Test func freshDirCreation() {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("tasks-test-\(UUID().uuidString)")
      .path
    defer { try? FileManager.default.removeItem(atPath: dir) }

    _ = TaskManager(directory: dir)
    #expect(FileManager.default.fileExists(atPath: dir))
  }

  @Test func persistenceAcrossInstances() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("tasks-test-\(UUID().uuidString)")
      .path
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let manager1 = TaskManager(directory: dir)
    _ = try manager1.create(subject: "Persistent task")
    _ = try manager1.create(subject: "Another task")

    let manager2 = TaskManager(directory: dir)
    let task = try decodeTask(try manager2.get(taskId: 1))
    #expect(task.subject == "Persistent task")

    // nextId should be 3
    let newTask = try decodeTask(try manager2.create(subject: "Third"))
    #expect(newTask.id == 3)
  }

  @Test func jsonRoundTripFidelity() throws {
    let (manager, dir) = makeTempTaskManager()
    defer { try? FileManager.default.removeItem(atPath: dir) }

    _ = try manager.create(subject: "Round trip", description: "Test desc")

    // Read raw file from disk independently
    let path = (dir as NSString).appendingPathComponent("task_1.json")
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let task = try JSONDecoder().decode(AgentTask.self, from: data)

    #expect(task.id == 1)
    #expect(task.subject == "Round trip")
    #expect(task.description == "Test desc")
    #expect(task.status == .pending)
    #expect(task.blockedBy == [])
    #expect(task.blocks == [])
    #expect(task.owner == "")
  }

  @Test func malformedJSONInListAll() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("tasks-test-\(UUID().uuidString)")
      .path
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let manager = TaskManager(directory: dir)
    _ = try manager.create(subject: "Good task")

    // Write malformed JSON
    let badPath = (dir as NSString).appendingPathComponent("task_2.json")
    try "not json".write(toFile: badPath, atomically: true, encoding: .utf8)

    let output = manager.listAll()
    #expect(output.contains("[ ] 1: Good task"))
    // Malformed file is skipped gracefully
    #expect(!output.contains("task_2"))
  }

  @Test func malformedJSONInClearDependency() throws {
    let dir = FileManager.default.temporaryDirectory
      .appendingPathComponent("tasks-test-\(UUID().uuidString)")
      .path
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let manager = TaskManager(directory: dir)
    _ = try manager.create(subject: "Blocker")
    _ = try manager.create(subject: "Blocked")
    _ = try manager.update(taskId: 1, addBlocks: [2])

    // Corrupt task_2.json
    let badPath = (dir as NSString).appendingPathComponent("task_2.json")
    try "corrupt".write(toFile: badPath, atomically: true, encoding: .utf8)

    // clearDependency should not crash (called via completing task 1)
    _ = try manager.update(taskId: 1, status: "completed")

    // Task 1 still completes successfully
    let task1 = try decodeTask(try manager.get(taskId: 1))
    #expect(task1.status == .completed)
  }
}
