// SwiftValidator.swift — Validate generated Swift code before writing to disk
//
// Runs `swiftc -typecheck` for semantic validation (~0.5s).
// Falls back to `swiftc -parse` (syntax only) if typecheck times out (10s).
// Integrated in the create/write pipeline via ValidatorRegistry.

import Foundation

/// Validates Swift source code using the compiler.
public struct SwiftValidator: CodeValidator, Sendable {
  public var supportedExtensions: Set<String> { ["swift"] }

  /// CodeValidator conformance — delegates to feedbackForLLM.
  public func validate(code: String, filePath: String) -> String? {
    feedbackForLLM(code: code, filePath: filePath)
  }

  /// Returns nil if code is valid Swift, or an error description for LLM feedback.
  public func feedbackForLLM(code: String, filePath: String) -> String? {
    guard filePath.hasSuffix(".swift") else { return nil }
    guard !code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
      return "Swift error: empty file content."
    }

    let tmp = NSTemporaryDirectory() + "junco-swiftcheck-\(UUID().uuidString).swift"
    defer { try? FileManager.default.removeItem(atPath: tmp) }

    do {
      try code.write(toFile: tmp, atomically: true, encoding: .utf8)
    } catch {
      return nil  // Can't validate — don't block the write
    }

    // Try -typecheck first (catches semantic errors like redundant conformance).
    // If it times out (10s), fall back to -parse (syntax only, much faster).
    if let result = runCompiler(args: ["-typecheck", "-suppress-warnings", tmp], timeout: 10) {
      return formatErrors(result, tempPath: tmp, filePath: filePath)
    }

    // Fallback: -parse only (fast, syntax-only)
    if let result = runCompiler(args: ["-parse", "-suppress-warnings", tmp], timeout: 10) {
      return formatErrors(result, tempPath: tmp, filePath: filePath)
    }

    return nil  // Both timed out or compiler unavailable
  }

  /// Run swiftc with given arguments. Returns stderr if exit code != 0, nil if clean or error.
  private func runCompiler(args: [String], timeout: TimeInterval) -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["swiftc"] + args
    let errPipe = Pipe()
    process.standardError = errPipe
    process.standardOutput = FileHandle.nullDevice

    do {
      try process.run()
    } catch {
      return nil  // Compiler not available
    }

    // Timeout enforcement: terminate if still running after limit
    let timer = DispatchSource.makeTimerSource(queue: .global())
    timer.schedule(deadline: .now() + timeout)
    timer.setEventHandler { process.terminate() }
    timer.resume()

    process.waitUntilExit()
    timer.cancel()

    // If terminated by timeout, signal failure so caller falls back
    guard process.terminationReason == .exit else { return nil }
    guard process.terminationStatus != 0 else { return nil }

    return String(data: errPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
  }

  /// Format compiler errors into concise LLM feedback.
  private func formatErrors(_ stderr: String, tempPath: String, filePath: String) -> String? {
    let errors = stderr
      .components(separatedBy: "\n")
      .filter { $0.contains("error:") }
      .prefix(3)  // Keep it concise for 4K context
      .map { $0.replacingOccurrences(of: tempPath, with: filePath) }
      .joined(separator: "\n")

    guard !errors.isEmpty else { return nil }
    return "Swift syntax error in generated code: \(errors). Fix and regenerate."
  }
}
