// TaskResolver.swift — Deterministic task decomposition with recipe templates
//
// Replaces LLM-based planning for common patterns (80% of tasks).
// Falls back to a single context-rich LLM call for novel tasks.
// Each ConcreteTask carries a rich specification built from ProjectSnapshot.

import Foundation
import FoundationModels

// MARK: - ConcreteTask

/// A resolved task with all context needed for execution.
public struct ConcreteTask: Sendable {
  /// Which action to perform.
  public let action: TaskAction
  /// Target file path.
  public let target: String
  /// Rich specification for the LLM, assembled from ProjectSnapshot.
  /// Contains project context, user query, and domain hints.
  public let specification: String

  public enum TaskAction: String, Sendable {
    case create   // Generate new file
    case edit     // Modify existing file
    case explain  // Read + respond (no file changes)
    case bash     // Run shell command
  }

  public init(action: TaskAction, target: String, specification: String) {
    self.action = action
    self.target = target
    self.specification = specification
  }
}

// MARK: - LLM Fallback Types

@Generable
public struct TaskPlan: Codable, Sendable {
  public var tasks: [TaskDescription]
}

@Generable
public struct TaskDescription: Codable, Sendable {
  @Guide(description: "create, edit, or bash")
  public var action: String
  public var target: String
  public var description: String
}

// MARK: - TaskResolver

/// Resolves user queries into concrete tasks using recipe templates
/// (0 LLM calls) or context-first LLM decomposition (1 call).
public struct TaskResolver: Sendable {
  private let files: FileTools
  private let contextPacker: ContextPacker

  public init(workingDirectory: String) {
    self.files = FileTools(workingDirectory: workingDirectory)
    self.contextPacker = ContextPacker(workingDirectory: workingDirectory)
  }

  /// Resolve a query into concrete tasks.
  /// Tries recipe templates first (deterministic, 0 LLM calls).
  /// Falls back to LLM decomposition (1 call) for novel tasks.
  public func resolve(
    query: String,
    intent: AgentIntent,
    snapshot: ProjectSnapshot,
    index: [IndexEntry],
    explicitContext: String,
    adapter: any LLMAdapter
  ) async throws -> [ConcreteTask] {
    // Try deterministic recipe templates first
    if let tasks = matchRecipe(
      query: query, intent: intent, snapshot: snapshot,
      index: index, explicitContext: explicitContext
    ) {
      return tasks
    }

    // Fallback: LLM decomposition with full project context
    return try await llmDecompose(
      query: query, intent: intent, snapshot: snapshot,
      index: index, explicitContext: explicitContext, adapter: adapter
    )
  }

  // MARK: - Recipe Templates

  /// Match query against known recipe patterns. Returns nil if no recipe matches.
  func matchRecipe(
    query: String,
    intent: AgentIntent,
    snapshot: ProjectSnapshot,
    index: [IndexEntry],
    explicitContext: String
  ) -> [ConcreteTask]? {
    switch intent.taskType {

    // Recipe 1: Single file create — "add" with non-existent targets
    case "add":
      let newTargets = intent.targets.filter { !files.exists($0) }
      guard !newTargets.isEmpty else { return nil }

      return newTargets.map { target in
        let spec = buildCreateSpecification(
          target: target, query: query, snapshot: snapshot, explicitContext: explicitContext
        )
        return ConcreteTask(action: .create, target: target, specification: spec)
      }

    // Recipe 2: Fix existing file — read then edit
    case "fix":
      let existingTargets = intent.targets.filter { files.exists($0) }
      guard !existingTargets.isEmpty else { return nil }

      return existingTargets.map { target in
        let content = (try? files.read(path: target, maxTokens: 800)) ?? ""
        let spec = buildEditSpecification(
          target: target, query: query, existingContent: content, snapshot: snapshot
        )
        return ConcreteTask(action: .edit, target: target, specification: spec)
      }

    // Recipe 3: Add test — create test file for a type
    case "test":
      let targetType = intent.targets.first ?? ""
      let testPath = inferTestPath(for: targetType, snapshot: snapshot)
      let spec = buildTestSpecification(
        target: testPath, query: query, snapshot: snapshot, forType: targetType
      )
      return [ConcreteTask(action: .create, target: testPath, specification: spec)]

    // Recipe 4: Refactor existing file(s)
    case "refactor":
      let existingTargets = intent.targets.filter { files.exists($0) }
      guard !existingTargets.isEmpty else { return nil }

      return existingTargets.map { target in
        let content = (try? files.read(path: target, maxTokens: 800)) ?? ""
        let spec = buildEditSpecification(
          target: target, query: query, existingContent: content, snapshot: snapshot
        )
        return ConcreteTask(action: .edit, target: target, specification: spec)
      }

    // Recipe 5: Explain/explore — read only
    case "explain", "explore":
      let spec = buildExplainSpecification(query: query, explicitContext: explicitContext, snapshot: snapshot)
      return [ConcreteTask(action: .explain, target: "", specification: spec)]

    default:
      return nil
    }
  }

