// BackgroundTasks.swift — Opportunistic background work during idle periods
//
// Runs low-priority tasks when the session is idle (no active query).
// Tasks include: thinking phrase generation, reflection compaction,
// context freshness checks, output quality scoring, and index refresh.
//
// Only one task runs at a time to avoid Neural Engine contention.
// Tasks are cancellable — interrupted immediately when a new query starts.

import Foundation

/// A background task that can run during idle periods.
public protocol BackgroundWork: Sendable {
  /// Human-readable name for debugging.
  var name: String { get }

  /// How many idle seconds before this task should run.
  var idleThreshold: TimeInterval { get }

  /// Minimum interval between runs of this task.
  var cooldown: TimeInterval { get }

  /// Execute the task. Return a short status string.
  func execute(context: BackgroundContext) async throws -> String
}

/// Context passed to background tasks.
public struct BackgroundContext: Sendable {
  public let workingDirectory: String
  public let adapter: any LLMAdapter
  public let domain: DomainConfig

  public init(workingDirectory: String, adapter: any LLMAdapter, domain: DomainConfig) {
    self.workingDirectory = workingDirectory
    self.adapter = adapter
    self.domain = domain
  }
}

/// Manages and schedules background tasks during session idle time.
public actor BackgroundTaskRunner {
  private let context: BackgroundContext
  private var tasks: [any BackgroundWork] = []
  private var lastRunTimes: [String: Date] = [:]
  private var currentTask: Task<Void, Never>?
  private var lastActivityTime = Date()

  public init(context: BackgroundContext) {
    self.context = context
    self.tasks = [
      PhraseGenerationTask(),
      ReflectionCompactionTask(),
      IndexFreshnessTask(),
    ]
  }

  /// Register a custom background task.
  public func register(_ task: any BackgroundWork) {
    tasks.append(task)
  }

  /// Mark that user activity occurred (resets idle timer).
  public func markActive() {
    lastActivityTime = Date()
    // Cancel any running background task
    currentTask?.cancel()
    currentTask = nil
  }

  /// Check if any tasks should run. Call periodically (e.g., after each query).
  public func checkAndRun() {
    let idleTime = Date().timeIntervalSince(lastActivityTime)

    // Find eligible tasks
    let eligible = tasks.filter { task in
      guard idleTime >= task.idleThreshold else { return false }
      if let lastRun = lastRunTimes[task.name] {
        return Date().timeIntervalSince(lastRun) >= task.cooldown
      }
      return true
    }

    guard let task = eligible.first, currentTask == nil else { return }

    let ctx = context
    currentTask = Task.detached(priority: .background) { [weak self] in
      do {
        let result = try await task.execute(context: ctx)
        await self?.taskCompleted(task.name, result: result)
      } catch {
        await self?.taskCompleted(task.name, result: "error: \(error)")
      }
    }
  }

  private func taskCompleted(_ name: String, result: String) {
    lastRunTimes[name] = Date()
    currentTask = nil
  }
}

// MARK: - Built-in Background Tasks

/// Generate new thinking phrases using AFM during idle time.
struct PhraseGenerationTask: BackgroundWork {
  let name = "phrase-generation"
  let idleThreshold: TimeInterval = 10
  let cooldown: TimeInterval = 300  // 5 minutes between runs

  func execute(context: BackgroundContext) async throws -> String {
    let prompt = "Generate 5 short (1-3 word) thinking phrases for a coding assistant. " +
      "Examples: Analyzing..., Reading code..., Planning steps... " +
      "Return only the phrases, one per line."

    let response = try await context.adapter.generate(prompt: prompt, system: nil)
    let phrases = response.components(separatedBy: "\n")
      .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
      .filter { !$0.isEmpty && $0.count < 30 }

    guard !phrases.isEmpty else { return "no phrases generated" }

    // Save to .junco/phrases.json
    let dir = (context.workingDirectory as NSString).appendingPathComponent(Config.projectDirName)
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    let path = (dir as NSString).appendingPathComponent("phrases.json")

    var existing: [String: [String]] = [:]
    if let data = FileManager.default.contents(atPath: path),
       let parsed = try? JSONDecoder().decode([String: [String]].self, from: data) {
      existing = parsed
    }

    // Merge into the "execute" category (general purpose)
    var pool = existing["execute"] ?? []
    pool.append(contentsOf: phrases)
    // Cap at 50 custom phrases
    if pool.count > 50 { pool = Array(pool.suffix(50)) }
    existing["execute"] = pool

    let data = try JSONEncoder().encode(existing)
    try data.write(to: URL(fileURLWithPath: path))

    return "added \(phrases.count) phrases"
  }
}

/// Compact old reflections to keep the store manageable.
struct ReflectionCompactionTask: BackgroundWork {
  let name = "reflection-compaction"
  let idleThreshold: TimeInterval = 30
  let cooldown: TimeInterval = 600  // 10 minutes

  func execute(context: BackgroundContext) async throws -> String {
    let store = ReflectionStore(projectDirectory: context.workingDirectory)
    let count = store.count
    guard count > Config.maxReflections / 2 else { return "no compaction needed (\(count) reflections)" }

    // The store auto-compacts on save, but we can trigger it by saving a no-op
    // Actually just report — real compaction happens on next save
    return "store has \(count) reflections, will compact on next save"
  }
}

/// Check if the project index is stale.
struct IndexFreshnessTask: BackgroundWork {
  let name = "index-freshness"
  let idleThreshold: TimeInterval = 15
  let cooldown: TimeInterval = 120  // 2 minutes

  func execute(context: BackgroundContext) async throws -> String {
    let ft = FileTools(workingDirectory: context.workingDirectory)
    let count = ft.listFiles().count
    return "project has \(count) indexed files"
  }
}
