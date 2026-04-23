// junco-meta — Meta-harness for the junco agent.
//
// Subcommands:
//   canary                       Run the canary split; non-zero exit on any failure.
//   eval --candidate <id>        Run the search split with a candidate's overlays.
//   list                         List all candidates with status.
//   show <id>                    Print a candidate's meta + summary.
//   frontier                     Print the current Pareto frontier.
//
// Filesystem layout: .junco/meta/
//   candidates/<id>/meta.json       — config + prompt overrides + rationale
//   candidates/<id>/summary.json    — aggregated eval results
//   candidates/<id>/traces/         — per-case trace.jsonl (optional)
//   baseline.json                   — Phase-0 reference metrics
//   frontier.json                   — current non-dominated candidate ids
//   history.md                      — narrative log for the proposer
//   STOP                            — presence halts further iterations

import Foundation

// MARK: - Filesystem paths

enum MetaFS {
  static let projectDir = ".junco/meta"
  static var candidatesDir: String { "\(projectDir)/candidates" }
  static var baselinePath: String { "\(projectDir)/baseline.json" }
  static var frontierPath: String { "\(projectDir)/frontier.json" }
  static var historyPath: String { "\(projectDir)/history.md" }
  static var stopPath: String { "\(projectDir)/STOP" }

  static func candidateDir(_ id: String) -> String { "\(candidatesDir)/\(id)" }
  static func metaPath(_ id: String) -> String { "\(candidateDir(id))/meta.json" }
  static func summaryPath(_ id: String) -> String { "\(candidateDir(id))/summary.json" }
  static func traceDir(_ id: String) -> String { "\(candidateDir(id))/traces" }

  static func ensure(_ path: String) {
    try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
  }
}

// MARK: - Candidate metadata

struct CandidateMeta: Codable {
  let id: String
  let createdAt: String
  var parent: String?
  var mutationClass: String          // "config-only" | "prompt-template" | "swift-code"
  var rationale: String
  var metaConfig: [String: AnyJSON]  // pass-through overlay
  var promptOverrides: [String: AnyJSON]
  /// For swift-code mutations: map from repo-relative path → full file content to replace.
  /// Only paths in Self.swiftCodeAllowlist are accepted; others fail the candidate.
  var swiftCodeFiles: [String: String]?
}

/// Whitelist of files a swift-code mutation may modify. Expand cautiously.
let swiftCodeAllowlist: Set<String> = [
  "Sources/JuncoKit/Agent/Orchestrator.swift",
  "Sources/JuncoKit/Agent/Prompts.swift",
  "Sources/JuncoKit/Agent/TaskResolver.swift"
]

/// Minimal dynamic JSON value for pass-through (candidate metaConfig / promptOverrides).
enum AnyJSON: Codable {
  case string(String)
  case int(Int)
  case double(Double)
  case bool(Bool)
  case null
  case object([String: AnyJSON])
  case array([AnyJSON])

  init(from decoder: Decoder) throws {
    let c = try decoder.singleValueContainer()
    if c.decodeNil() { self = .null; return }
    if let v = try? c.decode(Bool.self) { self = .bool(v); return }
    if let v = try? c.decode(Int.self) { self = .int(v); return }
    if let v = try? c.decode(Double.self) { self = .double(v); return }
    if let v = try? c.decode(String.self) { self = .string(v); return }
    if let v = try? c.decode([AnyJSON].self) { self = .array(v); return }
    if let v = try? c.decode([String: AnyJSON].self) { self = .object(v); return }
    throw DecodingError.dataCorruptedError(in: c, debugDescription: "Unknown AnyJSON")
  }

  func encode(to encoder: Encoder) throws {
    var c = encoder.singleValueContainer()
    switch self {
    case .null: try c.encodeNil()
    case .bool(let v): try c.encode(v)
    case .int(let v): try c.encode(v)
    case .double(let v): try c.encode(v)
    case .string(let v): try c.encode(v)
    case .array(let v): try c.encode(v)
    case .object(let v): try c.encode(v)
    }
  }
}

// MARK: - Subprocess runner

struct EvalInvocation {
  let split: String
  let metaConfigPath: String?
  let promptOverridesPath: String?
  let summaryPath: String
  let traceDir: String?
  let reportPath: String
  var caseFilter: String?
  /// Per-run hard timeout in seconds. Sends SIGTERM then SIGKILL if exceeded.
  var timeoutSec: Int = 900  // 15 min default — protection against CVF-loop hangs.

  func run() -> Int32 {
    let proc = Process()
    // Use the current session's debug binary directly to avoid a SwiftPM build-planning pass
    // per invocation (which also contends for `.build/` locks with any concurrent `swift run`).
    // DO NOT prefer release — a stale release binary from a prior session can silently run old
    // code against current sources (e.g., a LoRA-era binary against a LoRA-free tree).
    // If the debug binary is missing, fall back to `swift run -q` which forces a build.
    let fm = FileManager.default
    let cwd = fm.currentDirectoryPath
    let debugBin = "\(cwd)/.build/arm64-apple-macosx/debug/junco-eval"
    if fm.fileExists(atPath: debugBin) {
      proc.executableURL = URL(fileURLWithPath: debugBin)
    } else {
      proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    }
    let usingSwiftRun = proc.executableURL?.path == "/usr/bin/env"
    var args = usingSwiftRun
      ? ["swift", "run", "-q", "junco-eval", "--eval", "--split", split, "--report", reportPath]
      : ["--eval", "--split", split, "--report", reportPath]
    if let cf = caseFilter { args += ["--case", cf] }
    proc.arguments = args

    var env = ProcessInfo.processInfo.environment
    if let p = metaConfigPath { env["META_CONFIG_JSON"] = p }
    if let p = promptOverridesPath { env["PROMPT_OVERRIDES_JSON"] = p }
    env["JUNCO_SUMMARY_JSON"] = summaryPath
    if let d = traceDir { env["JUNCO_TRACE_DIR"] = d }
    // LoRA has been removed from the codebase; no env gate needed.
    proc.environment = env

    let killer = DispatchWorkItem { [proc] in
      if proc.isRunning {
        FileHandle.standardError.write(Data("[junco-meta] Timeout after \(self.timeoutSec)s — terminating eval.\n".utf8))
        proc.terminate()
        DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(30)) { [proc] in
          if proc.isRunning {
            kill(proc.processIdentifier, SIGKILL)
          }
        }
      }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(timeoutSec), execute: killer)

