// JuncoEval.swift — Test harness for evaluating junco quality
//
// Runs predefined scenarios against junco and checks:
// - Output contains/doesn't contain expected strings
// - LLM call count within budget
// - Token usage within budget
// - Files not unexpectedly modified
// - Success/failure matches expectation
//
// Usage: swift run JuncoEval [--scenario <name>] [--verbose]

import Foundation
import JuncoKit

@main
enum JuncoEval {
  static func main() async throws {
    let verbose = CommandLine.arguments.contains("--verbose") || CommandLine.arguments.contains("-v")
    let isEval = CommandLine.arguments.contains("--eval")
    // Resolve project root — walks up from cwd to find Package.swift
    let resolution = ProjectResolver.resolve(from: FileManager.default.currentDirectoryPath)
    let baseDir = resolution.path
    if resolution.wasAutoDetected {
      print("ℹ Using project root: \(baseDir)")
    }

    // Self-evaluation mode
    if isEval {
      let caseFilter = parseArg("--case")
      let includeDestructive = CommandLine.arguments.contains("--destructive")
      let reportPath = parseArg("--report")
      let splitRaw = parseArg("--split")
      let splitFilter: EvalSplit? = splitRaw.flatMap { EvalSplit(rawValue: $0) }
      if splitRaw != nil && splitFilter == nil {
        FileHandle.standardError.write(Data("Unknown --split value. Use: canary|search|holdout|holdout-final\n".utf8))
        Foundation.exit(2)
      }

      let harness = EvalHarness(workingDirectory: baseDir, verbose: verbose)
      let report = await harness.run(
        caseFilter: caseFilter,
        includeDestructive: includeDestructive,
        reportPath: reportPath,
        splitFilter: splitFilter
      )

      if verbose {
        print("\n" + report)
      }
      return
    }

    // Scenario mode (existing)
    let filterName = parseArg("--scenario")
    let scenariosPath = (baseDir as NSString).appendingPathComponent("fixtures/scenarios.json")

    guard let data = FileManager.default.contents(atPath: scenariosPath),
          let scenarios = try? JSONDecoder().decode([Scenario].self, from: data)
    else {
      print("ERROR: Cannot load fixtures/scenarios.json")
      Foundation.exit(1)
    }

    let filtered = filterName.map { name in scenarios.filter { $0.name == name } } ?? scenarios
    print("Running \(filtered.count) scenario(s)...\n")

    var passed = 0
    var failed = 0
    var totalTime: TimeInterval = 0

    for scenario in filtered {
      let result = await runScenario(scenario, baseDir: baseDir, verbose: verbose)
      totalTime += result.duration

      if result.passed {
        passed += 1
        print("  \u{2713} \(scenario.name) (\(String(format: "%.1fs", result.duration)), \(result.llmCalls) calls, ~\(result.tokens) tokens)")
      } else {
        failed += 1
        print("  \u{2717} \(scenario.name) (\(String(format: "%.1fs", result.duration)), \(result.llmCalls) calls)")
        for failure in result.failures {
          print("    - \(failure)")
        }
        if let output = result.outputPreview {
          print("    output: \(output)")
        }
      }
    }

    print("\n\(passed) passed, \(failed) failed (\(String(format: "%.1fs", totalTime)) total)")
    Foundation.exit(failed > 0 ? 1 : 0)
  }

