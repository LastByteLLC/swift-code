// NotificationService.swift — macOS notifications for long-running tasks
//
// Sends a system notification if a task exceeds a configurable threshold.
// Falls back to terminal bell if notifications aren't authorized.

import Foundation
import UserNotifications

/// Manages notifications for long-running agent tasks.
public actor NotificationService {
  private var authorized = false
  private let threshold: TimeInterval

  public init(threshold: TimeInterval = 30) {
    self.threshold = threshold
  }

  /// Request notification authorization.
  public func requestAuthorization() async {
    let center = UNUserNotificationCenter.current()
    do {
      authorized = try await center.requestAuthorization(options: [.alert, .sound])
    } catch {
      authorized = false
    }
  }

  /// Send a notification if the elapsed time exceeds the threshold.
  public func notifyIfSlow(taskStart: Date, query: String) async {
    let elapsed = Date().timeIntervalSince(taskStart)
    guard elapsed >= threshold else { return }

    let message = "Task completed (\(Int(elapsed))s): \(String(query.prefix(50)))"

    if authorized {
      let content = UNMutableNotificationContent()
      content.title = "junco"
      content.body = message
      content.sound = .default

      let request = UNNotificationRequest(
        identifier: UUID().uuidString, content: content, trigger: nil
      )
      try? await UNUserNotificationCenter.current().add(request)
    } else {
      // Fallback: terminal bell
      print("\u{07}", terminator: "")
      fflush(stdout)
    }
  }
}