    do {
      try proc.run()
      proc.waitUntilExit()
      killer.cancel()
      return proc.terminationStatus
    } catch {
      killer.cancel()
      FileHandle.standardError.write(Data("[junco-meta] Failed to run junco-eval: \(error)\n".utf8))
      return 127
    }
  }
}

// MARK: - Helpers

func readJSON<T: Decodable>(_ type: T.Type, path: String) -> T? {
  guard let data = FileManager.default.contents(atPath: path) else { return nil }
  return try? JSONDecoder().decode(type, from: data)
}

func writeJSON<T: Encodable>(_ value: T, path: String) throws {
  let dir = (path as NSString).deletingLastPathComponent
  try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
  let encoder = JSONEncoder()
  encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
  let data = try encoder.encode(value)
  try data.write(to: URL(fileURLWithPath: path))
}

func extractTempFile(_ anyJSON: [String: AnyJSON], prefix: String) -> String? {
  if anyJSON.isEmpty { return nil }
  guard let data = try? JSONEncoder().encode(anyJSON) else { return nil }
  let tmpDir = FileManager.default.temporaryDirectory
  let url = tmpDir.appendingPathComponent("\(prefix)-\(UUID().uuidString).json")
  try? data.write(to: url)
  return url.path
}

// MARK: - Subcommand implementations

func runCanary() -> Int32 {
  MetaFS.ensure(MetaFS.projectDir)
  print("[junco-meta] Running canary split …")
  let inv = EvalInvocation(
    split: "canary",
    metaConfigPath: nil,
    promptOverridesPath: nil,
    summaryPath: "\(MetaFS.projectDir)/canary.summary.json",
    traceDir: nil,
    reportPath: "\(MetaFS.projectDir)/canary.report.md"
  )
  let rc = inv.run()
  guard rc == 0 else { return rc }

  // Check summary: any failure → non-zero exit
  struct Summary: Decodable { let succeeded: Int; let failed: Int; let caseCount: Int }
  guard let s = readJSON(Summary.self, path: inv.summaryPath) else {
    FileHandle.standardError.write(Data("[junco-meta] canary: no summary written\n".utf8))
    return 2
  }
  if s.failed > 0 {
    FileHandle.standardError.write(Data("[junco-meta] canary: \(s.failed)/\(s.caseCount) failed\n".utf8))
    return 3
  }
  print("[junco-meta] canary: \(s.succeeded)/\(s.caseCount) ✓")
  return 0
}

func runEval(candidateId: String, replicates: Int = 1, caseFilter: String? = nil, skipCanary: Bool = false) -> Int32 {
  let metaPath = MetaFS.metaPath(candidateId)
  guard let candidate = readJSON(CandidateMeta.self, path: metaPath) else {
    FileHandle.standardError.write(Data("[junco-meta] No meta.json at \(metaPath)\n".utf8))
    return 4
  }
  MetaFS.ensure(MetaFS.candidateDir(candidateId))

  // Auto-gate: canary must pass on the main repo before committing to a full eval.
  // Protects against harness regressions that would invalidate ALL candidate results.
  // (swift-code candidates run canary inside the worktree, not here — a broken worktree
  // fails the build gate first.)
  if !skipCanary && candidate.mutationClass != "swift-code" {
    print("[junco-meta] Pre-eval canary …")
    let canaryRC = runCanary()
    guard canaryRC == 0 else {
      FileHandle.standardError.write(Data(
        "[junco-meta] Canary failed — aborting eval. Re-run with --skip-canary to bypass.\n".utf8))
      return canaryRC
    }
  }

  if candidate.mutationClass == "swift-code" {
    return runSwiftCodeEval(candidate: candidate, replicates: replicates, caseFilter: caseFilter)
  }

  let metaCfgPath = extractTempFile(candidate.metaConfig, prefix: "metacfg")
  let promptOverPath = extractTempFile(candidate.promptOverrides, prefix: "prompts")

  print("[junco-meta] Evaluating candidate \(candidateId) (class: \(candidate.mutationClass)) replicates=\(replicates)")
  if !candidate.rationale.isEmpty { print("  rationale: \(candidate.rationale)") }

  let replicatesDir = "\(MetaFS.candidateDir(candidateId))/replicates"
  MetaFS.ensure(replicatesDir)

  var lastRC: Int32 = 0
  for n in 1...replicates {
    let traceDir = "\(MetaFS.candidateDir(candidateId))/traces-run\(n)"
    MetaFS.ensure(traceDir)
    let summaryPath = "\(replicatesDir)/run\(n).summary.json"
    let reportPath = "\(replicatesDir)/run\(n).report.md"
    print("\n[junco-meta] --- run \(n) of \(replicates) ---")
    let inv = EvalInvocation(
      split: "search",
      metaConfigPath: metaCfgPath,
      promptOverridesPath: promptOverPath,
      summaryPath: summaryPath,
      traceDir: traceDir,
      reportPath: reportPath,
      caseFilter: caseFilter
    )
    let rc = inv.run()
    if rc != 0 {
      FileHandle.standardError.write(Data("[junco-meta] run \(n) returned \(rc)\n".utf8))
    }
    lastRC = rc
  }

  aggregateReplicates(candidateId: candidateId, replicates: replicates)
  return lastRC
}

// MARK: - Swift-code candidates (git worktree isolation)

