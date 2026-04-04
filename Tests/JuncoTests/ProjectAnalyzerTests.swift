// ProjectAnalyzerTests.swift — Tests for ProjectAnalyzer

import Testing
import Foundation
@testable import JuncoKit

@Suite("ProjectAnalyzer")
struct ProjectAnalyzerTests {

  @Test("analyzes Junco project and finds types")
  func analyzeSelf() {
    let dir = FileManager.default.currentDirectoryPath
    let files = FileTools(workingDirectory: dir)
    let indexer = FileIndexer(workingDirectory: dir)
    let index = indexer.indexProject(extensions: ["swift"])
    let domain = DomainDetector(workingDirectory: dir).detect()

    let analyzer = ProjectAnalyzer()
    let snapshot = analyzer.analyze(index: index, domain: domain, files: files)

    // Should find some types
    let allTypes = snapshot.models + snapshot.views + snapshot.services
    #expect(!allTypes.isEmpty, "Should find types in the project")
  }

  @Test("compact description fits within budget")
  func compactFitsBudget() {
    let snapshot = ProjectSnapshot(
      models: [
        TypeSummary(name: "Podcast", file: "Podcast.swift", kind: "struct",
                    properties: ["id", "name", "artist", "artworkURL"],
                    conformances: ["Identifiable", "Codable"]),
        TypeSummary(name: "Episode", file: "Episode.swift", kind: "struct",
                    properties: ["id", "title", "duration", "streamURL"],
                    conformances: ["Identifiable"]),
      ],
      views: [
        TypeSummary(name: "PodcastListView", file: "PodcastListView.swift", kind: "struct",
                    conformances: ["View"]),
        TypeSummary(name: "PodcastDetailView", file: "PodcastDetailView.swift", kind: "struct",
                    conformances: ["View"]),
      ],
      services: [
        TypeSummary(name: "PodcastService", file: "PodcastService.swift", kind: "actor",
                    methods: ["fetchTopPodcasts", "searchPodcasts", "fetchEpisodes"]),
      ],
      navigationPattern: "NavigationStack in PodcastApp.swift",
      testPattern: "Swift Testing @Test (3 test files)",
      keyFiles: ["entry": "PodcastApp.swift"]
    )

    let desc = snapshot.compactDescription(budget: 400)
    let tokens = TokenBudget.estimate(desc)
    #expect(tokens <= 450, "Compact description used \(tokens) tokens, budget was 400")
    #expect(desc.contains("Podcast"))
    #expect(desc.contains("PodcastListView"))
    #expect(desc.contains("PodcastService"))
    #expect(desc.contains("NavigationStack"))
  }

  @Test("empty snapshot returns empty description")
  func emptySnapshot() {
    let desc = ProjectSnapshot.empty.compactDescription()
    #expect(desc.isEmpty)
  }

  @Test("type classification by conformance")
  func typeClassification() {
    let dir = NSTemporaryDirectory() + "junco-analyzer-test-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let files = FileTools(workingDirectory: dir)
    let analyzer = ProjectAnalyzer()

    // Create index entries that mimic a real project
    let index: [IndexEntry] = [
      IndexEntry(filePath: "Model.swift", symbolName: "User", kind: .type, lineNumber: 1,
                 snippet: "struct User: Codable, Identifiable {\n  let id: String\n  let name: String"),
      IndexEntry(filePath: "Model.swift", symbolName: "id", kind: .property, lineNumber: 2, snippet: "let id: String"),
      IndexEntry(filePath: "Model.swift", symbolName: "name", kind: .property, lineNumber: 3, snippet: "let name: String"),
      IndexEntry(filePath: "UserView.swift", symbolName: "UserView", kind: .type, lineNumber: 1,
                 snippet: "struct UserView: View {"),
      IndexEntry(filePath: "DataService.swift", symbolName: "DataService", kind: .type, lineNumber: 1,
                 snippet: "actor DataService {"),
      IndexEntry(filePath: "DataService.swift", symbolName: "fetchAll", kind: .function, lineNumber: 5,
                 snippet: "func fetchAll() async throws"),
    ]

    let domain = DomainConfig(kind: .swift, displayName: "Swift", fileExtensions: ["swift"],
                              buildCommand: nil, testCommand: nil, lintCommand: nil,
                              promptHint: "", markers: ["Package.swift"])
    let snapshot = analyzer.analyze(index: index, domain: domain, files: files)

    #expect(snapshot.models.contains { $0.name == "User" }, "User should be a model")
    #expect(snapshot.views.contains { $0.name == "UserView" }, "UserView should be a view")
    #expect(snapshot.services.contains { $0.name == "DataService" }, "DataService should be a service")
  }
}