  // MARK: - Specification Builders

  /// Build a rich specification for file creation.
  func buildCreateSpecification(
    target: String,
    query: String,
    snapshot: ProjectSnapshot,
    explicitContext: String
  ) -> String {
    var spec = "Create \(target).\n\nUser request: \(query)\n"

    // Add project context (high-level summary)
    let context = snapshot.compactDescription(budget: 150)
    if !context.isEmpty {
      spec += "\nProject context:\n\(context)\n"
    }

    // Add type signatures so the LLM uses exact property/method names
    let typeBlock = snapshot.typeSignatureBlock(budget: 150)
    if !typeBlock.isEmpty {
      spec += "\n\(typeBlock)\n"
    }

    // Add explicit context (@-files, URLs)
    if !explicitContext.isEmpty {
      spec += "\nReference:\n\(TokenBudget.truncate(explicitContext, toTokens: 200))\n"
    }

    // Add URL hints
    let urls = extractURLs(query)
    if !urls.isEmpty {
      spec += "\nIMPORTANT: Use these exact URLs: \(urls.joined(separator: ", "))\n"
    }

    // Add style hint based on existing similar files
    if target.hasSuffix("View.swift"), let existingView = snapshot.views.first {
      spec += "\nFollow the patterns in \(existingView.file).\n"
    }

    return spec
  }

  /// Build a rich specification for file editing.
  func buildEditSpecification(
    target: String,
    query: String,
    existingContent: String,
    snapshot: ProjectSnapshot
  ) -> String {
    var spec = "Edit \(target).\n\nUser request: \(query)\n"

    spec += "\nCurrent file content:\n\(TokenBudget.truncateSmart(existingContent, toTokens: 600))\n"

    let context = snapshot.compactDescription(budget: 200)
    if !context.isEmpty {
      spec += "\nProject context:\n\(context)\n"
    }

    spec += "\nIMPORTANT: Apply ONLY the changes described in the user request. "
    spec += "Do not add unrequested properties, methods, or imports. "
    spec += "If the request lists specific items, implement ALL of them.\n"

    return spec
  }

  /// Build a specification for test file creation.
  func buildTestSpecification(
    target: String,
    query: String,
    snapshot: ProjectSnapshot,
    forType: String
  ) -> String {
    var spec = "Create \(target) — test file.\n\nUser request: \(query)\n"

    // Find the type being tested
    let typeSummary = (snapshot.models + snapshot.services).first { $0.name == forType }
    if let t = typeSummary {
      spec += "\nType to test: \(t.kind) \(t.name)"
      if !t.properties.isEmpty {
        spec += " (properties: \(t.properties.joined(separator: ", ")))"
      }
      if !t.methods.isEmpty {
        spec += "\nMethods: \(t.methods.joined(separator: ", "))"
      }
      spec += "\n"
    }

    // Add test pattern hint
    if let testPattern = snapshot.testPattern {
      spec += "\nExisting test pattern: \(testPattern)\n"
      if testPattern.contains("Swift Testing") {
        spec += "Use import Testing and @Test macro.\n"
      } else {
        spec += "Use import XCTest and XCTestCase.\n"
      }
    } else {
      spec += "\nUse Swift Testing: import Testing, @Test macro.\n"
    }

    return spec
  }