@discardableResult
func runCommand(_ args: [String], cwd: String? = nil, captureStderr: Bool = true) -> (rc: Int32, output: String) {
  // Redirect stdout+stderr to a temp file rather than a Pipe, because Pipe's buffer
  // (64KB on macOS) deadlocks when a verbose child (e.g., `swift build`) exceeds it
  // before we've called readDataToEndOfFile(). File redirection has no such limit.
  let proc = Process()
  proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
  proc.arguments = args
  if let cwd { proc.currentDirectoryURL = URL(fileURLWithPath: cwd) }
  let tmpURL = FileManager.default.temporaryDirectory
    .appendingPathComponent("junco-meta-\(UUID()).log")
  FileManager.default.createFile(atPath: tmpURL.path, contents: nil)
  guard let handle = try? FileHandle(forWritingTo: tmpURL) else {
    return (127, "tmp handle open failed")
  }
  proc.standardOutput = handle
  proc.standardError = captureStderr ? handle : FileHandle.standardError
  defer { try? FileManager.default.removeItem(at: tmpURL) }
  do {
    try proc.run()
    proc.waitUntilExit()
    try? handle.close()
  } catch {
    try? handle.close()
    return (127, "failed to spawn: \(error)")
  }
  let output: String
  if let data = try? Data(contentsOf: tmpURL) {
    output = String(data: data, encoding: .utf8) ?? ""
  } else {
    output = ""
  }
  return (proc.terminationStatus, output)
}

func runSwiftCodeEval(candidate: CandidateMeta, replicates: Int, caseFilter: String?) -> Int32 {
  // A swift-code candidate supplies its file overrides either inline via swiftCodeFiles
  // or by placing files under candidates/<id>/code/<rel-path>. Whichever is present wins.
  var files: [String: String] = candidate.swiftCodeFiles ?? [:]

  let codeDir = "\(MetaFS.candidateDir(candidate.id))/code"
  if FileManager.default.fileExists(atPath: codeDir) {
    let enumerator = FileManager.default.enumerator(atPath: codeDir)
    while let entry = enumerator?.nextObject() as? String {
      let abs = "\(codeDir)/\(entry)"
      var isDir: ObjCBool = false
      FileManager.default.fileExists(atPath: abs, isDirectory: &isDir)
      if isDir.boolValue { continue }
      if let content = try? String(contentsOfFile: abs, encoding: .utf8) {
        files[entry] = content
      }
    }
  }

  guard !files.isEmpty else {
    FileHandle.standardError.write(Data(
      "[junco-meta] swift-code class requires swiftCodeFiles or a code/ subdirectory\n".utf8))
    return 5
  }
  // Whitelist check — reject any path outside the allowlist.
  let disallowed = files.keys.filter { !swiftCodeAllowlist.contains($0) }
  if !disallowed.isEmpty {
    FileHandle.standardError.write(Data(
      "[junco-meta] Rejected — paths outside allowlist: \(disallowed.sorted().joined(separator: ", "))\n"
        .utf8))
    return 6
  }

  let worktreeRoot = "\(MetaFS.projectDir)/worktrees"
  MetaFS.ensure(worktreeRoot)
  let worktreePath = "\(worktreeRoot)/\(candidate.id)"

  // Clean any stale worktree from a previous failed run.
  _ = runCommand(["rm", "-rf", worktreePath])
  MetaFS.ensure(worktreePath)

  // Clone the full working-tree state (committed + uncommitted + untracked) via rsync.
  // We deliberately skip `git worktree add` — that checks out HEAD, which would miss
  // any uncommitted changes in the main tree. rsync captures the whole working state.
  print("[junco-meta] Cloning working tree to \(worktreePath)")
  let rsync = runCommand([
    "rsync", "-a",
    "--exclude=.git",
    "--exclude=.build",
    "--exclude=.junco/meta/worktrees",
    "--exclude=.junco/meta/candidates",
    "--exclude=/.junco/api_cache",
    "./", worktreePath + "/"
  ])
  guard rsync.rc == 0 else {
    FileHandle.standardError.write(Data("[junco-meta] rsync failed (rc=\(rsync.rc)): \(rsync.output)\n".utf8))
    return 7
  }

  // Apply the candidate's file overrides.
  for (rel, content) in files {
    let abs = "\(worktreePath)/\(rel)"
    print("  write \(rel) (\(content.count) bytes)")
    let dir = (abs as NSString).deletingLastPathComponent
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try? content.write(to: URL(fileURLWithPath: abs), atomically: true, encoding: .utf8)
  }

  // Gate: build must succeed in the worktree.
  print("[junco-meta] Building worktree …")
  let build = runCommand(["swift", "build", "-q"], cwd: worktreePath)
  if build.rc != 0 {
    FileHandle.standardError.write(Data("[junco-meta] Worktree build FAILED (rc=\(build.rc)):\n\(build.output)\n".utf8))
    _ = runCommand(["git", "worktree", "remove", "--force", worktreePath])
    return 8
  }
  print("[junco-meta] Worktree build OK")

  // Absolute paths for artifacts — we'll write into the main repo's .junco/meta so results
  // persist after worktree removal.
  let candidateDirAbs = FileManager.default.currentDirectoryPath + "/" + MetaFS.candidateDir(candidate.id)
  MetaFS.ensure(MetaFS.candidateDir(candidate.id))
  MetaFS.ensure("\(MetaFS.candidateDir(candidate.id))/replicates")

  let metaCfgPath = extractTempFile(candidate.metaConfig, prefix: "metacfg")
  let promptOverPath = extractTempFile(candidate.promptOverrides, prefix: "prompts")

  // Use the worktree's debug binary (built by the gate above). Never prefer release here
  // either — a stale release binary from a prior run of this same candidate id would shadow
  // the just-built code. If missing, fall back to swift-run.
  let fmInner = FileManager.default
  let wtDebug = "\(worktreePath)/.build/arm64-apple-macosx/debug/junco-eval"

  print("[junco-meta] Running eval(s) in worktree …")
  var lastRC: Int32 = 0
  for n in 1...replicates {
    let traceDir = "\(candidateDirAbs)/traces-run\(n)"
    let summaryPath = "\(candidateDirAbs)/replicates/run\(n).summary.json"
    let reportPath = "\(candidateDirAbs)/replicates/run\(n).report.md"
    MetaFS.ensure(traceDir)

    print("\n[junco-meta] --- run \(n) of \(replicates) (in worktree) ---")
    let proc = Process()
    if fmInner.fileExists(atPath: wtDebug) {
      proc.executableURL = URL(fileURLWithPath: wtDebug)
    } else {
      proc.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    }
    let usingSwiftRun = proc.executableURL?.path == "/usr/bin/env"
    var args = usingSwiftRun
      ? ["swift", "run", "-q", "junco-eval", "--eval", "--split", "search", "--report", reportPath]
      : ["--eval", "--split", "search", "--report", reportPath]
    if let cf = caseFilter { args += ["--case", cf] }
    proc.arguments = args
    proc.currentDirectoryURL = URL(fileURLWithPath: worktreePath)
    var env = ProcessInfo.processInfo.environment
    if let p = metaCfgPath { env["META_CONFIG_JSON"] = p }
    if let p = promptOverPath { env["PROMPT_OVERRIDES_JSON"] = p }
    env["JUNCO_SUMMARY_JSON"] = summaryPath
    env["JUNCO_TRACE_DIR"] = traceDir
    proc.environment = env

    // 15-min timeout per run
    let killer = DispatchWorkItem { [proc] in
      if proc.isRunning {
        FileHandle.standardError.write(Data("[junco-meta] Timeout — terminating worktree eval\n".utf8))
        proc.terminate()
      }
    }
    DispatchQueue.global().asyncAfter(deadline: .now() + .seconds(900), execute: killer)
    do {
      try proc.run()
      proc.waitUntilExit()
      killer.cancel()
      lastRC = proc.terminationStatus
    } catch {
      killer.cancel()
      FileHandle.standardError.write(Data("[junco-meta] run \(n) spawn failed: \(error)\n".utf8))
      lastRC = 127
    }
  }

  aggregateReplicates(candidateId: candidate.id, replicates: replicates)

  // Clean up worktree.
  print("[junco-meta] Removing worktree")
  _ = runCommand(["rm", "-rf", worktreePath])

  return lastRC
}

