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
  private let scratchpad: Scratchpad

  public init(workingDirectory: String) {
    self.files = FileTools(workingDirectory: workingDirectory)
    self.contextPacker = ContextPacker(workingDirectory: workingDirectory)
    self.scratchpad = Scratchpad(projectDirectory: workingDirectory)
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

    // Recipe 0: Multi-file app scaffold — "build/create a X app"
    // Must check BEFORE single-file recipe since scaffold queries have no explicit targets.
    case "add" where Self.isAppScopeQuery(query),
         "build" where Self.isAppScopeQuery(query):
      return buildAppScaffoldTasks(
        query: query, snapshot: snapshot, explicitContext: explicitContext
      )

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
    } else if let cached = scratchpad.readAll()["generated_types"], !cached.isEmpty {
      // Cross-turn fallback: use type manifest from previous build session
      spec += "\n\(TokenBudget.truncate(cached, toTokens: 150))\n"
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

    // Add personalized exemplar using actual type names from the snapshot.
    // If the snapshot has enough info, generate exemplar with real property names.
    // Otherwise fall back to the generic pattern.
    let role = MicroSkill.inferFileRole(target)
    if let personalized = Self.personalizedExemplar(for: role, snapshot: snapshot) {
      spec += "\n\(personalized)\n"
    } else if let generic = Self.exemplar(for: role) {
      spec += "\n\(generic)\n"
    }

    return spec
  }

  /// Generate an exemplar using actual property/method names from the project snapshot.
  /// Eliminates the prompt conflict where the model copies generic names from a template
  /// instead of adapting to the real types.
  static func personalizedExemplar(for role: String, snapshot: ProjectSnapshot) -> String? {
    guard role == "view" else { return nil }

    // Find a ViewModel and its associated model type
    let vms = snapshot.services.filter { $0.name.contains("ViewModel") } +
              snapshot.models.filter { $0.name.contains("ViewModel") }
    guard let vm = vms.first else { return nil }

    // Find a model type (not ViewModel, not Service)
    let models = snapshot.models.filter { !$0.name.contains("ViewModel") }
    guard let model = models.first else { return nil }

    let listProp = vm.properties.first(where: { $0.contains("[") }) ?? vm.properties.first ?? "items"
    let titleProp = model.properties.first ?? "name"
    let subtitleProp = model.properties.count > 1 ? model.properties[1] : ""
    let loadMethod = vm.methods.first ?? "load"
    let searchProp = vm.properties.first(where: { $0.lowercased().contains("search") })

    var exemplar = """
      // PATTERN — use these exact property names:
      // @State var viewModel = \(vm.name)()
      // List(viewModel.\(listProp)) { item in
      //   Text(item.\(titleProp))
      """
    if !subtitleProp.isEmpty {
      exemplar += "\n//   Text(item.\(subtitleProp)).foregroundStyle(.secondary)"
    }
    exemplar += "\n// }"
    exemplar += "\n// .navigationTitle(\"...\")"
    if let search = searchProp {
      exemplar += "\n// .searchable(text: $viewModel.\(search))"
    }
    exemplar += "\n// .task { await viewModel.\(loadMethod)() }"

    return exemplar
  }

  /// Generic exemplar for a file role (fallback when no snapshot data available).
  static func exemplar(for role: String) -> String? {
    switch role {
    case "view":
      return """
        // PATTERN — follow this structure:
        // struct XView: View {
        //   @State var viewModel = XViewModel()
        //   var body: some View {
        //     NavigationStack {
        //       List(viewModel.items) { item in
        //         Text(item.name)
        //       }
        //       .navigationTitle("Title")
        //       .task { await viewModel.load() }
        //     }
        //   }
        // }
        """
    default:
      return nil
    }
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

  // MARK: - App Scaffold Recipe

  /// Detect queries that describe an entire app rather than a single file.
  static func isAppScopeQuery(_ query: String) -> Bool {
    let lower = query.lowercased()
    let triggers = ["build a", "create a", "make a", "build an", "create an", "make an"]
    let indicators = ["app", "application", "project"]
    let hasTrigger = triggers.contains(where: { lower.contains($0) })
    let hasIndicator = indicators.contains(where: { lower.contains($0) })
    return hasTrigger && hasIndicator
  }

  /// Extract the primary domain noun from an app creation query.
  /// "build a podcast app" → "podcast", "create a weather application" → "weather"
  static func inferAppDomain(_ query: String) -> String {
    let lower = query.lowercased()
    let patterns = [
      #"(?:build|create|make)\s+(?:a|an)\s+(\w+)\s+(?:app|application|project)"#,
    ]
    for pattern in patterns {
      if let regex = try? NSRegularExpression(pattern: pattern),
         let match = regex.firstMatch(in: lower, range: NSRange(lower.startIndex..., in: lower)),
         let range = Range(match.range(at: 1), in: lower) {
        return String(lower[range])
      }
    }
    return "app"
  }

  /// Generate ordered create tasks for an app scaffold.
  /// Order: Model → Service → ViewModel → View → App entry point.
  /// Only creates files that don't already exist.
  private func buildAppScaffoldTasks(
    query: String,
    snapshot: ProjectSnapshot,
    explicitContext: String
  ) -> [ConcreteTask] {
    let domain = Self.inferAppDomain(query)
    let cap = domain.prefix(1).uppercased() + domain.dropFirst()

    // Detect source directory from Package.swift target path or existing Swift files
    let sourceDir: String
    if let packageContent = try? files.read(path: "Package.swift", maxTokens: 400),
       let pathMatch = packageContent.firstMatch(of: /path:\s*"([^"]+)"/) {
      let targetPath = String(pathMatch.1)
      sourceDir = targetPath.hasSuffix("/") ? targetPath : targetPath + "/"
    } else {
      let swiftFiles = files.listFiles(extensions: ["swift"]).filter { !$0.contains("Package.swift") }
      if let first = swiftFiles.first {
        let dir = (first as NSString).deletingLastPathComponent
        sourceDir = dir.isEmpty ? "" : (dir.hasSuffix("/") ? dir : dir + "/")
      } else {
        sourceDir = "Sources/"
      }
    }

    // Extract URLs from the original query for the service spec
    let urls = extractURLs(query)
    let urlHint = urls.isEmpty ? "" : "\nIMPORTANT: Use this exact URL: \(urls.first ?? "")"

    // Generate narrow, file-specific tasks. Each spec is tailored so the model
    // (and template system) generates ONLY the content for that file.
    var tasks: [ConcreteTask] = []

    // Task 1: Model (use "Models" in filename so template router picks it up)
    let modelTarget = "\(sourceDir)\(cap)Models.swift"
    if !files.exists(modelTarget) {
      tasks.append(ConcreteTask(
        action: .create, target: modelTarget,
        specification: "Create \(modelTarget).\n\nstruct \(cap): Codable, Identifiable with properties relevant to a \(domain). Include var id = UUID()."
      ))
    }

    // Task 2: Service (short spec to fit within 4K with template schema overhead)
    let serviceTarget = "\(sourceDir)\(cap)Service.swift"
    if !files.exists(serviceTarget) {
      tasks.append(ConcreteTask(
        action: .create, target: serviceTarget,
        specification: "Create \(serviceTarget). actor \(cap)Service. Method: search\(cap)s(term: String) -> [\(cap)].\(urlHint) Params: term, media=\(domain)."
      ))
    }

    // Task 3: ViewModel
    let vmTarget = "\(sourceDir)\(cap)ViewModel.swift"
    if !files.exists(vmTarget) {
      tasks.append(ConcreteTask(
        action: .create, target: vmTarget,
        specification: "Create \(vmTarget).\n\n@Observable class \(cap)ViewModel with var \(domain)s: [\(cap)] = [] and var searchText: String = \"\". Method: func search() calls \(cap)Service().search\(cap)s(term: searchText) and assigns to \(domain)s."
      ))
    }

    // Task 4: ListView
    let viewTarget = "\(sourceDir)\(cap)ListView.swift"
    if !files.exists(viewTarget) {
      tasks.append(ConcreteTask(
        action: .create, target: viewTarget,
        specification: "Create \(viewTarget).\n\nSwiftUI View with @State var viewModel = \(cap)ViewModel(). List of viewModel.\(domain)s. Show each item's first two properties. Add .searchable(text: $viewModel.searchText) and .task { await viewModel.search() }. Navigation title: \"\(cap)s\"."
      ))
    }

    // Task 5: App entry point
    let appTarget = "\(sourceDir)\(cap)App.swift"
    if !files.exists(appTarget) {
      tasks.append(ConcreteTask(
        action: .create, target: appTarget,
        specification: "Create \(appTarget).\n\n@main App struct \(cap)App with WindowGroup containing \(cap)ListView()."
      ))
    }

    return tasks
  }
}
