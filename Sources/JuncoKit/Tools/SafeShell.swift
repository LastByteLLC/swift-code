// SafeShell.swift — Sandboxed shell execution with safety checks and timeouts
//
// Three layers of defense:
// 1. Pattern blocklist (fast, catches obvious dangerous commands)
// 2. Structural bypass detection (catches encoded/piped/eval attacks)
// 3. sandbox-exec (OS-level restriction to working directory)

import Foundation

/// Result of a shell command execution.
public struct ShellResult: Sendable {
  public let stdout: String
  public let stderr: String
  public let exitCode: Int32

  /// Formatted output suitable for LLM consumption, truncated to token budget.
  public func formatted(maxTokens: Int = 400) -> String {
    var output = stdout
    if !stderr.isEmpty {
      output += (output.isEmpty ? "" : "\n") + "STDERR: \(stderr)"
    }
    if exitCode != 0 {
      output += "\n[exit code: \(exitCode)]"
    }
    if output.isEmpty { return "(no output)" }
    return TokenBudget.truncate(output, toTokens: maxTokens)
  }
}

/// Errors from shell execution.
public enum ShellError: Error, Sendable, Equatable {
  case blockedCommand(String)
  case timeout(seconds: Int)
  case executionFailed(String)
}

/// Safe shell executor with dangerous command blocking, bypass detection,
/// OS-level sandboxing, and timeout support.
public struct SafeShell: Sendable {
  public let workingDirectory: String
  public let defaultTimeout: TimeInterval

  public init(workingDirectory: String, defaultTimeout: TimeInterval = Config.bashTimeout) {
    self.workingDirectory = workingDirectory
    self.defaultTimeout = defaultTimeout
  }

  /// Execute a shell command with safety checks, sandbox, and timeout.
  public func execute(
    _ command: String,
    timeout: TimeInterval? = nil
  ) async throws -> ShellResult {
    // Layer 1: Pattern blocklist (fast reject)
    let lowerCmd = command.lowercased()
    if let match = Config.blockedShellPatterns.first(where: { lowerCmd.contains($0) }) {
      throw ShellError.blockedCommand(match)
    }

    // Layer 2: Structural bypass detection
    if let bypass = Self.detectBypass(command) {
      throw ShellError.blockedCommand(bypass)
    }

    let effectiveTimeout = timeout ?? defaultTimeout
    let cwd = workingDirectory

    return try await Task.detached {
      let process = Process()
      let stdoutPipe = Pipe()
      let stderrPipe = Pipe()

      // Layer 3: sandbox-exec (OS-level file system restriction)
      if Config.sandboxEnabled {
        process.executableURL = URL(fileURLWithPath: "/usr/bin/sandbox-exec")
        process.arguments = ["-p", Self.sandboxProfile(workingDirectory: cwd), "/bin/bash", "-c", command]
      } else {
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", command]
      }

      process.standardOutput = stdoutPipe
      process.standardError = stderrPipe
      process.currentDirectoryURL = URL(fileURLWithPath: cwd)

      try process.run()

      // Timeout via SIGINT
      let timer = DispatchSource.makeTimerSource()
      timer.schedule(deadline: .now() + effectiveTimeout)
      timer.setEventHandler {
        if process.isRunning { process.interrupt() }
      }
      timer.resume()

      // Read pipes before wait to avoid deadlock
      let outData = stdoutPipe.fileHandleForReading.readDataToEndOfFile()
      let errData = stderrPipe.fileHandleForReading.readDataToEndOfFile()
      process.waitUntilExit()

      timer.cancel()

      return ShellResult(
        stdout: String(data: outData, encoding: .utf8) ?? "",
        stderr: String(data: errData, encoding: .utf8) ?? "",
        exitCode: process.terminationStatus
      )
    }.value
  }

  // MARK: - Bypass Detection

  /// Detect common patterns used to bypass simple blocklists.
  /// Returns a human-readable reason if a bypass attempt is detected, nil if clean.
  public static func detectBypass(_ command: String) -> String? {
    let lower = command.lowercased()

    // Encoded command piped to shell
    if lower.contains("base64") && (lower.contains("| bash") || lower.contains("| sh") || lower.contains("| zsh")) {
      return "Encoded command piped to shell"
    }

    // Remote code execution: curl/wget piped to shell
    if (lower.contains("curl ") || lower.contains("wget ")) &&
       (lower.contains("| bash") || lower.contains("| sh") || lower.contains("| zsh")) {
      return "Remote code execution pattern"
    }

    // Dynamic execution via eval/exec/source
    // Allow "exec" as part of other words (e.g., "executable"), block standalone
    let evalPatterns = ["eval ", "eval\t", "eval(", " exec ", "\texec "]
    for pattern in evalPatterns {
      if lower.contains(pattern) {
        return "Dynamic execution via eval/exec"
      }
    }

    // Hex/octal encoding used to hide commands
    if lower.contains("\\x") && (lower.contains("echo") || lower.contains("printf")) &&
       (lower.contains("| bash") || lower.contains("| sh")) {
      return "Hex-encoded command piped to shell"
    }

    // Python/perl/ruby one-liners executing system commands
    if (lower.contains("python") || lower.contains("perl") || lower.contains("ruby")) &&
       (lower.contains("os.system") || lower.contains("subprocess") || lower.contains("exec(")) {
      return "Script-language command execution"
    }

    return nil
  }

  // MARK: - Sandbox Profile

  /// Generate a macOS sandbox-exec profile that restricts file WRITES
  /// to the working directory + temp dirs. Allows reads broadly (needed for
  /// toolchains, SDKs, etc.) but blocks writes to sensitive system paths.
  /// Uses allow-default with targeted denies — safer for development tools
  /// than deny-default which blocks too many system operations.
  public static func sandboxProfile(workingDirectory: String) -> String {
    """
    (version 1)
    (allow default)
    (deny file-write* (subpath "/Users")
      (require-not (subpath "\(workingDirectory)"))
    )
    (deny file-write* (subpath "/System"))
    (deny file-write* (subpath "/Library"))
    (deny file-write* (subpath "/usr"))
    (deny file-write* (subpath "/bin"))
    (deny file-write* (subpath "/sbin"))
    (deny file-write* (subpath "/etc"))
    (deny file-write* (subpath "/opt"))
    (allow file-write* (subpath "\(workingDirectory)"))
    """
  }
}