/// Read per-replicate summaries and write the aggregate summary.json (median durations, per-case success counts).
func aggregateReplicates(candidateId: String, replicates: Int) {
  let replicatesDir = "\(MetaFS.candidateDir(candidateId))/replicates"
  var runs: [Summary] = []
  for n in 1...replicates {
    if let s = readJSON(Summary.self, path: "\(replicatesDir)/run\(n).summary.json") {
      runs.append(s)
    }
  }
  guard !runs.isEmpty else { return }

  // For v1 aggregation: per-case success count across N runs; median duration per case.
  // Overall `successRate` = fraction of (case, run) pairs that succeeded.
  var caseSuccessCount: [String: Int] = [:]
  var caseDurations: [String: [Double]] = [:]
  var caseModeCorrect: [String: [Bool]] = [:]
  var totalLlmCalls = 0
  var totalTokens = 0
  var totalDuration = 0.0

  var caseRefSims: [String: [Double]] = [:]
  for run in runs {
    totalLlmCalls += run.totalLlmCalls
    totalTokens += run.totalTokens
    totalDuration += run.totalDurationSec
    for c in run.cases ?? [] {
      caseSuccessCount[c.name, default: 0] += c.didSucceed ? 1 : 0
      caseDurations[c.name, default: []].append(c.duration)
      if let mc = c.modeCorrect {
        caseModeCorrect[c.name, default: []].append(mc)
      }
      if let sim = c.referenceSimilarity {
        caseRefSims[c.name, default: []].append(sim)
      }
    }
  }

  let caseNames = Array(caseSuccessCount.keys).sorted()
  struct AggCase: Encodable {
    let name: String
    let succeededInAllRuns: Bool
    let successCount: Int
    let replicateCount: Int
    let medianDurationSeconds: Double
    let minDurationSeconds: Double
    let maxDurationSeconds: Double
    let highVariance: Bool
    let modeCorrectRate: Double?
    let medianReferenceSimilarity: Double?
  }
  var aggCases: [AggCase] = []
  var durations: [Double] = []
  for name in caseNames {
    let durs = caseDurations[name] ?? []
    let sortedDur = durs.sorted()
    let med = sortedDur.isEmpty ? 0 : sortedDur[sortedDur.count / 2]
    durations.append(med)
    let minD = sortedDur.first ?? 0
    let maxD = sortedDur.last ?? 0
    let highVar = maxD - minD > 10.0  // 10s delta → high variance flag
    let mcList = caseModeCorrect[name] ?? []
    let mcRate = mcList.isEmpty ? nil : Double(mcList.filter { $0 }.count) / Double(mcList.count)
    let simList = caseRefSims[name] ?? []
    let sortedSims = simList.sorted()
    let simMedian = sortedSims.isEmpty ? nil : sortedSims[sortedSims.count / 2]
    aggCases.append(AggCase(
      name: name,
      succeededInAllRuns: caseSuccessCount[name] == replicates,
      successCount: caseSuccessCount[name] ?? 0,
      replicateCount: replicates,
      medianDurationSeconds: med,
      minDurationSeconds: minD,
      maxDurationSeconds: maxD,
      highVariance: highVar,
      modeCorrectRate: mcRate,
      medianReferenceSimilarity: simMedian
    ))
  }

  let allInAllRuns = aggCases.filter { $0.succeededInAllRuns }.count
  let totalCaseRuns = caseNames.count * replicates
  let totalSucc = caseSuccessCount.values.reduce(0, +)
  let sortedDur = durations.sorted()
  let median = sortedDur.isEmpty ? 0 : sortedDur[sortedDur.count / 2]
  let p90 = sortedDur.isEmpty ? 0 : sortedDur[min(sortedDur.count - 1, Int(Double(sortedDur.count) * 0.9))]
  let mean = durations.isEmpty ? 0 : durations.reduce(0, +) / Double(durations.count)

  // Build the summary.json that frontier/compare consumes. Keep schema compatible.
  struct AggSummary: Encodable {
    let replicateCount: Int
    let caseCount: Int
    let succeeded: Int  // cases that passed IN ALL RUNS
    let failed: Int
    let successRate: Double  // fraction over all (case, run) pairs
    let stableSuccessRate: Double  // fraction of cases that pass in every run
    let totalLlmCalls: Int
    let totalTokens: Int
    let totalDurationSec: Double
    let meanDurationSec: Double
    let medianDurationSec: Double
    let p90DurationSec: Double
    let modeCorrectCount: Int
    let modeExpectedCount: Int
    let highVarianceCaseCount: Int
    let referenceScoredCount: Int
    let meanReferenceSimilarity: Double?
    let minReferenceSimilarity: Double?
    let cases: [AggCase]
  }
  let modeExpected = aggCases.filter { $0.modeCorrectRate != nil }.count
  let modeCorrect = aggCases.compactMap { $0.modeCorrectRate }.filter { $0 >= 1.0 }.count
  let scoredCases = aggCases.compactMap { $0.medianReferenceSimilarity }
  let meanRef = scoredCases.isEmpty ? nil : scoredCases.reduce(0, +) / Double(scoredCases.count)
  let minRef = scoredCases.min()
  let agg = AggSummary(
    replicateCount: replicates,
    caseCount: caseNames.count,
    succeeded: allInAllRuns,
    failed: caseNames.count - allInAllRuns,
    successRate: totalCaseRuns == 0 ? 0 : Double(totalSucc) / Double(totalCaseRuns),
    stableSuccessRate: caseNames.isEmpty ? 0 : Double(allInAllRuns) / Double(caseNames.count),
    totalLlmCalls: totalLlmCalls,
    totalTokens: totalTokens,
    totalDurationSec: totalDuration,
    meanDurationSec: mean,
    medianDurationSec: median,
    p90DurationSec: p90,
    modeCorrectCount: modeCorrect,
    modeExpectedCount: modeExpected,
    highVarianceCaseCount: aggCases.filter { $0.highVariance }.count,
    referenceScoredCount: scoredCases.count,
    meanReferenceSimilarity: meanRef,
    minReferenceSimilarity: minRef,
    cases: aggCases
  )
  try? writeJSON(agg, path: MetaFS.summaryPath(candidateId))
  print("\n[junco-meta] aggregated \(replicates) replicate(s): \(allInAllRuns)/\(caseNames.count) stable success; high-variance cases: \(aggCases.filter { $0.highVariance }.count)")
}

