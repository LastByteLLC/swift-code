import Foundation

public enum BackgroundJobStatus: String, Sendable, Equatable {
  case running
  case completed
  case timeout
  case error
}

public struct BackgroundJob: Sendable, Equatable {
  public let id: String
  public let command: String
  public let commandPreview: String
  public var status: BackgroundJobStatus
  public var result: String?
}

public struct BackgroundNotification: Sendable, Equatable {
  public let jobId: String
  public let status: BackgroundJobStatus
  public let command: String
  public let result: String
}

public actor BackgroundManager {
  private let executor: ShellExecutor

  private var jobs: [String: BackgroundJob] = [:]
  private var notifications: [BackgroundNotification] = []
  private var runningTasks: [String: Task<Void, Never>] = [:]

  public init(executor: ShellExecutor) {
    self.executor = executor
  }

  public func run(
    command: String,
    timeout: TimeInterval = Limits.backgroundTimeout
  ) -> String {
    let jobId = String(UUID().uuidString.prefix(8)).lowercased()
    let commandPreview = String(command.prefix(Limits.backgroundCommandPreview))
    jobs[jobId] = BackgroundJob(
      id: jobId, command: command, commandPreview: commandPreview, status: .running
    )

    let task = Task {
      let status: BackgroundJobStatus
      let output: String

      do {
        let result = try await self.executor.execute(command, timeout: timeout)

        if result.exitCode != 0 {
          status = .error
        } else {
          status = .completed
        }

        output = result.formatted
      } catch ShellExecutorError.timeout {
        status = .timeout
        output = "Error: Timeout (\(Int(timeout))s)"
      } catch {
        status = .error
        output = "Error: \(error)"
      }

      self.complete(jobId: jobId, status: status, output: output)
    }
    runningTasks[jobId] = task

    return "Background job \(jobId) started: \(commandPreview)"
  }

  public func check(jobId: String?) -> String {
    if let jobId {
      guard let job = jobs[jobId] else {
        return "Error: Unknown job \(jobId)"
      }

      return "[\(job.status.rawValue)] \(job.commandPreview)\n\(job.result ?? "(running)")"
    }

    guard !jobs.isEmpty else {
      return "No background jobs."
    }

    return
      jobs
      .map { id, job in
        "\(id): [\(job.status.rawValue)] \(job.commandPreview)"
      }
      .joined(separator: "\n")
  }

  public func drainNotifications() -> [BackgroundNotification] {
    let result = notifications
    notifications.removeAll()
    return result
  }

  /// Wait for a specific background job to finish. Used for test determinism.
  /// Returns immediately if jobId is unknown or already completed (safe no-op).
  public func awaitCompletion(jobId: String) async {
    await runningTasks[jobId]?.value
  }

  private func complete(
    jobId: String,
    status: BackgroundJobStatus,
    output: String
  ) {
    jobs[jobId]?.status = status
    jobs[jobId]?.result = output

    notifications.append(
      BackgroundNotification(
        jobId: jobId,
        status: status,
        command: jobs[jobId]?.commandPreview ?? "",
        result: String(output.prefix(Limits.backgroundResultPreview))
      )
    )

    runningTasks.removeValue(forKey: jobId)
  }
}
