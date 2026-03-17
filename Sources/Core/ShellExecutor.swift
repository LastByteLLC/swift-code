@preconcurrency import Foundation

public struct ShellResult: Sendable {
  public let stdout: String
  public let stderr: String
  public let exitCode: Int32

  public var formatted: String {
    var output = stdout

    if !stderr.isEmpty {
      output += "\nSTDERR:\n\(stderr)"
    }

    if exitCode != 0 {
      output += "\n[exit code: \(exitCode)]"
    }

    if output.count > Limits.maxOutputSize {
      output = String(output.prefix(Limits.maxOutputSize))
    }

    return output.isEmpty ? "(no output)" : output
  }
}

public enum ShellExecutorError: Error, Equatable {
  case blockedCommand(String)
  case timeout(seconds: Int)
}

public struct ShellExecutor: Sendable {
  private static let dangerousPatterns = [
    "rm -rf /", "sudo", "shutdown", "reboot", "> /dev/"
  ]

  public let workingDirectory: String

  public init(workingDirectory: String = ".") {
    self.workingDirectory = workingDirectory
  }

  /// Run a shell command and capture stdout, stderr, and exit code.
  /// Optionally terminates the process via SIGTERM if the timeout deadline passes.
  public func execute(
    _ command: String,
    timeout: TimeInterval? = nil
  ) async throws -> ShellResult {
    if let matchedPattern = Self.dangerousPatterns.first(where: { command.contains($0) }) {
      throw ShellExecutorError.blockedCommand(matchedPattern)
    }

    let cwd = workingDirectory
    return try await Task.detached {
      let process = Process()
      let stdoutPipe = Pipe()
      let stderrPipe = Pipe()

      process.executableURL = URL(fileURLWithPath: "/bin/bash")
      process.arguments = ["-c", command]
      process.standardOutput = stdoutPipe
      process.standardError = stderrPipe
      process.currentDirectoryURL = URL(fileURLWithPath: cwd)

      try process.run()

      var timer: DispatchSourceTimer?
      if let timeout {
        let source = DispatchSource.makeTimerSource()
        source.schedule(deadline: .now() + timeout)
        source.setEventHandler {
          if process.isRunning {
            process.terminate()
          }
        }
        source.resume()
        timer = source
      }

      // Read pipe data BEFORE waitUntilExit() to avoid deadlock
      let stdoutData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
      let stderrData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()

      timer?.cancel()

      if let timeout {
        let wasTerminated =
          process.terminationReason == .uncaughtSignal && process.terminationStatus == SIGTERM
        if wasTerminated {
          throw ShellExecutorError.timeout(seconds: Int(timeout))
        }
      }

      return ShellResult(
        stdout: String(data: stdoutData, encoding: .utf8) ?? "",
        stderr: String(data: stderrData, encoding: .utf8) ?? "",
        exitCode: process.terminationStatus
      )
    }
    .value
  }
}