func runList() -> Int32 {
  let dir = MetaFS.candidatesDir
  guard FileManager.default.fileExists(atPath: dir) else {
    print("(no candidates yet — run `junco-meta eval --candidate <id>` after writing meta.json)")
    return 0
  }
  guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return 0 }
  func pad(_ s: String, _ width: Int) -> String {
    s.count >= width ? s : s + String(repeating: " ", count: width - s.count)
  }
  print("\(pad("id", 30))  \(pad("class", 14))  \(pad("status", 9))  \(pad("succ/cases", 10))  rationale")
  for id in entries.sorted() {
    let meta = readJSON(CandidateMeta.self, path: MetaFS.metaPath(id))
    struct SummaryLite: Decodable { let succeeded: Int; let caseCount: Int }
    let sum = readJSON(SummaryLite.self, path: MetaFS.summaryPath(id))
    let klass = meta?.mutationClass ?? "?"
    let status = sum != nil ? "evaluated" : "pending"
    let succ = sum.map { "\($0.succeeded)/\($0.caseCount)" } ?? "-"
    let rationale = String(meta?.rationale.prefix(50) ?? "")
    print("\(pad(id, 30))  \(pad(klass, 14))  \(pad(status, 9))  \(pad(succ, 10))  \(rationale)")
  }
  return 0
}

// MARK: - Frontier & compare shared types

/// Summary decoder that tolerates either the single-run format (from EvalHarness)
/// or the aggregate format (from aggregateReplicates). Missing fields default sensibly.
struct Summary: Decodable {
  let caseCount: Int
  let succeeded: Int
  let failed: Int
  let successRate: Double
  let totalLlmCalls: Int
  let totalTokens: Int
  let totalDurationSec: Double
  let meanDurationSec: Double
  let medianDurationSec: Double
  let p90DurationSec: Double
  let modeCorrectCount: Int
  let modeExpectedCount: Int
  let replicateCount: Int
  let stableSuccessRate: Double?
  let highVarianceCaseCount: Int?
  let referenceScoredCount: Int?
  let meanReferenceSimilarity: Double?
  let minReferenceSimilarity: Double?
  let cases: [CaseRow]?

  struct CaseRow: Decodable {
    let name: String
    // Single-run fields
    let mode: String?
    let modeCorrect: Bool?
    let succeeded: Bool?
    let llmCalls: Int?
    let tokensUsed: Int?
    let durationSeconds: Double?
    let referenceSimilarity: Double?
    // Aggregate fields
    let succeededInAllRuns: Bool?
    let successCount: Int?
    let replicateCount: Int?
    let medianDurationSeconds: Double?
    let minDurationSeconds: Double?
    let maxDurationSeconds: Double?
    let highVariance: Bool?
    let modeCorrectRate: Double?
    let medianReferenceSimilarity: Double?

    /// Canonical `succeeded` across both formats.
    var didSucceed: Bool {
      succeeded ?? succeededInAllRuns ?? false
    }

    /// Canonical `durationSeconds` across both formats.
    var duration: Double {
      durationSeconds ?? medianDurationSeconds ?? 0
    }
  }

  private enum CodingKeys: String, CodingKey {
    case caseCount, succeeded, failed, successRate
    case totalLlmCalls, totalTokens, totalDurationSec
    case meanDurationSec, medianDurationSec, p90DurationSec
    case modeCorrectCount, modeExpectedCount
    case replicateCount, stableSuccessRate, highVarianceCaseCount
    case referenceScoredCount, meanReferenceSimilarity, minReferenceSimilarity
    case cases
  }

