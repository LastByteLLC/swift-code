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

  /// Token cost of this skill's hint.
  public var tokenCost: Int { TokenBudget.estimate(hint) }
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

  /// Find skills matching a domain and task type.
  public func findSkills(domain: String, taskType: String) -> [MicroSkill] {
    loadAll().filter { skill in
      (skill.domain == domain || skill.domain == "*") &&
      skill.taskTypes.contains(taskType)
    }
  }

  /// Format matching skills as a prompt fragment, capped at a token budget.
  public func skillHints(domain: String, taskType: String, budget: Int = 200) -> String? {
    let matching = findSkills(domain: domain, taskType: taskType)
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
      MicroSkill(
        name: "swift-test",
        domain: "swift", taskTypes: ["test"],
        hint: "Use Swift Testing (@Test, #expect, #require). Prefer @Suite for grouping. Use async tests for actor code.",
        tools: nil, maxSteps: nil
      ),
      MicroSkill(
        name: "swift-concurrency",
        domain: "swift", taskTypes: ["fix", "refactor"],
        hint: "Use actors for shared state. Mark @MainActor for UI code. Use async/await, not callbacks. All types must be Sendable.",
        tools: nil, maxSteps: nil
      ),
      MicroSkill(
        name: "explain-only",
        domain: "*", taskTypes: ["explain"],
        hint: "Read-only task. Do NOT edit or write files. Only use read and search tools.",
        tools: ["read", "search", "bash"], maxSteps: 3
      ),
      MicroSkill(
        name: "explore-only",
        domain: "*", taskTypes: ["explore"],
        hint: "Search and discovery only. Do NOT modify any files.",
        tools: ["read", "search", "bash"], maxSteps: 5
      ),
      MicroSkill(
        name: "ralph-wiggum-loop",
        domain: "*", taskTypes: ["fix", "add", "refactor", "test"],
        hint: """
          LOOP DETECTION: If the last 2 observations show the same tool failing on the same target, \
          you are in a loop. STOP repeating the same action. Instead: \
          (1) re-read the file to get fresh content, \
          (2) try a completely different approach (different tool or different edit), \
          (3) if stuck after 3 attempts, report what you tried and ask the user. \
          Never retry an identical failing action.
          """,
        tools: nil, maxSteps: nil
      ),
      MicroSkill(
        name: "swift-docsearch",
        domain: "swift", taskTypes: ["fix", "add", "explain", "explore"],
        hint: """
          For API reference, search the host: \
          SDK headers at /Applications/Xcode.app/Contents/Developer/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk/usr/include/. \
          Swift interfaces via: find /Applications/Xcode.app -name '*.swiftinterface' | grep <Framework>. \
          Use `swift symbolgraph-extract --module-name <Module> --minimum-access-level public` for full API symbols. \
          DocC docs at ~/Library/Developer/Documentation/. \
          Man pages via `man <command>`. Check `xcrun --find <tool>` for tool paths. \
          Online documentation at https://developer.apple.com/documentation/
          """,
        tools: nil, maxSteps: nil
      ),
      MicroSkill(
        name: "minimal-change",
        domain: "*", taskTypes: ["fix"],
        hint: """
          Change ONLY what is necessary to fix the issue. Do not refactor, rename, reformat, \
          or reorganize surrounding code. Do not add comments, docstrings, or type annotations \
          to code you didn't change. Do not "improve" adjacent lines. The smallest correct diff wins.
          """,
        tools: nil, maxSteps: nil
      ),
      MicroSkill(
        name: "debug-trace",
        domain: "*", taskTypes: ["fix"],
        hint: """
          Before editing, diagnose first: read the failing code, add a print/console.log at \
          function entry and before the suspected line, run the code, read the output. \
          Only edit once you understand the root cause from the trace. \
          Remove debug prints after the fix is confirmed.
          """,
        tools: nil, maxSteps: nil
      ),
      MicroSkill(
        name: "swiftui-patterns",
        domain: "swift", taskTypes: ["add", "fix", "refactor"],
        hint: """
          @State for view-local state, @Binding for parent-owned, @Environment for DI. \
          Extract subviews over long body expressions. Never force-unwrap in view body. \
          Use .task {} not .onAppear for async work. Prefer value types. \
          IMPORTANT: Use @Observable, NOT ObservableObject. @Observable does NOT use @Published — \
          properties are tracked automatically. Use @ObservationIgnored to opt out. \
          Use @State (NOT @StateObject) for @Observable classes. \
          NavigationStack (not NavigationView). FormatStyle (not DateFormatter). \
          NavigationStack with .navigationDestination(for: Type.self) { item in DetailView(item: item) }. \
          Use NavigationLink(value: item) inside ForEach, not NavigationLink(destination:). \
          Do NOT use .fontSize() — use .font(.system(size:)). \
          Do NOT use Image(systemName:style:) — style parameter does not exist.
          """,
        tools: nil, maxSteps: nil
      ),
      MicroSkill(
        name: "swift-networking",
        domain: "swift", taskTypes: ["add", "fix"],
        hint: """
          URLSession pattern: let (data, _) = try await URLSession.shared.data(from: url). \
          JSON decode: try JSONDecoder().decode(T.self, from: data). \
          Raw JSON: try JSONSerialization.jsonObject(with: data) as? [String: Any]. \
          Do NOT use withCheckedThrowingContinuation for URLSession — use async/await directly.
          """,
        tools: nil, maxSteps: nil
      ),
      MicroSkill(
        name: "swift-async",
        domain: "swift", taskTypes: ["add", "fix"],
        hint: """
          When calling async throws functions, assign directly: let items = try await service.fetchAll(). \
          Do NOT use trailing closure callbacks after async calls. \
          WRONG: try await service.fetch { result in }. \
          RIGHT: let result = try await service.fetch(). \
          Wrap in do { try await ... } catch { } if enclosing function is not throws.
          """,
        tools: nil, maxSteps: nil
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
        tools: nil, maxSteps: nil
      ),
      MicroSkill(
        name: "multi-edit-fix",
        domain: "swift", taskTypes: ["fix", "refactor"],
        hint: """
          When a fix requires changing BOTH a function signature AND its body, plan multiple edit steps: \
          step 1: edit the signature (return type, parameters), step 2: edit the body. \
          For complex multi-location changes, use the patch tool (unified diff) instead of edit. \
          Patch can change multiple locations in one step.
          """,
        tools: nil, maxSteps: nil
      ),
      MicroSkill(
        name: "xcode-project-files",
        domain: "swift", taskTypes: ["add", "fix"],
        hint: """
          Never generate .pbxproj, .xcworkspace, or Package.resolved directly. \
          For SPM: edit Package.swift, run swift package resolve. \
          For XcodeGen: edit project.yml, run xcodegen generate. \
          Package.resolved is auto-generated — never edit it manually.
          """,
        tools: nil, maxSteps: nil
      ),
      MicroSkill(
        name: "swift-package-manifest",
        domain: "swift", taskTypes: ["add"],
        hint: """
          Package.swift uses PackageDescription, NOT Foundation. Structure: \
          import PackageDescription; let package = Package(name:, platforms: [.macOS(.v15), .iOS(.v18)], \
          products: [.library(name:, targets:)], dependencies: [.package(url:, from:)], \
          targets: [.target(name:, dependencies:), .testTarget(name:, dependencies:)]). \
          This is a manifest, NOT a regular Swift source file.
          """,
        tools: nil, maxSteps: nil
      ),
      MicroSkill(
        name: "dependency-add",
        domain: "*", taskTypes: ["add"],
        hint: """
          When adding a dependency: verify it exists before adding \
          (Swift: `swift package resolve`). \
          Pin to a version range, not latest. Use `.package(url:from:)`. \
          Run `swift build` after adding to confirm it resolves.
          """,
        tools: nil, maxSteps: nil
      ),
      MicroSkill(
        name: "git-commit",
        domain: "*", taskTypes: ["add", "fix", "refactor"],
        hint: """
          When committing: use conventional commit format (fix:, feat:, refactor:, test:, docs:). \
          Stage specific files by name, never `git add -A` or `git add .`. \
          Never commit .env, credentials, secrets, or build artifacts. \
          Write a concise message describing WHY, not WHAT (the diff shows what).
          """,
        tools: nil, maxSteps: nil
      ),
      MicroSkill(
        name: "swift-docc",
        domain: "swift", taskTypes: ["add", "explain", "refactor"],
        hint: """
          DocC documentation workflow: \
          1) Extract symbol graphs: `swift symbolgraph-extract --module-name <Module> \
          --minimum-access-level public --output-dir .build/symbol-graphs \
          -target arm64-apple-macosx26.0 -I .build/debug`. \
          2) Create a catalog: `xcrun docc init --name <Module> --output-dir Sources/<Module>.docc \
          --template articleOnly`. \
          3) Build docs: `xcrun docc convert Sources/<Module>.docc \
          --additional-symbol-graph-dir .build/symbol-graphs --output-path .build/docs`. \
          4) Preview locally: `xcrun docc preview Sources/<Module>.docc \
          --additional-symbol-graph-dir .build/symbol-graphs`. \
          Use `/// Triple-slash` comments with `- Parameters:`, `- Returns:`, `- Throws:` for symbols. \
          Use `## Topics` sections in extension files to organize the symbol sidebar. \
          Link to symbols with `` ``MyType/myMethod(_:)`` `` (double backtick).
          """,
        tools: nil, maxSteps: nil
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
        hint: hint, tools: nil, maxSteps: nil
      ))
    }

    return skills
  }
}
