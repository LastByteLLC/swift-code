// MicroSkills.swift — Token-capped skill definitions loaded from MicroSkills.md
//
// MicroSkills are domain-specific prompt packs, each capped at 200 tokens.
// They modify the agent's behavior for specific task types without
// consuming a significant portion of the 4K context window.
//
// Format in MicroSkills.md:
// | Name | Domain | Task Types | Hint |
// |------|--------|------------|------|
// | swift-test | swift | test | Use @Test and #expect. Prefer Swift Testing over XCTest. |

import Foundation

/// A micro-skill that modifies agent behavior for specific task types.
public struct MicroSkill: Codable, Sendable {
  public let name: String
  public let domain: String        // "swift", "javascript", "general", "*"
  public let taskTypes: [String]   // Which task types trigger this skill
  public let hint: String          // Injected into system prompts (~200 tokens max)
  public let tools: [String]?      // Restrict to specific tools (nil = all)
  public let maxSteps: Int?        // Limit plan steps (nil = default)
  public let fileRoles: [String]?  // nil = all roles, ["view","app"] = only those roles

  /// Token cost of this skill's hint.
  public var tokenCost: Int { TokenBudget.estimate(hint) }

  /// Infer a file role from a target path.
  public static func inferFileRole(_ target: String) -> String {
    let lower = target.lowercased()
    if lower.contains("viewmodel") || lower.contains("view_model") || lower.hasSuffix("vm.swift") { return "viewmodel" }
    if lower.contains("view") { return "view" }
    if lower.contains("service") || lower.contains("manager") || lower.contains("store") { return "service" }
    if lower.contains("model") { return "model" }
    if lower.hasSuffix("app.swift") { return "app" }
    if lower.contains("test") { return "test" }
    return "unknown"
  }
}

/// Loads and manages micro-skills from MicroSkills.md or .junco/skills.json.
public struct SkillLoader: Sendable {
  public let workingDirectory: String

  public init(workingDirectory: String) {
    self.workingDirectory = workingDirectory
  }

  /// Load all available skills.
  public func loadAll() -> [MicroSkill] {
    var skills: [MicroSkill] = builtinSkills

    // Load from .junco/skills.json if present
    let customPath = (workingDirectory as NSString)
      .appendingPathComponent(".junco/skills.json")
    if let data = FileManager.default.contents(atPath: customPath),
       let custom = try? JSONDecoder().decode([MicroSkill].self, from: data) {
      skills.append(contentsOf: custom)
    }

    // Load from MicroSkills.md if present
    let mdPath = (workingDirectory as NSString)
      .appendingPathComponent("MicroSkills.md")
    if let content = try? String(contentsOfFile: mdPath, encoding: .utf8) {
      skills.append(contentsOf: parseMarkdownSkills(content))
    }

    return skills
  }

  /// Find skills matching a domain, task type, and optional file role.
  public func findSkills(domain: String, taskType: String, fileRole: String? = nil) -> [MicroSkill] {
    loadAll().filter { skill in
      (skill.domain == domain || skill.domain == "*") &&
      skill.taskTypes.contains(taskType) &&
      (skill.fileRoles == nil || fileRole == nil || skill.fileRoles!.contains(fileRole!))
    }
  }

  /// Format matching skills as a prompt fragment, capped at a token budget.
  public func skillHints(domain: String, taskType: String, fileRole: String? = nil, budget: Int = 200) -> String? {
    let matching = findSkills(domain: domain, taskType: taskType, fileRole: fileRole)
    guard !matching.isEmpty else { return nil }

    var hints: [String] = []
    var tokensUsed = 0

    for skill in matching {
      if tokensUsed + skill.tokenCost > budget { break }
      hints.append(skill.hint)
      tokensUsed += skill.tokenCost
    }

    return hints.isEmpty ? nil : hints.joined(separator: " ")
  }

  // MARK: - Built-in Skills