  init(from decoder: Decoder) throws {
    let c = try decoder.container(keyedBy: CodingKeys.self)
    self.caseCount = try c.decode(Int.self, forKey: .caseCount)
    self.succeeded = try c.decode(Int.self, forKey: .succeeded)
    self.failed = try c.decode(Int.self, forKey: .failed)
    self.successRate = try c.decode(Double.self, forKey: .successRate)
    self.totalLlmCalls = try c.decode(Int.self, forKey: .totalLlmCalls)
    self.totalTokens = try c.decode(Int.self, forKey: .totalTokens)
    self.totalDurationSec = try c.decode(Double.self, forKey: .totalDurationSec)
    self.meanDurationSec = try c.decode(Double.self, forKey: .meanDurationSec)
    self.medianDurationSec = try c.decode(Double.self, forKey: .medianDurationSec)
    self.p90DurationSec = try c.decode(Double.self, forKey: .p90DurationSec)
    self.modeCorrectCount = try c.decode(Int.self, forKey: .modeCorrectCount)
    self.modeExpectedCount = try c.decode(Int.self, forKey: .modeExpectedCount)
    self.replicateCount = (try? c.decode(Int.self, forKey: .replicateCount)) ?? 1
    self.stableSuccessRate = try? c.decode(Double.self, forKey: .stableSuccessRate)
    self.highVarianceCaseCount = try? c.decode(Int.self, forKey: .highVarianceCaseCount)
    self.referenceScoredCount = try? c.decode(Int.self, forKey: .referenceScoredCount)
    self.meanReferenceSimilarity = try? c.decode(Double.self, forKey: .meanReferenceSimilarity)
    self.minReferenceSimilarity = try? c.decode(Double.self, forKey: .minReferenceSimilarity)
    self.cases = try? c.decode([CaseRow].self, forKey: .cases)
  }
}

/// Load (id, summary) pairs for all candidates that have completed an evaluation.
func loadEvaluatedCandidates() -> [(id: String, summary: Summary)] {
  let dir = MetaFS.candidatesDir
  guard let entries = try? FileManager.default.contentsOfDirectory(atPath: dir) else { return [] }
  var out: [(String, Summary)] = []
  for id in entries.sorted() {
    if let s = readJSON(Summary.self, path: MetaFS.summaryPath(id)) {
      out.append((id, s))
    }
  }
  return out
}

/// 4-axis Pareto dominance on primary metrics.
/// Axes: successRate ↑, medianDurationSec ↓, totalLlmCalls ↓, totalTokens ↓.
/// A dominates B iff A is weakly better on all four AND strictly better on at least one.
/// Captures both quality (success) and efficiency (latency, calls, tokens) — otherwise
/// candidates that cut LLM calls at identical success rates (e.g., soft-classify-guard,
/// which trades 1 extra call for a 30-call CVF loop via the deterministic tier) are
/// wrongly marked dominated by a faster-median baseline.
func dominates(_ a: Summary, _ b: Summary) -> Bool {
  let aCalls = Double(a.totalLlmCalls), bCalls = Double(b.totalLlmCalls)
  let aToks = Double(a.totalTokens), bToks = Double(b.totalTokens)
  let betterOrEq =
    a.successRate >= b.successRate
    && a.medianDurationSec <= b.medianDurationSec
    && aCalls <= bCalls
    && aToks <= bToks
  let strictlyBetter =
    a.successRate > b.successRate
    || a.medianDurationSec < b.medianDurationSec
    || aCalls < bCalls
    || aToks < bToks
  return betterOrEq && strictlyBetter
}

func computeFrontier(_ evaluated: [(id: String, summary: Summary)]) -> Set<String> {
  var frontier: Set<String> = []
  for (i, pair) in evaluated.enumerated() {
    var dominated = false
    for (j, other) in evaluated.enumerated() where i != j {
      if dominates(other.summary, pair.summary) {
        dominated = true
        break
      }
    }
    if !dominated { frontier.insert(pair.id) }
  }
  return frontier
}

func runFrontier() -> Int32 {
  let evaluated = loadEvaluatedCandidates()
  guard !evaluated.isEmpty else {
    print("(no evaluated candidates yet)")
    return 0
  }
  let frontier = computeFrontier(evaluated)

  func pad(_ s: String, _ n: Int) -> String {
    s.count >= n ? s : s + String(repeating: " ", count: n - s.count)
  }
  print("\(pad("id", 30))  \(pad("rate", 6))  \(pad("median", 8))  \(pad("p90", 7))  \(pad("tokens", 8))  \(pad("calls", 6))  frontier")
  for (id, s) in evaluated.sorted(by: { $0.summary.successRate > $1.summary.successRate || ($0.summary.successRate == $1.summary.successRate && $0.summary.medianDurationSec < $1.summary.medianDurationSec) }) {
    let mark = frontier.contains(id) ? "★" : "·"
    let rate = String(format: "%.1f%%", s.successRate * 100)
    let med = String(format: "%.1fs", s.medianDurationSec)
    let p90 = String(format: "%.1fs", s.p90DurationSec)
    print("\(pad(id, 30))  \(pad(rate, 6))  \(pad(med, 8))  \(pad(p90, 7))  \(pad(String(s.totalTokens), 8))  \(pad(String(s.totalLlmCalls), 6))  \(mark)")
  }
  // Persist
  struct FrontierFile: Encodable {
    let computedAt: String
    let ids: [String]
    let axes: [String]
  }
  let iso = ISO8601DateFormatter().string(from: Date())
  let ff = FrontierFile(
    computedAt: iso, ids: frontier.sorted(),
    axes: ["successRate", "medianDurationSec", "totalLlmCalls", "totalTokens"]
  )
  try? writeJSON(ff, path: MetaFS.frontierPath)
  return 0
}

