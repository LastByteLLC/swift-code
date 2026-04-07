// TaskResolverTests.swift — Tests for recipe matching and task resolution

import Testing
import Foundation
@testable import JuncoKit

@Suite("TaskResolver")
struct TaskResolverTests {

  private func makeTempDir(files: [String: String] = [:]) throws -> String {
    let dir = NSTemporaryDirectory() + "junco-resolver-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for (name, content) in files {
      let path = "\(dir)/\(name)"
      let parent = (path as NSString).deletingLastPathComponent
      try FileManager.default.createDirectory(atPath: parent, withIntermediateDirectories: true)
      try content.write(toFile: path, atomically: true, encoding: .utf8)
    }
    return dir
  }

  private func cleanup(_ dir: String) {
    try? FileManager.default.removeItem(atPath: dir)
  }

  // MARK: - Recipe Matching

  @Test("simple create matches recipe")
  func simpleCreate() async throws {
    let dir = try makeTempDir()
    defer { cleanup(dir) }

    let resolver = TaskResolver(workingDirectory: dir)
    let intent = AgentIntent(
      domain: "swift", taskType: "add", complexity: "simple",
      mode: "build", targets: ["NewView.swift"]
    )

    let tasks = await resolver.matchRecipe(
      query: "Create a new SwiftUI view",
      intent: intent,
      snapshot: .empty,
      index: [],
      explicitContext: ""
    )

    #expect(tasks != nil, "Simple create should match recipe")
    #expect(tasks?.count == 1)
    #expect(tasks?.first?.action == .create)
    #expect(tasks?.first?.target == "NewView.swift")
  }

  @Test("fix matches recipe for existing file")
  func fixExisting() async throws {
    let dir = try makeTempDir(files: ["Bug.swift": "let x = 1"])
    defer { cleanup(dir) }

    let resolver = TaskResolver(workingDirectory: dir)
    let intent = AgentIntent(
      domain: "swift", taskType: "fix", complexity: "simple",
      mode: "build", targets: ["Bug.swift"]
    )

    let tasks = await resolver.matchRecipe(
      query: "Fix the bug",
      intent: intent,
      snapshot: .empty,
      index: [],
      explicitContext: ""
    )

    #expect(tasks != nil, "Fix for existing file should match recipe")
    #expect(tasks?.first?.action == .edit)
    #expect(tasks?.first?.specification.contains("let x = 1") == true, "Spec should include file content")
  }

  @Test("fix returns nil for non-existent file")
  func fixNonExistent() async throws {
    let dir = try makeTempDir()
    defer { cleanup(dir) }

    let resolver = TaskResolver(workingDirectory: dir)
    let intent = AgentIntent(
      domain: "swift", taskType: "fix", complexity: "simple",
      mode: "build", targets: ["Missing.swift"]
    )

    let tasks = await resolver.matchRecipe(
      query: "Fix the bug",
      intent: intent,
      snapshot: .empty,
      index: [],
      explicitContext: ""
    )

    #expect(tasks == nil, "Fix for non-existent file should not match recipe")
  }

  @Test("test recipe creates test file")
  func testRecipe() async throws {
    let dir = try makeTempDir()
    defer { cleanup(dir) }

    let resolver = TaskResolver(workingDirectory: dir)
    let intent = AgentIntent(
      domain: "swift", taskType: "test", complexity: "simple",
      mode: "build", targets: ["UserService"]
    )

    let snapshot = ProjectSnapshot(
      models: [],
      views: [],
      services: [TypeSummary(name: "UserService", file: "UserService.swift", kind: "actor",
                             methods: ["fetchAll", "create"])],
      navigationPattern: nil,
      testPattern: "Swift Testing @Test (2 test files)",
      keyFiles: [:]
    )

    let tasks = await resolver.matchRecipe(
      query: "Write tests for UserService",
      intent: intent,
      snapshot: snapshot,
      index: [],
      explicitContext: ""
    )

    #expect(tasks != nil)
    #expect(tasks?.first?.action == .create)
    #expect(tasks?.first?.target.contains("Tests") == true)
    #expect(tasks?.first?.specification.contains("UserService") == true)
    #expect(tasks?.first?.specification.contains("@Test") == true)
  }

  @Test("explain recipe returns explain action")
  func explainRecipe() async throws {
    let dir = try makeTempDir()
    defer { cleanup(dir) }

    let resolver = TaskResolver(workingDirectory: dir)
    let intent = AgentIntent(
      domain: "swift", taskType: "explain", complexity: "simple",
      mode: "answer", targets: []
    )

    let tasks = await resolver.matchRecipe(
      query: "Explain how the auth works",
      intent: intent,
      snapshot: .empty,
      index: [],
      explicitContext: "func authenticate() { ... }"
    )

    #expect(tasks != nil)
    #expect(tasks?.first?.action == .explain)
  }

  @Test("unknown task type returns nil")
  func unknownType() async throws {
    let dir = try makeTempDir()
    defer { cleanup(dir) }

    let resolver = TaskResolver(workingDirectory: dir)
    let intent = AgentIntent(
      domain: "swift", taskType: "deploy", complexity: "simple",
      mode: "build", targets: []
    )

    let tasks = await resolver.matchRecipe(
      query: "Deploy to production",
      intent: intent,
      snapshot: .empty,
      index: [],
      explicitContext: ""
    )

    #expect(tasks == nil, "Unknown task type should not match any recipe")
  }

  // MARK: - Specification Quality

  @Test("create specification includes project context")
  func createSpecIncludesContext() throws {
    let dir = try makeTempDir()
    defer { cleanup(dir) }

    let resolver = TaskResolver(workingDirectory: dir)
    let snapshot = ProjectSnapshot(
      models: [TypeSummary(name: "Podcast", file: "Podcast.swift", kind: "struct",
                           properties: ["id", "name", "artist"])],
      views: [TypeSummary(name: "PodcastListView", file: "PodcastListView.swift", kind: "struct")],
      services: [],
      navigationPattern: "NavigationStack in App.swift",
      testPattern: nil,
      keyFiles: [:]
    )

    let spec = resolver.buildCreateSpecification(
      target: "PodcastPlayerView.swift",
      query: "Create a podcast player view with thumbnail and scrubber",
      snapshot: snapshot,
      explicitContext: ""
    )

    #expect(spec.contains("Podcast"), "Spec should reference existing models")
    #expect(spec.contains("PodcastListView"), "Spec should reference existing views")
    #expect(spec.contains("NavigationStack"), "Spec should reference navigation pattern")
    #expect(spec.contains("thumbnail"), "Spec should include user requirements")
  }

  @Test("create specification includes URLs")
  func createSpecIncludesURLs() throws {
    let dir = try makeTempDir()
    defer { cleanup(dir) }

    let resolver = TaskResolver(workingDirectory: dir)
    let spec = resolver.buildCreateSpecification(
      target: "app.js",
      query: "Create app.js that fetches from https://itunes.apple.com/search",
      snapshot: .empty,
      explicitContext: ""
    )

    #expect(spec.contains("https://itunes.apple.com/search"), "Spec should preserve URLs")
  }
}
