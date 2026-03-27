// NotificationService.swift — Configurable notifications for long-running tasks
//
// Reads settings from JuncoConfig.notifications (threshold, method).
// Falls back to terminal bell if system notifications aren't authorized.

import Foundation
import UserNotifications

/// Notification method.
public enum NotificationMethod: String, Sendable {
  case system  // macOS UNUserNotification
  case bell    // Terminal bell character
  case none    // Disabled
}

/// Manages notifications for long-running agent tasks.
public actor NotificationService {
  private var authorized = false
  public let threshold: TimeInterval
  public let method: NotificationMethod
  public let enabled: Bool

  /// Initialize from JuncoConfig (reads .junco/config.json).
  public init(workingDirectory: String) {
    let config = JuncoConfig.load(from: workingDirectory)
    self.enabled = config.notifications?.enabled ?? true
    self.threshold = TimeInterval(config.notifications?.thresholdSeconds ?? 30)
    self.method = NotificationMethod(rawValue: config.notifications?.method ?? "system") ?? .system
  }

  /// Initialize with explicit values (for testing).
  public init(threshold: TimeInterval = 30, method: NotificationMethod = .system, enabled: Bool = true) {
    self.threshold = threshold
    self.method = method
    self.enabled = enabled
  }

  /// Request notification authorization (system method only).
  public func requestAuthorization() async {
    guard enabled, method == .system else { return }
    let center = UNUserNotificationCenter.current()
    do {
      authorized = try await center.requestAuthorization(options: [.alert, .sound])
    } catch {
      authorized = false
    }
  }

  /// Send a notification if the elapsed time exceeds the threshold.
  public func notifyIfSlow(taskStart: Date, query: String) async {
    guard enabled else { return }
    let elapsed = Date().timeIntervalSince(taskStart)
    guard elapsed >= threshold else { return }

    let message = "Task completed (\(Int(elapsed))s): \(String(query.prefix(50)))"

    switch method {
    case .system:
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
        // Fallback to bell if not authorized
        print("\u{07}", terminator: "")
        fflush(stdout)
      }
    case .bell:
      print("\u{07}", terminator: "")
      fflush(stdout)
    case .none:
      break
    }
  }
}