func runCompare(_ idA: String, _ idB: String) -> Int32 {
  guard let a = readJSON(Summary.self, path: MetaFS.summaryPath(idA)) else {
    FileHandle.standardError.write(Data("[junco-meta] No summary for \(idA)\n".utf8))
    return 4
  }
  guard let b = readJSON(Summary.self, path: MetaFS.summaryPath(idB)) else {
    FileHandle.standardError.write(Data("[junco-meta] No summary for \(idB)\n".utf8))
    return 4
  }
  print("Comparing \(idA) vs \(idB)")
  func line(_ label: String, _ av: Double, _ bv: Double, _ higherIsBetter: Bool, fmt: String = "%.1f") {
    let delta = bv - av
    let sign = delta > 0 ? "+" : ""
    let good = (higherIsBetter ? delta > 0 : delta < 0)
    let marker = delta == 0 ? "·" : (good ? "↑" : "↓")
    let padded = label.count >= 24 ? label : label + String(repeating: " ", count: 24 - label.count)
    let aStr = String(format: fmt, av)
    let bStr = String(format: fmt, bv)
    let dStr = String(format: fmt, delta)
    print("  \(padded)  \(aStr)  →  \(bStr)    Δ \(sign)\(dStr)  \(marker)")
  }
  line("success rate", a.successRate * 100, b.successRate * 100, true, fmt: "%.1f%%")
  line("median dur (s)", a.medianDurationSec, b.medianDurationSec, false)
  line("p90 dur (s)", a.p90DurationSec, b.p90DurationSec, false)
  line("mean dur (s)", a.meanDurationSec, b.meanDurationSec, false)
  line("total wall (s)", a.totalDurationSec, b.totalDurationSec, false)
  line("total tokens", Double(a.totalTokens), Double(b.totalTokens), false, fmt: "%.0f")
  line("total LLM calls", Double(a.totalLlmCalls), Double(b.totalLlmCalls), false, fmt: "%.0f")

  // Per-case deltas when both have per-case data
  if let ac = a.cases, let bc = b.cases {
    let am = Dictionary(uniqueKeysWithValues: ac.map { ($0.name, $0) })
    let bm = Dictionary(uniqueKeysWithValues: bc.map { ($0.name, $0) })
    let shared = Set(am.keys).intersection(bm.keys).sorted()
    var regressed: [String] = []
    var improved: [String] = []
    var durBigDelta: [(String, Double)] = []
    for name in shared {
      guard let av = am[name], let bv = bm[name] else { continue }
      if av.didSucceed && !bv.didSucceed { regressed.append(name) }
      if !av.didSucceed && bv.didSucceed { improved.append(name) }
      let d = bv.duration - av.duration
      if abs(d) >= 2 { durBigDelta.append((name, d)) }
    }
    print("\n  regressed (succ→fail):  \(regressed.isEmpty ? "none" : regressed.joined(separator: ", "))")
    print("  improved (fail→succ):   \(improved.isEmpty ? "none" : improved.joined(separator: ", "))")
    if !durBigDelta.isEmpty {
      let sorted = durBigDelta.sorted { abs($0.1) > abs($1.1) }.prefix(5)
      print("  top duration shifts:")
      for (name, d) in sorted {
        print(String(format: "    %@  %+.1fs", name as NSString, d))
      }
    }
  }
  return 0
}

// MARK: - Trace diff

struct TraceLine: Decodable {
  let timestampNs: UInt64?
  let stage: String
  let kind: String
  let durationMs: Double?
  let payload: TracePayload?

  struct TracePayload: Decodable {
    let name: String?
    let systemPrompt: String?
    let userPrompt: String?
    let response: String?
    let structuredType: String?
    let temperature: Double?
    let tool: String?
    let target: String?
    let output: String?
    let observedValue: Double?
    let effectiveThreshold: Double?
    let pathTaken: String?
    let notes: String?
    let errorMessage: String?
  }
}

/// Read a trace.jsonl file and return each line's decoded event.
func readTrace(path: String) -> [TraceLine] {
  guard let data = FileManager.default.contents(atPath: path),
        let text = String(data: data, encoding: .utf8) else { return [] }
  var out: [TraceLine] = []
  for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
    if let bytes = line.data(using: .utf8),
       let ev = try? JSONDecoder().decode(TraceLine.self, from: bytes) {
      out.append(ev)
    }
  }
  return out
}

/// Find the trace for a case under a candidate, preferring single-dir `traces/` layout
/// and falling back to the first per-replicate directory.
func findTracePath(candidateId: String, caseName: String) -> String? {
  let fm = FileManager.default
  let single = "\(MetaFS.candidateDir(candidateId))/traces/\(caseName).trace.jsonl"
  if fm.fileExists(atPath: single) { return single }
  let baseDir = MetaFS.candidateDir(candidateId)
  if let entries = try? fm.contentsOfDirectory(atPath: baseDir) {
    for entry in entries.sorted() where entry.hasPrefix("traces-run") {
      let path = "\(baseDir)/\(entry)/\(caseName).trace.jsonl"
      if fm.fileExists(atPath: path) { return path }
    }
  }
  return nil
}

func runTraceDiff(_ idA: String, _ idB: String, _ caseName: String) -> Int32 {
  guard let pathA = findTracePath(candidateId: idA, caseName: caseName) else {
    FileHandle.standardError.write(Data("No trace for \(idA)/\(caseName)\n".utf8))
    return 4
  }
  guard let pathB = findTracePath(candidateId: idB, caseName: caseName) else {
    FileHandle.standardError.write(Data("No trace for \(idB)/\(caseName)\n".utf8))
    return 4
  }
  let traceA = readTrace(path: pathA)
  let traceB = readTrace(path: pathB)

  func summarize(_ trace: [TraceLine], label: String) {
    print("--- \(label) ---")
    for e in trace {
      let dur = e.durationMs.map { String(format: " %.0fms", $0) } ?? ""
      var tail = ""
      if let p = e.payload {
        if let t = p.structuredType { tail += " type=\(t)" }
        if let pt = p.pathTaken { tail += " path=\(pt)" }
        if let ov = p.observedValue, let thr = p.effectiveThreshold {
          tail += String(format: " obs=%.2f thr=%.2f", ov, thr)
        }
        if let tool = p.tool { tail += " tool=\(tool)" }
        if let n = p.notes { tail += " notes=\(String(n.prefix(80)))" }
      }
      print("  [\(e.stage)] \(e.kind)\(dur)\(tail)")
    }
  }
  summarize(traceA, label: "\(idA)  \(caseName)  (\(traceA.count) events)")
  print()
  summarize(traceB, label: "\(idB)  \(caseName)  (\(traceB.count) events)")

  // Emit a succinct side-by-side of the CLASSIFY LLM call responses when both exist.
  let classifyA = traceA.first { $0.kind == "llmCall" && $0.payload?.structuredType == "AgentIntent" }
  let classifyB = traceB.first { $0.kind == "llmCall" && $0.payload?.structuredType == "AgentIntent" }
  if let ca = classifyA, let cb = classifyB {
    print("\n--- classify response diff ---")
    let rA = ca.payload?.response ?? "(none)"
    let rB = cb.payload?.response ?? "(none)"
    print("  \(idA):  \(String(rA.prefix(200)))")
    print("  \(idB):  \(String(rB.prefix(200)))")
    let promptsMatch = ca.payload?.userPrompt == cb.payload?.userPrompt
      && ca.payload?.systemPrompt == cb.payload?.systemPrompt
    print(promptsMatch
      ? "  prompts: IDENTICAL — any divergence is AFM sampling noise"
      : "  prompts: DIFFER — inspect systemPrompt / userPrompt for diff source")
  }
  return 0
}

