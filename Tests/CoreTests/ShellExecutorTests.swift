import Foundation
import Testing

@testable import Core

// MARK: - ShellResult.formatted

@Suite("ShellResult.formatted")
struct ShellResultFormattedTests {
  @Test func stdoutOnly() {
    let result = ShellResult(stdout: "hello\n", stderr: "", exitCode: 0)
    #expect(result.formatted == "hello\n")
  }

  @Test func includesStderr() {
    let result = ShellResult(stdout: "out", stderr: "err", exitCode: 0)
    #expect(result.formatted.contains("STDERR:"))
    #expect(result.formatted.contains("err"))
  }

  @Test func includesExitCode() {
    let result = ShellResult(stdout: "out", stderr: "", exitCode: 1)
    #expect(result.formatted.contains("[exit code: 1]"))
  }

  @Test func emptyOutputReturnsNoOutput() {
    let result = ShellResult(stdout: "", stderr: "", exitCode: 0)
    #expect(result.formatted == "(no output)")
  }

  @Test func truncatesLargeOutput() {
    let large = String(repeating: "x", count: 60_000)
    let result = ShellResult(stdout: large, stderr: "", exitCode: 0)
    #expect(result.formatted.count == Limits.maxOutputSize)
  }
}

// MARK: - Dangerous command blocking

@Suite("ShellExecutor dangerous command blocking")
struct DangerousCommandTests {
  @Test(arguments: ["sudo rm -rf /tmp/test", "rm -rf /", "shutdown -h now"])
  func blocksDangerousCommands(command: String) async {
    await #expect(throws: ShellExecutorError.self) {
      try await ShellExecutor().execute(command)
    }
  }

  @Test func allowsSafeCommands() async throws {
    let executor = ShellExecutor()
    let result = try await executor.execute("echo safe")
    #expect(result.exitCode == 0)
    #expect(result.stdout.contains("safe"))
  }
}

// MARK: - Timeout support

@Suite("ShellExecutor timeout")
struct ShellExecutorTimeoutTests {
  @Test func normalExecutionWithTimeout() async throws {
    let executor = ShellExecutor()
    let result = try await executor.execute("echo hello", timeout: 5.0)
    #expect(result.exitCode == 0)
    #expect(result.stdout.contains("hello"))
  }

  @Test(.timeLimit(.minutes(1)))
  func timeoutFiresForLongRunningCommand() async {
    await #expect(throws: ShellExecutorError.self) {
      try await ShellExecutor().execute("sleep 10", timeout: 0.5)
    }
  }

  @Test(.timeLimit(.minutes(1)))
  func timeoutThrowsCorrectError() async {
    await #expect(throws: ShellExecutorError.timeout(seconds: 1)) {
      try await ShellExecutor().execute("sleep 10", timeout: 1.0)
    }
  }
}