  private var builtinSkills: [MicroSkill] {
    [
      // --- Role-targeted skills (injected based on file type) ---

      MicroSkill(
        name: "swiftui-core",
        domain: "swift", taskTypes: ["add", "fix", "refactor"],
        hint: """
          Use @Observable (NOT ObservableObject, NOT @Published). \
          Use @State (NOT @StateObject) for @Observable classes. \
          NavigationStack (not NavigationView). Use .task {} not .onAppear for async. \
          Use NavigationLink(value:) inside ForEach, not NavigationLink(destination:).
          """,
        tools: nil, maxSteps: nil, fileRoles: ["view", "app"]
      ),
      MicroSkill(
        name: "swiftui-guards",
        domain: "swift", taskTypes: ["add", "fix"],
        hint: """
          Do NOT use .fontSize() — use .font(.system(size:)). \
          Do NOT use Image(systemName:style:) — no style parameter. \
          Never force-unwrap in view body. Prefer value types.
          """,
        tools: nil, maxSteps: nil, fileRoles: ["view"]
      ),
      // API-specific skills (swift-networking, avfoundation-audio) removed —
      // API signatures are now discovered at runtime via SwiftInterfaceIndex.
      MicroSkill(
        name: "swift-async",
        domain: "swift", taskTypes: ["add", "fix"],
        hint: """
          Assign async results directly: let items = try await service.fetchAll(). \
          Do NOT use trailing closure callbacks after async calls. \
          WRONG: service.fetch { result in }. RIGHT: let x = try await service.fetch(). \
          Wrap in do { try await ... } catch { } if function is not throws.
          """,
        tools: nil, maxSteps: nil, fileRoles: ["service", "viewmodel"]
      ),

      // --- Universal skills (no file role filter) ---

      MicroSkill(
        name: "swift-test",
        domain: "swift", taskTypes: ["test"],
        hint: "Use Swift Testing (@Test, #expect, #require). Prefer @Suite for grouping. Use async tests for actor code.",
        tools: nil, maxSteps: nil, fileRoles: ["test"]
      ),
      MicroSkill(
        name: "swift-concurrency",
        domain: "swift", taskTypes: ["fix", "refactor"],
        hint: "Use actors for shared state. Mark @MainActor for UI code. Use async/await, not callbacks. All types must be Sendable.",
        tools: nil, maxSteps: nil, fileRoles: nil
      ),
      MicroSkill(
        name: "explain-only",
        domain: "*", taskTypes: ["explain"],
        hint: "Read-only task. Do NOT edit or write files. Only use read and search tools.",
        tools: ["read", "search", "bash"], maxSteps: 3, fileRoles: nil
      ),
      MicroSkill(
        name: "explore-only",
        domain: "*", taskTypes: ["explore"],
        hint: "Search and discovery only. Do NOT modify any files.",
        tools: ["read", "search", "bash"], maxSteps: 5, fileRoles: nil
      ),
      MicroSkill(
        name: "ralph-wiggum-loop",
        domain: "*", taskTypes: ["fix", "add", "refactor", "test"],
        hint: """
          LOOP DETECTION: If the last 2 observations show the same tool failing on the same target, \
          STOP. Re-read the file, try a different approach, or report and ask the user. \
          Never retry an identical failing action.
          """,
        tools: nil, maxSteps: nil, fileRoles: nil
      ),
      MicroSkill(
        name: "swift-docsearch",
        domain: "swift", taskTypes: ["fix", "add", "explain", "explore"],
        hint: """
          For API reference: SDK headers at Xcode.app/.../SDKs/MacOSX.sdk/usr/include/. \
          Swift interfaces: find Xcode.app -name '*.swiftinterface' | grep <Framework>. \
          symbolgraph-extract for full API symbols. DocC at ~/Library/Developer/Documentation/.
          """,
        tools: nil, maxSteps: nil, fileRoles: nil
      ),
      MicroSkill(
        name: "minimal-change",
        domain: "*", taskTypes: ["fix"],
        hint: """
          Change ONLY what is necessary. Do not refactor, rename, reformat surrounding code. \
          Do not add comments or type annotations to code you didn't change. Smallest correct diff wins.
          """,
        tools: nil, maxSteps: nil, fileRoles: nil
      ),
      MicroSkill(
        name: "debug-trace",
        domain: "*", taskTypes: ["fix"],
        hint: """
          Before editing, diagnose: read failing code, add print at entry and before suspect line, \
          run, read output. Only edit once you understand the root cause. Remove debug prints after.
          """,
        tools: nil, maxSteps: nil, fileRoles: nil
      ),
      MicroSkill(
        name: "swift-entitlements",
        domain: "swift", taskTypes: ["add"],
        hint: """
          Common macOS entitlement keys (use exact strings): \
          com.apple.security.app-sandbox, com.apple.security.network.client, \
          com.apple.security.network.server, com.apple.security.files.user-selected.read-write, \
          com.apple.security.files.user-selected.read-only, com.apple.security.device.audio-input, \
          com.apple.security.device.camera, com.apple.security.device.usb, \
          com.apple.security.application-groups, com.apple.security.personal-information.location. \
          iOS Info.plist privacy keys: NSCameraUsageDescription, NSMicrophoneUsageDescription, \
          NSLocationWhenInUseUsageDescription, NSPhotoLibraryUsageDescription, \
          NSHealthShareUsageDescription, NSCalendarsUsageDescription.
          """,
        tools: nil, maxSteps: nil, fileRoles: nil
      ),
      MicroSkill(
        name: "multi-edit-fix",
        domain: "swift", taskTypes: ["fix", "refactor"],
        hint: """
          For multi-location changes, plan multiple edit steps (signature then body) \
          or use patch tool (unified diff). Patch changes multiple locations in one step.
          """,
        tools: nil, maxSteps: nil, fileRoles: nil
      ),
      MicroSkill(
        name: "xcode-project-files",
        domain: "swift", taskTypes: ["add", "fix"],
        hint: """
          Never generate .pbxproj, .xcworkspace, or Package.resolved directly. \
          Edit Package.swift or project.yml instead. Package.resolved is auto-generated.
          """,
        tools: nil, maxSteps: nil, fileRoles: nil
      ),
      MicroSkill(
        name: "swift-package-manifest",
        domain: "swift", taskTypes: ["add"],
        hint: """
          Package.swift uses PackageDescription, NOT Foundation. Structure: \
          import PackageDescription; Package(name:, platforms:, products:, dependencies:, targets:). \
          This is a manifest, NOT a regular Swift source file.
          """,
        tools: nil, maxSteps: nil, fileRoles: nil
      ),
      MicroSkill(
        name: "dependency-add",
        domain: "*", taskTypes: ["add"],
        hint: """
          Verify dependency exists before adding. Pin to version range, not latest. \
          Use .package(url:from:). Run swift build after to confirm.
          """,
        tools: nil, maxSteps: nil, fileRoles: nil
      ),
      MicroSkill(
        name: "git-commit",
        domain: "*", taskTypes: ["add", "fix", "refactor"],
        hint: """
          Conventional commits (fix:, feat:, refactor:). Stage by name, never git add -A. \
          Never commit .env or credentials. Describe WHY, not WHAT.
          """,
        tools: nil, maxSteps: nil, fileRoles: nil
      ),
      MicroSkill(
        name: "swift-docc",
        domain: "swift", taskTypes: ["add", "explain", "refactor"],
        hint: """
          DocC: symbolgraph-extract → docc init → docc convert → docc preview. \
          Use /// triple-slash with - Parameters:, - Returns:, - Throws:. \
          Link symbols with ``MyType/myMethod(_:)`` (double backtick).
          """,
        tools: nil, maxSteps: nil, fileRoles: nil
      ),
    ]
  }

  // MARK: - Markdown Parsing

  /// Parse MicroSkills.md table format:
  /// | Name | Domain | TaskTypes | Hint |
  private func parseMarkdownSkills(_ content: String) -> [MicroSkill] {
    let lines = content.components(separatedBy: "\n")
    var skills: [MicroSkill] = []

    for line in lines {
      let cols = line.split(separator: "|").map { $0.trimmingCharacters(in: .whitespaces) }
      guard cols.count >= 4 else { continue }
      // Skip header and separator rows
      if cols[0].hasPrefix("-") || cols[0].lowercased() == "name" { continue }

      let taskTypes = cols[2].split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
      let hint = String(cols[3].prefix(800))  // Hard cap at ~200 tokens

      skills.append(MicroSkill(
        name: cols[0], domain: cols[1], taskTypes: taskTypes,
        hint: hint, tools: nil, maxSteps: nil, fileRoles: nil
      ))
    }

    return skills
  }
}
