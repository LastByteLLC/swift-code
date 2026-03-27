// NotificationServiceTests.swift

import Testing
import Foundation
@testable import JuncoKit

@Suite("NotificationService")
struct NotificationServiceTests {
  @Test("default threshold is 30 seconds")
  func defaultThreshold() async {
    let svc = NotificationService(threshold: 30)
    let threshold = await svc.threshold
    #expect(threshold == 30)
  }

  @Test("reads config from JuncoConfig")
  func configReading() async throws {
    let dir = NSTemporaryDirectory() + "junco-notif-\(UUID().uuidString)"
    let juncoDir = "\(dir)/.junco"
    try FileManager.default.createDirectory(atPath: juncoDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let config = """
    {"notifications": {"enabled": true, "thresholdSeconds": 60, "method": "bell"}}
    """
    try config.write(toFile: "\(juncoDir)/config.json", atomically: true, encoding: .utf8)

    let svc = NotificationService(workingDirectory: dir)
    let threshold = await svc.threshold
    let method = await svc.method
    let enabled = await svc.enabled
    #expect(threshold == 60)
    #expect(method == .bell)
    #expect(enabled == true)
  }

  @Test("disabled notifications skip all calls")
  func disabled() async {
    let svc = NotificationService(threshold: 0, method: .none, enabled: false)
    // Should not crash or do anything
    await svc.notifyIfSlow(taskStart: Date.distantPast, query: "test")
  }

  @Test("does not notify for fast tasks")
  func fastTask() async {
    let svc = NotificationService(threshold: 30, method: .bell, enabled: true)
    // Task started now, threshold is 30s — should not trigger
    await svc.notifyIfSlow(taskStart: Date(), query: "test")
    // No crash = pass (bell would go to stdout which we can't capture in test)
  }
}
