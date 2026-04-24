// CandidateGenerator.swift — Multi-sample generation with compile-select
//
// Generates N code candidates at temperature > 0, compiles each with
// `swiftc -typecheck`, and returns the first that passes. Falls back to
// the candidate with fewest compiler errors.
//
// Exploits model non-determinism: with 50-70% per-attempt success,
// 3 attempts yields 87-97% overall success rate.

import Foundation

/// Result of evaluating a single candidate.
public struct CandidateResult: Sendable {
  public let code: String
  public let errorCount: Int
  public let errors: [String]
  public let compiled: Bool

  public init(code: String, errorCount: Int, errors: [String], compiled: Bool) {
    self.code = code
    self.errorCount = errorCount
    self.errors = errors
    self.compiled = compiled
  }
}

/// Generates multiple code candidates and selects the best via compilation.
public struct CandidateGenerator: Sendable {
  private let adapter: any LLMAdapter
  private let shell: SafeShell
  private let candidateCount: Int
  private let temperature: Double

  /// Create a candidate generator.
  /// - Parameters:
  ///   - adapter: LLM backend for generation.
  ///   - shell: Shell for running swiftc.
  ///   - candidateCount: Number of candidates to generate (default: 3).
  ///   - temperature: Sampling temperature for diversity (default: 0.8).
  public init(
    adapter: any LLMAdapter,
    shell: SafeShell,
    candidateCount: Int = 3,
    temperature: Double = 0.8
  ) {
    self.adapter = adapter
    self.shell = shell
    self.candidateCount = candidateCount
    self.temperature = temperature
  }

  /// Generate code candidates, compile-check each, return the best.
  /// - Parameters:
  ///   - prompt: The generation prompt.
  ///   - system: System prompt.
  ///   - type: The @Generable type to decode into.
  ///   - filePath: Target file path (used for swiftc type-checking).
  ///   - extract: Closure to extract the code string from the decoded type.
  /// - Returns: The best candidate result and its decoded value.
  public func generate<T: GenerableContent>(
    prompt: String,
    system: String?,
    as type: T.Type,
    filePath: String,
    extract: @Sendable (T) -> String
  ) async throws -> (value: T, result: CandidateResult) {
    // Generate candidates sequentially (on-device model is single-threaded).
    // Slot 0 is greedy (deterministic floor); slot 1+ uses random + the configured
    // temperature, giving the caller a reproducible candidate plus diversified alternates.
    var candidates: [(T, CandidateResult)] = []
    var lastError: (any Error)?

    for index in 0..<candidateCount {
      let options = GenerationProfile.candidate(index: index, temperature: temperature).options()
      do {
        let value = try await adapter.generateStructured(
          prompt: prompt, system: system, as: type, options: options
        )
        let code = extract(value)
        // AFM occasionally emits an empty string under greedy structured decoding
        // (observed 45s 0-byte responses on simple create-hello prompts). Treat as
        // a failed candidate so the loop can try the next slot instead of feeding
        // an empty file into downstream CVF/fix paths.
        if code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
          lastError = LLMError.generationFailed("empty candidate output at slot \(index)")
          continue
        }
        let result = await evaluate(code: code, filePath: filePath)
        candidates.append((value, result))

        // Short-circuit: if it compiles, return immediately
        if result.compiled {
          return (value, result)
        }
      } catch {
        // Deserialization failure — count as a failed candidate, keep trying
        lastError = error
        continue
      }
    }

    // No candidate compiled — pick the one with fewest errors
    if let best = candidates.min(by: { $0.1.errorCount < $1.1.errorCount }) {
      return best
    }

    // All candidates failed to even deserialize
    throw lastError ?? LLMError.generationFailed(
      "CandidateGenerator: all \(candidateCount) candidates failed"
    )
  }

  /// Evaluate a single code candidate by running `swiftc -typecheck`.
  public func evaluate(code: String, filePath: String) async -> CandidateResult {
    // Write to a temp file for compilation
    let tempDir = NSTemporaryDirectory()
    let fileName = (filePath as NSString).lastPathComponent
    let tempPath = (tempDir as NSString).appendingPathComponent("junco_candidate_\(UUID().uuidString)_\(fileName)")

    defer { try? FileManager.default.removeItem(atPath: tempPath) }

    do {
      try code.write(toFile: tempPath, atomically: true, encoding: .utf8)
    } catch {
      return CandidateResult(code: code, errorCount: 1, errors: ["Failed to write temp file"], compiled: false)
    }

    // Run swiftc -typecheck (syntax + type checking, no codegen)
    let command = "swiftc -typecheck \(tempPath) 2>&1"
    do {
      let result = try await shell.execute(command, timeout: Config.bashTimeout)
      let combined = result.stdout + result.stderr
      let errorLines = combined.components(separatedBy: "\n")
        .filter { $0.contains("error:") }

      return CandidateResult(
        code: code,
        errorCount: errorLines.count,
        errors: Array(errorLines.prefix(5)),
        compiled: errorLines.isEmpty && result.exitCode == 0
      )
    } catch {
      // Shell timeout or other failure — treat as non-compiling
      return CandidateResult(
        code: code,
        errorCount: 999,
        errors: ["swiftc timed out or failed: \(error)"],
        compiled: false
      )
    }
  }

  /// Evaluate code and, if it fails, enrich the error with correct API signatures.
  /// Uses the APISurfaceProvider for runtime discovery (swiftinterface → LSP → static fallback).
  public func evaluateAndSuggestFix(
    code: String,
    filePath: String,
    apiProvider: any APISurfaceProvider
  ) async -> (result: CandidateResult, fixHints: [String]) {
    let result = await evaluate(code: code, filePath: filePath)
    guard !result.compiled else { return (result, []) }

    var hints: [String] = []
    for errorLine in result.errors {
      if let hint = await apiProvider.lookupFix(compilerError: errorLine) {
        hints.append(hint)
      }
    }
    return (result, hints)
  }

  /// Legacy overload for backward compatibility with SignatureIndex.
  public func evaluateAndSuggestFix(
    code: String,
    filePath: String,
    signatureIndex: SignatureIndex
  ) async -> (result: CandidateResult, fixHints: [String]) {
    let result = await evaluate(code: code, filePath: filePath)
    guard !result.compiled else { return (result, []) }

    var hints: [String] = []
    for errorLine in result.errors {
      if let hint = signatureIndex.lookup(compilerError: errorLine) {
        hints.append(hint)
      }
    }
    return (result, hints)
  }
}