  /// Build a specification for explain/explore tasks.
  func buildExplainSpecification(
    query: String,
    explicitContext: String,
    snapshot: ProjectSnapshot
  ) -> String {
    var spec = "Task: \(query)\n"

    if !explicitContext.isEmpty {
      spec += "\nContent:\n\(TokenBudget.truncate(explicitContext, toTokens: 2000))\n"
    }

    let context = snapshot.compactDescription(budget: 200)
    if !context.isEmpty {
      spec += "\nProject context:\n\(context)\n"
    }

    return spec
  }

  // MARK: - LLM Fallback

  /// Decompose using a single LLM call with full project context.
  private func llmDecompose(
    query: String,
    intent: AgentIntent,
    snapshot: ProjectSnapshot,
    index: [IndexEntry],
    explicitContext: String,
    adapter: any LLMAdapter
  ) async throws -> [ConcreteTask] {
    let projectContext = snapshot.compactDescription(budget: 300)
    let fileList = files.listFiles().prefix(20).joined(separator: "\n")

    let prompt = """
      Task: \(query)
      Domain: \(intent.domain) | Type: \(intent.taskType)
      Targets: \(intent.targets.joined(separator: ", "))

      Project files:
      \(fileList)

      Project context:
      \(projectContext)

      Break this into 1-6 concrete tasks. Each task creates or edits ONE file.
      """

    let system = """
      You decompose coding tasks into concrete file operations. \
      Each task specifies one file to create or edit. \
      Use real file paths from the project. For new files, follow project naming conventions.
      """

    let plan = try await adapter.generateStructured(
      prompt: prompt, system: system, as: TaskPlan.self
    )

    // Convert TaskDescriptions to ConcreteTasks with rich specifications
    return plan.tasks.prefix(6).map { desc in
      let action: ConcreteTask.TaskAction
      switch desc.action.lowercased() {
      case "edit": action = .edit
      case "bash": action = .bash
      default: action = .create
      }

      let spec: String
      switch action {
      case .create:
        spec = buildCreateSpecification(
          target: desc.target, query: "\(query)\n\(desc.description)",
          snapshot: snapshot, explicitContext: explicitContext
        )
      case .edit:
        let content = (try? files.read(path: desc.target, maxTokens: 600)) ?? ""
        spec = buildEditSpecification(
          target: desc.target, query: "\(query)\n\(desc.description)",
          existingContent: content, snapshot: snapshot
        )
      case .bash:
        spec = desc.description
      case .explain:
        spec = desc.description
      }

      return ConcreteTask(action: action, target: desc.target, specification: spec)
    }
  }

  // MARK: - Helpers

  /// Infer test file path from a type name.
  private func inferTestPath(for typeName: String, snapshot: ProjectSnapshot) -> String {
    let cleanName = typeName.replacingOccurrences(of: ".swift", with: "")
    return "Tests/\(cleanName)Tests.swift"
  }

  /// Extract URLs from text.
  private func extractURLs(_ text: String) -> [String] {
    guard let detector = try? NSDataDetector(
      types: NSTextCheckingResult.CheckingType.link.rawValue
    ) else { return [] }
    let range = NSRange(text.startIndex..., in: text)
    return detector.matches(in: text, range: range).compactMap { match in
      Range(match.range, in: text).map { String(text[$0]) }
    }
  }
}