func runShow(candidateId: String) -> Int32 {
  guard let meta = readJSON(CandidateMeta.self, path: MetaFS.metaPath(candidateId)) else {
    FileHandle.standardError.write(Data("[junco-meta] No meta.json for \(candidateId)\n".utf8))
    return 4
  }
  print("=== Candidate \(candidateId) ===")
  print("created:   \(meta.createdAt)")
  print("parent:    \(meta.parent ?? "-")")
  print("class:     \(meta.mutationClass)")
  print("rationale: \(meta.rationale)")

  if !meta.metaConfig.isEmpty {
    print("\n--- metaConfig overrides ---")
    if let d = try? JSONEncoder().encode(meta.metaConfig), let s = String(data: d, encoding: .utf8) { print(s) }
  }
  if !meta.promptOverrides.isEmpty {
    print("\n--- promptOverrides ---")
    if let d = try? JSONEncoder().encode(meta.promptOverrides), let s = String(data: d, encoding: .utf8) { print(s) }
  }

  struct ShowSummary: Decodable {
    let caseCount: Int; let succeeded: Int; let failed: Int; let successRate: Double
    let totalLlmCalls: Int; let totalTokens: Int; let totalDurationSec: Double
    let medianDurationSec: Double; let p90DurationSec: Double
    let modeCorrectCount: Int; let modeExpectedCount: Int
    let referenceScoredCount: Int?
    let meanReferenceSimilarity: Double?
    let minReferenceSimilarity: Double?
  }
  if let s = readJSON(ShowSummary.self, path: MetaFS.summaryPath(candidateId)) {
    print("\n--- summary ---")
    print(String(format: "cases: %d   succeeded: %d   rate: %.1f%%", s.caseCount, s.succeeded, s.successRate * 100))
    print("llmCalls: \(s.totalLlmCalls)   tokens: \(s.totalTokens)   wall: \(String(format: "%.1fs", s.totalDurationSec))")
    print(String(format: "duration/case  median: %.1fs  p90: %.1fs",
      s.medianDurationSec, s.p90DurationSec))
    print(String(format: "mode accuracy: %d/%d", s.modeCorrectCount, s.modeExpectedCount))
    if let meanRef = s.meanReferenceSimilarity, let scored = s.referenceScoredCount {
      let minText = s.minReferenceSimilarity.map { String(format: " min=%.3f", $0) } ?? ""
      print(String(format: "reference similarity (n=%d): mean=%.3f%@", scored, meanRef, minText))
    }
  } else {
    print("\n(no summary yet — run `junco-meta eval --candidate \(candidateId)`)")
  }
  return 0
}

// MARK: - CLI dispatch

let args = CommandLine.arguments
guard args.count >= 2 else {
  print("""
  Usage: junco-meta <subcommand> [options]

  Subcommands:
    canary                    Run the canary split (fast smoke gate).
    eval --candidate <id> [--replicates N] [--case <name>] [--skip-canary]
                              Evaluate a candidate on the search split. Auto-runs canary first
                              unless --skip-canary is passed (swift-code candidates always skip;
                              their worktree build gates separately).
    list                      List all candidates with status.
    show <id>                 Show a candidate's meta + summary.
    frontier                  Print the current 2-axis Pareto frontier.
    compare <a> <b>           Diff two candidates' summaries.
    trace-diff <a> <b> <case> Compare per-event traces between two candidates for a case.
  """)
  exit(1)
}

let sub = args[1]
switch sub {
case "canary":
  exit(runCanary())

case "eval":
  var candidate: String?
  var replicates = 1
  var caseFilter: String?
  var skipCanary = false
  var i = 2
  while i < args.count {
    if args[i] == "--candidate", i + 1 < args.count {
      candidate = args[i + 1]; i += 2
    } else if args[i] == "--replicates", i + 1 < args.count {
      replicates = max(1, Int(args[i + 1]) ?? 1); i += 2
    } else if args[i] == "--case", i + 1 < args.count {
      caseFilter = args[i + 1]; i += 2
    } else if args[i] == "--skip-canary" {
      skipCanary = true; i += 1
    } else { i += 1 }
  }
  guard let id = candidate else {
    FileHandle.standardError.write(Data("eval requires --candidate <id>\n".utf8))
    exit(2)
  }
  exit(runEval(candidateId: id, replicates: replicates, caseFilter: caseFilter, skipCanary: skipCanary))

case "list":
  exit(runList())

case "show":
  guard args.count >= 3 else {
    FileHandle.standardError.write(Data("show requires <id>\n".utf8))
    exit(2)
  }
  exit(runShow(candidateId: args[2]))

case "frontier":
  exit(runFrontier())

case "compare":
  guard args.count >= 4 else {
    FileHandle.standardError.write(Data("compare requires two ids\n".utf8))
    exit(2)
  }
  exit(runCompare(args[2], args[3]))

case "trace-diff":
  guard args.count >= 5 else {
    FileHandle.standardError.write(Data("trace-diff requires <idA> <idB> <caseName>\n".utf8))
    exit(2)
  }
  exit(runTraceDiff(args[2], args[3], args[4]))

default:
  FileHandle.standardError.write(Data("Unknown subcommand: \(sub)\n".utf8))
  exit(2)
}
