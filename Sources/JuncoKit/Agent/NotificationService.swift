// NotificationService.swift — Configurable notifications for long-running tasks
//
// Uses terminal bell by default. System notifications (UNUserNotificationCenter)
// require a bundle identity and crash bare CLI executables, so they're only
// attempted when running inside an .app bundle.

import Foundation

/// Notification method.
public enum NotificationMethod: String, Sendable {
  case system  // macOS UNUserNotification (requires .app bundle)
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
    // Default to bell — system notifications crash bare CLI tools
    let configured = NotificationMethod(rawValue: config.notifications?.method ?? "bell") ?? .bell
    self.method = configured
  }

  /// Initialize with explicit values (for testing).
  public init(threshold: TimeInterval = 30, method: NotificationMethod = .bell, enabled: Bool = true) {
    self.threshold = threshold
    self.method = method
    self.enabled = enabled
  }

  /// Request notification authorization. Only safe inside an .app bundle.
  public func requestAuthorization() async {
    guard enabled, method == .system else { return }

    // UNUserNotificationCenter.current() crashes if there's no bundle identity.
    // Only attempt if we're running inside an .app bundle.
    guard Bundle.main.bundleIdentifier != nil else {
      // Bare CLI — fall back silently, notifyIfSlow will use bell
      return
    }

    // Import dynamically to avoid linking crash on CLI
    guard let center = tryGetNotificationCenter() else { return }
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

    let effectiveMethod = (method == .system && !authorized) ? .bell : method

    switch effectiveMethod {
    case .system:
      if let center = tryGetNotificationCenter() {
        let content = UNMutableNotificationContent()
        content.title = "junco"
        content.body = "Task completed (\(Int(elapsed))s): \(String(query.prefix(50)))"
        content.sound = .default
        let request = UNNotificationRequest(
          identifier: UUID().uuidString, content: content, trigger: nil
        )
        try? await center.add(request)
      }
    case .bell:
      print("\u{07}", terminator: "")
      fflush(stdout)
    case .none:
      break
    }
  }

  /// Safely get UNUserNotificationCenter, returning nil if not available.
  private func tryGetNotificationCenter() -> UNUserNotificationCenter? {
    guard Bundle.main.bundleIdentifier != nil else { return nil }
    return UNUserNotificationCenter.current()
  }
}

import UserNotifications
