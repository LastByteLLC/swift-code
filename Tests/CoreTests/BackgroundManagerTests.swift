import Foundation
import Testing

@testable import Core

// MARK: - BackgroundJobStatus

@Suite("BackgroundJobStatus")
struct BackgroundJobStatusTests {
  @Test(arguments: [
    (BackgroundJobStatus.running, "running"),
    (BackgroundJobStatus.completed, "completed"),
    (BackgroundJobStatus.timeout, "timeout"),
    (BackgroundJobStatus.error, "error")
  ])
  func rawValueRoundTrip(status: BackgroundJobStatus, raw: String) {
    #expect(status.rawValue == raw)
    #expect(BackgroundJobStatus(rawValue: raw) == status)
  }
}

private func makeManager() -> BackgroundManager {
  BackgroundManager(executor: ShellExecutor())
}

// MARK: - BackgroundManager

@Suite("BackgroundManager")
struct BackgroundManagerTests {

  @Test func runReturnsConfirmation() async {
    let manager = makeManager()
    let result = await manager.run(command: "echo hello")
    #expect(result.hasPrefix("Background job "))
    #expect(result.contains("started:"))
    #expect(result.contains("echo hello"))
  }

  @Test func checkUnknownJobReturnsError() async {
    let manager = makeManager()
    let result = await manager.check(jobId: "nonexistent")
    #expect(result == "Error: Unknown job nonexistent")
  }

  @Test func checkNilListsAllJobs() async {
    let manager = makeManager()
    let result = await manager.check(jobId: nil)
    #expect(result == "No background jobs.")
  }

  @Test func jobIdUniqueness() async throws {
    let manager = makeManager()
    let result1 = await manager.run(command: "echo 1")
    let result2 = await manager.run(command: "echo 2")
    let result3 = await manager.run(command: "echo 3")

    let id1 = try extractJobId(result1)
    let id2 = try extractJobId(result2)
    let id3 = try extractJobId(result3)

    #expect(id1 != id2)
    #expect(id2 != id3)
    #expect(id1 != id3)
  }

  @Test func checkAfterCompletionShowsCompleted() async throws {
    let manager = makeManager()
    let confirmation = await manager.run(command: "echo done")
    let jobId = try extractJobId(confirmation)

    await manager.awaitCompletion(jobId: jobId)
    let status = await manager.check(jobId: jobId)
    #expect(status.contains("[completed]"))
    #expect(status.contains("done"))
  }

  @Test func failedCommandProducesError() async throws {
    let manager = makeManager()
    let confirmation = await manager.run(command: "false")
    let jobId = try extractJobId(confirmation)

    await manager.awaitCompletion(jobId: jobId)
    let status = await manager.check(jobId: jobId)
    #expect(status.contains("[error]"))
  }

  @Test(.timeLimit(.minutes(1)))
  func timeoutProducesTimeoutStatus() async throws {
    let manager = makeManager()
    let confirmation = await manager.run(command: "sleep 10", timeout: 0.5)
    let jobId = try extractJobId(confirmation)

    await manager.awaitCompletion(jobId: jobId)
    let status = await manager.check(jobId: jobId)
    #expect(status.contains("[timeout]"))
  }

  @Test func emptyCommandExecutes() async throws {
    let manager = makeManager()
    let confirmation = await manager.run(command: "")
    let jobId = try extractJobId(confirmation)
    await manager.awaitCompletion(jobId: jobId)

    let status = await manager.check(jobId: jobId)
    // Should not crash — either completed or error is fine
    #expect(
      status.contains("[completed]") || status.contains("[error]")
    )
  }

  @Test func awaitCompletionNonexistentReturnsImmediately() async {
    let manager = makeManager()
    // Should not hang
    await manager.awaitCompletion(jobId: "nonexistent")
  }

  @Test func checkNilListsMultipleJobs() async throws {
    let manager = makeManager()
    let r1 = await manager.run(command: "echo a")
    let r2 = await manager.run(command: "echo b")
    let id1 = try extractJobId(r1)
    let id2 = try extractJobId(r2)

    await manager.awaitCompletion(jobId: id1)
    await manager.awaitCompletion(jobId: id2)

    let listing = await manager.check(jobId: nil)
    #expect(listing.contains(id1))
    #expect(listing.contains(id2))
  }
}

// MARK: - BackgroundManager Notifications

@Suite("BackgroundManager Notifications")
struct BackgroundManagerNotificationTests {

  @Test func completedJobAppearsInNotifications() async throws {
    let manager = makeManager()
    let confirmation = await manager.run(command: "echo notify-me")
    let jobId = try extractJobId(confirmation)

    await manager.awaitCompletion(jobId: jobId)
    let notifications = await manager.drainNotifications()
    #expect(notifications.count == 1)
    #expect(notifications[0].jobId == jobId)
    #expect(notifications[0].status == .completed)
  }

  @Test func drainClearsQueue() async throws {
    let manager = makeManager()
    let confirmation = await manager.run(command: "echo clear-test")
    let jobId = try extractJobId(confirmation)

    await manager.awaitCompletion(jobId: jobId)
    let first = await manager.drainNotifications()
    #expect(first.count == 1)

    let second = await manager.drainNotifications()
    #expect(second.isEmpty)
  }

  @Test func multipleJobsDrainAll() async throws {
    let manager = makeManager()
    let r1 = await manager.run(command: "echo one")
    let r2 = await manager.run(command: "echo two")
    let r3 = await manager.run(command: "echo three")

    await manager.awaitCompletion(jobId: try extractJobId(r1))
    await manager.awaitCompletion(jobId: try extractJobId(r2))
    await manager.awaitCompletion(jobId: try extractJobId(r3))

    let notifications = await manager.drainNotifications()
    #expect(notifications.count == 3)
  }

  @Test func notificationResultTruncated() async throws {
    let manager = makeManager()
    let longOutput = String(repeating: "x", count: 1000)
    let confirmation = await manager.run(command: "echo '\(longOutput)'")
    let jobId = try extractJobId(confirmation)

    await manager.awaitCompletion(jobId: jobId)
    let notifications = await manager.drainNotifications()
    #expect(notifications.count == 1)
    #expect(notifications[0].result.count <= Limits.backgroundResultPreview)
  }

  @Test func notificationCommandTruncated() async throws {
    let manager = makeManager()
    let longCommand = "echo " + String(repeating: "a", count: 200)
    let confirmation = await manager.run(command: longCommand)
    let jobId = try extractJobId(confirmation)

    await manager.awaitCompletion(jobId: jobId)
    let notifications = await manager.drainNotifications()
    #expect(notifications.count == 1)
    #expect(notifications[0].command.count <= Limits.backgroundCommandPreview)
  }
}