  static func runScenario(_ scenario: Scenario, baseDir: String, verbose: Bool) async -> ScenarioResult {
    let dir: String
    if scenario.directory == "." {
      dir = baseDir
    } else {
      dir = (baseDir as NSString).appendingPathComponent(scenario.directory)
    }

    // Snapshot files before running
    let filesBefore = snapshotFiles(dir)

    let adapter = AFMAdapter()
    let orchestrator = Orchestrator(adapter: adapter, workingDirectory: dir)
    if verbose { await orchestrator.setVerbose(true) }

    let start = Date()
    var failures: [String] = []

    // Parse @-references from query
    let parser = InputParser(workingDirectory: dir)
    let parsed = parser.parse(scenario.query)
    let urlCtx: String? = nil

    do {
      let result = try await orchestrator.run(
        query: parsed.query,
        referencedFiles: parsed.referencedFiles,
        urlContext: urlCtx
      )

      let duration = Date().timeIntervalSince(start)
      let output = result.reflection.insight
      let llmCalls = result.memory.llmCalls
      let tokens = result.memory.totalTokensUsed

      // Check output_contains
      for expected in scenario.expect.outputContains ?? [] {
        if !output.lowercased().contains(expected.lowercased()) {
          failures.append("output missing '\(expected)'")
        }
      }

      // Check output_not_contains
      for forbidden in scenario.expect.outputNotContains ?? [] {
        if output.lowercased().contains(forbidden.lowercased()) {
          failures.append("output contains forbidden '\(forbidden)'")
        }
      }

      // Check LLM calls
      if let maxCalls = scenario.expect.maxLLMCalls, llmCalls > maxCalls {
        failures.append("LLM calls \(llmCalls) > max \(maxCalls)")
      }

      // Check tokens
      if let maxTokens = scenario.expect.maxTokens, tokens > maxTokens {
        failures.append("tokens \(tokens) > max \(maxTokens)")
      }

      // Check succeeded
      if let expectedSuccess = scenario.expect.succeeded, result.reflection.succeeded != expectedSuccess {
        failures.append("succeeded=\(result.reflection.succeeded), expected=\(expectedSuccess)")
      }

      // Check files_modified
      if let maxModified = scenario.expect.filesModified {
        let filesAfter = snapshotFiles(dir)
        let modified = filesAfter.filter { path, hash in filesBefore[path] != hash }.count
        let created = filesAfter.count - filesBefore.count
        let totalChanges = modified + max(0, created)
        if totalChanges > maxModified {
          failures.append("files changed: \(totalChanges) > max \(maxModified)")
        }
      }

      let preview = String(output.prefix(200))
      return ScenarioResult(
        passed: failures.isEmpty,
        failures: failures,
        duration: duration,
        llmCalls: llmCalls,
        tokens: tokens,
        outputPreview: failures.isEmpty ? nil : preview
      )
    } catch {
      let duration = Date().timeIntervalSince(start)
      return ScenarioResult(
        passed: false,
        failures: ["threw: \(error)"],
        duration: duration,
        llmCalls: 0,
        tokens: 0,
        outputPreview: "\(error)"
      )
    }
  }

  static func snapshotFiles(_ dir: String) -> [String: Int] {
    var result: [String: Int] = [:]
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(atPath: dir) else { return result }
    while let path = enumerator.nextObject() as? String {
      if path.hasPrefix(".build") || path.hasPrefix(".junco") || path.hasPrefix(".git") {
        enumerator.skipDescendants()
        continue
      }
      let full = (dir as NSString).appendingPathComponent(path)
      if let data = fm.contents(atPath: full) {
        result[path] = data.hashValue
      }
    }
    return result
  }

  static func parseArg(_ flag: String) -> String? {
    guard let idx = CommandLine.arguments.firstIndex(of: flag),
          idx + 1 < CommandLine.arguments.count
    else { return nil }
    return CommandLine.arguments[idx + 1]
  }
}

// MARK: - Scenario Types

struct Scenario: Codable {
  let name: String
  let description: String
  let directory: String
  let query: String
  let expect: Expectations
}

struct Expectations: Codable {
  let outputContains: [String]?
  let outputNotContains: [String]?
  let maxLLMCalls: Int?
  let maxTokens: Int?
  let succeeded: Bool?
  let filesModified: Int?

  enum CodingKeys: String, CodingKey {
    case outputContains = "output_contains"
    case outputNotContains = "output_not_contains"
    case maxLLMCalls = "max_llm_calls"
    case maxTokens = "max_tokens"
    case succeeded
    case filesModified = "files_modified"
  }
}

struct ScenarioResult {
  let passed: Bool
  let failures: [String]
  let duration: TimeInterval
  let llmCalls: Int
  let tokens: Int
  let outputPreview: String?
}
