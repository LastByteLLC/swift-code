// SwiftValidator.swift — Validate generated Swift code before writing to disk
//
// Runs `swiftc -parse` for fast syntax checking (~0.3s).
// Integrated alongside JSCValidator in the create/write pipeline.

import Foundation

/// Validates Swift source code using the compiler's parser.
public struct SwiftValidator: Sendable {

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

    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/xcrun")
    process.arguments = ["swiftc", "-parse", "-suppress-warnings", tmp]
    let errPipe = Pipe()
    process.standardError = errPipe
    process.standardOutput = FileHandle.nullDevice

    do {
      try process.run()
      process.waitUntilExit()
    } catch {
      return nil  // Compiler not available — don't block
    }

    guard process.terminationStatus != 0 else { return nil }

    let stderr = String(
      data: errPipe.fileHandleForReading.readDataToEndOfFile(),
      encoding: .utf8
    ) ?? ""

    // Extract error lines, replace temp path with the target filename
    let errors = stderr
      .components(separatedBy: "\n")
      .filter { $0.contains("error:") }
      .prefix(3)  // Keep it concise for 4K context
      .map { $0.replacingOccurrences(of: tmp, with: filePath) }
      .joined(separator: "\n")

    guard !errors.isEmpty else { return nil }
    return "Swift syntax error in generated code: \(errors). Fix and regenerate."
  }
}
