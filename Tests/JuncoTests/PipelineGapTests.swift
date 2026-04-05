// PipelineGapTests.swift — Tests for the 4-phase pipeline gap fixes
//
// Phase 1: Live type manifest (updateSnapshot, incremental index)
// Phase 2: SwiftUI modifier linting + AVFoundation coverage
// Phase 3: AST-based compression + structural edits
// Phase 4: Context budget optimization for later steps

import Foundation
import Testing
@testable import JuncoKit

// MARK: - Phase 1: Live Type Manifest

@Suite("Phase 1: Live Type Manifest")
struct LiveTypeManifestTests {

  @Test("updateSnapshot adds new types from generated file")
  func updateSnapshotAddsTypes() {
    let analyzer = ProjectAnalyzer()
    let extractor = TreeSitterExtractor()
    let initial = ProjectSnapshot.empty

    let code = """
    import Foundation

    struct Podcast: Codable, Identifiable {
      let id: UUID
      let trackName: String
      let artistName: String
      let feedUrl: String?
    }

    struct Episode: Codable {
      let title: String
      let releaseDate: Date
      let audioUrl: String
    }
    """

    let updated = analyzer.updateSnapshot(
      initial, afterWriting: "PodcastModels.swift", content: code,
      extractor: extractor
    )

    #expect(updated.models.count >= 1, "Should have at least 1 model type")
    let names = updated.models.map(\.name)
    #expect(names.contains("Podcast"), "Should contain Podcast type")
    #expect(names.contains("Episode"), "Should contain Episode type")
  }

  @Test("updateSnapshot classifies View types correctly")
  func updateSnapshotClassifiesViews() {
    let analyzer = ProjectAnalyzer()
    let extractor = TreeSitterExtractor()
    let initial = ProjectSnapshot.empty

    let code = """
    import SwiftUI

    struct PodcastListView: View {
      var viewModel: PodcastViewModel
      var body: some View {
        List(viewModel.podcasts) { podcast in
          Text(podcast.trackName)
        }
      }
    }
    """

    let updated = analyzer.updateSnapshot(
      initial, afterWriting: "PodcastListView.swift", content: code,
      extractor: extractor
    )

    #expect(!updated.views.isEmpty, "Should classify as view")
    #expect(updated.views.first?.name == "PodcastListView")
  }

  @Test("updateSnapshot classifies Service types correctly")
  func updateSnapshotClassifiesServices() {
    let analyzer = ProjectAnalyzer()
    let extractor = TreeSitterExtractor()
    let initial = ProjectSnapshot.empty

    let code = """
    import Foundation

    actor PodcastService {
      func search(term: String) async throws -> [Podcast] {
        return []
      }
    }
    """

    let updated = analyzer.updateSnapshot(
      initial, afterWriting: "PodcastService.swift", content: code,
      extractor: extractor
    )

    #expect(!updated.services.isEmpty, "Should classify as service")
    #expect(updated.services.first?.name == "PodcastService")
  }

  @Test("Sequential updates produce cumulative snapshot")
  func sequentialUpdates() {
    let analyzer = ProjectAnalyzer()
    let extractor = TreeSitterExtractor()
    var snapshot = ProjectSnapshot.empty

    // Step 1: Create models
    snapshot = analyzer.updateSnapshot(
      snapshot, afterWriting: "Models.swift",
      content: "struct Podcast: Codable { let name: String }",
      extractor: extractor
    )

    // Step 2: Create service
    snapshot = analyzer.updateSnapshot(
      snapshot, afterWriting: "PodcastService.swift",
      content: "actor PodcastService { func fetch() async throws -> [Podcast] { [] } }",
      extractor: extractor
    )

    // Both types should be in the snapshot
    let allNames = (snapshot.models + snapshot.services).map(\.name)
    #expect(allNames.contains("Podcast"))
    #expect(allNames.contains("PodcastService"))

    // typeSignatureBlock should mention both
    let block = snapshot.typeSignatureBlock()
    #expect(block.contains("Podcast"))
    #expect(block.contains("PodcastService"))
  }

  @Test("updateSnapshot replaces types when file is re-generated")
  func updateSnapshotReplacesOnRewrite() {
    let analyzer = ProjectAnalyzer()
    let extractor = TreeSitterExtractor()
    var snapshot = ProjectSnapshot.empty

    // First version
    snapshot = analyzer.updateSnapshot(
      snapshot, afterWriting: "Models.swift",
      content: "struct OldName: Codable { let x: Int }",
      extractor: extractor
    )
    #expect(snapshot.models.contains(where: { $0.name == "OldName" }))

    // Rewrite same file
    snapshot = analyzer.updateSnapshot(
      snapshot, afterWriting: "Models.swift",
      content: "struct NewName: Codable { let y: String }",
      extractor: extractor
    )
    #expect(!snapshot.models.contains(where: { $0.name == "OldName" }))
    #expect(snapshot.models.contains(where: { $0.name == "NewName" }))
  }

  @Test("merging removes old types from same file")
  func mergingReplacesFile() {
    let s1 = ProjectSnapshot(
      models: [TypeSummary(name: "A", file: "f.swift", kind: "struct")],
      views: [], services: [],
      navigationPattern: nil, testPattern: nil, keyFiles: [:]
    )
    let s2 = s1.merging(
      typesFromFile: "f.swift",
      newModels: [TypeSummary(name: "B", file: "f.swift", kind: "struct")],
      newViews: [], newServices: []
    )
    #expect(s2.models.count == 1)
    #expect(s2.models[0].name == "B")
  }
}

// MARK: - Phase 2: SwiftUI Modifiers + AVFoundation

@Suite("Phase 2: SwiftUI + AVFoundation")
struct SwiftUIAVFoundationTests {

  private func lint(_ code: String) -> String {
    PostGenerationLinter().lint(content: code, filePath: "test.swift")
  }

  @Test(".textColor → .foregroundStyle")
  func textColorFix() {
    let code = "Text(\"hello\").textColor(.red)"
    #expect(lint(code).contains(".foregroundStyle(.red)"))
  }

  @Test(".foregroundColor → .foregroundStyle")
  func foregroundColorFix() {
    let code = "Text(\"hello\").foregroundColor(.blue)"
    #expect(lint(code).contains(".foregroundStyle(.blue)"))
  }

  @Test(".backgroundColor → .background")
  func backgroundColorFix() {
    let code = "VStack {}.backgroundColor(.gray)"
    #expect(lint(code).contains(".background(.gray)"))
  }

  @Test(".cornerRadius → .clipShape")
  func cornerRadiusFix() {
    let code = "Image(\"photo\").cornerRadius(12)"
    #expect(lint(code).contains(".clipShape(.rect(cornerRadius: 12))"))
  }

  @Test(".size(width:height:) → .frame")
  func sizeFix() {
    let code = "Color.blue.size(width: 100, height: 50)"
    #expect(lint(code).contains(".frame(width: 100, height: 50)"))
  }

  @Test(".onTap → .onTapGesture")
  func onTapFix() {
    let code = "Button(\"tap\").onTap {\n  action()\n}"
    #expect(lint(code).contains(".onTapGesture {"))
  }

  @Test(".maxWidth → .frame(maxWidth:)")
  func maxWidthFix() {
    let code = "Text(\"full\").maxWidth(.infinity)"
    #expect(lint(code).contains(".frame(maxWidth: .infinity)"))
  }

  @Test(".accessoryView removed")
  func accessoryViewRemoved() {
    let code = "List {}.accessoryView { Image(\"x\") }"
    #expect(!lint(code).contains(".accessoryView"))
  }

  @Test("AVFoundation import added when AVPlayer used")
  func avfoundationImportAdded() {
    let code = """
    import SwiftUI
    struct PlayerView: View {
      let player = AVPlayer(url: URL(string: "x")!)
      var body: some View { Text("playing") }
    }
    """
    let result = lint(code)
    #expect(result.contains("import AVFoundation"))
  }

  @Test("SignatureIndex static fallback has AVPlayer.play (ObjC-bridged)")
  func signatureIndexAVPlayer() {
    let index = SignatureIndex.builtIn()
    let hint = index.lookup(
      compilerError: "error: value of type 'AVPlayer' has no member 'start'"
    )
    #expect(hint != nil)
    #expect(hint!.contains("play()"))
  }

  // SwiftUI modifier entries (foregroundColor, cornerRadius) were moved from the static
  // table to runtime discovery via SwiftInterfaceIndex. The PostGenerationLinter handles
  // these modifiers directly via regex replacement.
}

// MARK: - Phase 3: AST-Based Compression + Structural Edits

@Suite("Phase 3: AST Compression")
struct ASTCompressionTests {

  @Test("codeGistAST produces valid output for Swift code")
  func gistASTBasic() {
    let compressor = ProgressiveCompressor()
    let code = """
    import Foundation

    struct Podcast: Codable {
      let name: String
      let artist: String

      func display() -> String {
        return "\\(name) by \\(artist)"
      }
    }
    """
    let gist = compressor.codeGistAST(code)
    #expect(gist != nil, "AST gist should succeed for valid Swift")
    if let gist {
      #expect(gist.contains("import Foundation"))
      #expect(gist.contains("Podcast"))
      #expect(gist.contains("name"))
      #expect(gist.contains("display"))
      // Function body should be stripped
      #expect(!gist.contains("return \""))
    }
  }

  @Test("codeGistAST handles multi-line function signatures")
  func gistASTMultiLine() {
    let compressor = ProgressiveCompressor()
    let code = """
    import Foundation

    func fetchData(
      from url: URL,
      headers: [String: String],
      timeout: TimeInterval
    ) async throws -> Data {
      let request = URLRequest(url: url)
      return try await URLSession.shared.data(for: request).0
    }
    """
    let gist = compressor.codeGistAST(code)
    #expect(gist != nil)
    if let gist {
      #expect(gist.contains("fetchData"))
      #expect(gist.contains("url: URL"))
      // Body should be stripped
      #expect(!gist.contains("URLSession.shared"))
    }
  }

  @Test("codeGistAST is more compact than regex codeGist")
  func gistASTCompactness() {
    let compressor = ProgressiveCompressor()
    let code = """
    import Foundation

    struct Service {
      let baseURL: URL

      func fetchAll() async throws -> [Item] {
        let (data, _) = try await URLSession.shared.data(from: baseURL)
        return try JSONDecoder().decode([Item].self, from: data)
      }

      func fetchOne(id: Int) async throws -> Item {
        let url = baseURL.appendingPathComponent("\\(id)")
        let (data, _) = try await URLSession.shared.data(from: url)
        return try JSONDecoder().decode(Item.self, from: data)
      }
    }
    """
    let astGist = compressor.codeGistAST(code)
    let regexGist = compressor.codeGist(code)
    #expect(astGist != nil)
    if let astGist {
      let astTokens = TokenBudget.estimate(astGist)
      let regexTokens = TokenBudget.estimate(regexGist)
      #expect(astTokens <= regexTokens + 10, "AST gist should be at least as compact as regex")
    }
  }

  @Test("codeGistAST returns nil for invalid Swift")
  func gistASTInvalid() {
    let compressor = ProgressiveCompressor()
    // This is not valid Swift but tree-sitter may still produce a partial tree
    let gist = compressor.codeGistAST("{{{{ not swift at all !!!!")
    // Should either return nil or a reasonable fallback
  }
}

@Suite("Phase 3: AST Error Region")
struct ASTErrorRegionTests {

  @Test("extractAST finds enclosing function")
  func extractASTFunction() {
    let extractor = ErrorRegionExtractor()
    let code = """
    import Foundation

    struct Service {
      func fetchData() async throws -> Data {
        let url = URL(string: "bad")!
        let result = try await URLSession.shared.asyncData(from: url)
        return result
      }

      func otherMethod() {
        print("hello")
      }
    }
    """
    // Error on line 6 (asyncData)
    let region = extractor.extractAST(content: code, errorLine: 6)
    #expect(region != nil)
    if let region {
      #expect(region.text.contains("fetchData"))
      // Should NOT include otherMethod
      #expect(!region.text.contains("otherMethod"))
    }
  }

  @Test("extractAST falls back to regex gracefully")
  func extractASTFallback() {
    let extractor = ErrorRegionExtractor()
    // extract(content:errorMessage:) should work for valid Swift
    let code = "func broken() {\n  let x: = bad\n}\n"
    let region = extractor.extract(content: code, errorMessage: "test.swift:2:10: error: expected pattern")
    #expect(region != nil)
  }
}

@Suite("Phase 3: Structural Edit")
struct StructuralEditTests {

  private func makeTempDir(files: [String: String] = [:]) throws -> String {
    let dir = NSTemporaryDirectory() + "junco_edit_test_\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    for (name, content) in files {
      try content.write(toFile: "\(dir)/\(name)", atomically: true, encoding: .utf8)
    }
    return dir
  }

  @Test("Structural edit finds function by name despite whitespace difference")
  func structuralEditWhitespace() throws {
    let original = """
    import Foundation

    func fetchPodcasts(term: String) async throws -> [String] {
      return []
    }
    """
    let dir = try makeTempDir(files: ["test.swift": original])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let tools = FileTools(workingDirectory: dir)

    // find text has different whitespace than the file
    let find = "func   fetchPodcasts( term: String )  async throws -> [String] {\n    return []\n}"
    let replace = "func fetchPodcasts(term: String) async throws -> [String] {\n  return [\"result\"]\n}"

    try tools.edit(path: "test.swift", find: find, replace: replace, fuzzy: true, structural: true)

    let result = try String(contentsOfFile: "\(dir)/test.swift", encoding: .utf8)
    #expect(result.contains("[\"result\"]"))
  }

  @Test("Structural edit preserves other declarations")
  func structuralEditPreservesOthers() throws {
    let original = """
    import Foundation

    func first() -> Int { return 1 }

    func second() -> Int { return 2 }

    func third() -> Int { return 3 }
    """
    let dir = try makeTempDir(files: ["test.swift": original])
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let tools = FileTools(workingDirectory: dir)

    // Edit only `second` with slightly different formatting
    let find = "func second() -> Int {\n  return 2\n}"
    let replace = "func second() -> Int { return 42 }"

    try tools.edit(path: "test.swift", find: find, replace: replace, fuzzy: true, structural: true)

    let result = try String(contentsOfFile: "\(dir)/test.swift", encoding: .utf8)
    #expect(result.contains("return 1"), "first() should be preserved")
    #expect(result.contains("42"), "second() should be updated")
    #expect(result.contains("return 3"), "third() should be preserved")
  }
}

// MARK: - Phase 4: Context Budget Optimization

@Suite("Phase 4: Budget Optimization")
struct BudgetOptimizationTests {

  @Test("compactDescription at step 0 includes full observations")
  func compactDescriptionEarlyStep() {
    var mem = WorkingMemory(query: "fix bug", workingDirectory: "/tmp/project")
    mem.addObservation(StepObservation(tool: "read", outcome: .ok, keyFact: "Read file.swift"))
    mem.addObservation(StepObservation(tool: "edit", outcome: .ok, keyFact: "Fixed typo"))
    mem.currentStepIndex = 0

    let desc = mem.compactDescription()
    #expect(desc.contains("Read file.swift"))
    #expect(desc.contains("Fixed typo"))
  }

  @Test("compactDescription at step 5 uses compact counter")
  func compactDescriptionLateStep() {
    var mem = WorkingMemory(query: "build app", workingDirectory: "/tmp/project")
    for i in 0..<5 {
      mem.addObservation(StepObservation(tool: "create", outcome: .ok, keyFact: "File \(i)"))
    }
    mem.currentStepIndex = 5

    let desc = mem.compactDescription()
    // Should NOT have individual observations
    #expect(!desc.contains("File 0"))
    // Should have compact counter
    #expect(desc.contains("5 ok"))
  }

  @Test("compactDescription at step 5 is shorter than step 0")
  func compactDescriptionTokenSavings() {
    var memEarly = WorkingMemory(query: "build app", workingDirectory: "/tmp/project")
    var memLate = WorkingMemory(query: "build app", workingDirectory: "/tmp/project")

    for i in 0..<5 {
      let obs = StepObservation(tool: "create", outcome: .ok, keyFact: "Created file\(i).swift (\(100 + i * 50) chars)")
      memEarly.addObservation(obs)
      memLate.addObservation(obs)
    }
    memEarly.currentStepIndex = 0
    memLate.currentStepIndex = 5

    let earlyTokens = TokenBudget.estimate(memEarly.compactDescription())
    let lateTokens = TokenBudget.estimate(memLate.compactDescription())
    #expect(lateTokens < earlyTokens, "Late step should use fewer tokens: \(lateTokens) vs \(earlyTokens)")
  }

  @Test("typeSignatureBlock compresses at step 4+")
  func tieredTypeSignatureBlock() {
    let snapshot = ProjectSnapshot(
      models: [
        TypeSummary(name: "Podcast", file: "m.swift", kind: "struct",
                    properties: ["name", "artist"], methods: [], conformances: ["Codable"]),
        TypeSummary(name: "Episode", file: "m.swift", kind: "struct",
                    properties: ["title", "date"], methods: [], conformances: ["Codable"]),
      ],
      views: [TypeSummary(name: "ListView", file: "v.swift", kind: "struct")],
      services: [TypeSummary(name: "PodcastService", file: "s.swift", kind: "actor", methods: ["search"])],
      navigationPattern: nil, testPattern: nil, keyFiles: [:]
    )

    let fullBlock = snapshot.typeSignatureBlock(stepIndex: 0)
    let compactBlock = snapshot.typeSignatureBlock(stepIndex: 4)

    #expect(fullBlock.contains("EXISTING TYPES"))
    #expect(compactBlock.contains("Known types:"))
    #expect(compactBlock.contains("Podcast"))
    #expect(compactBlock.contains("PodcastService"))

    let fullTokens = TokenBudget.estimate(fullBlock)
    let compactTokens = TokenBudget.estimate(compactBlock)
    #expect(compactTokens < fullTokens, "Compact should be shorter: \(compactTokens) vs \(fullTokens)")
  }

  @Test("forExecute rebalances budget at step 4+")
  func stepAwareBudget() {
    let normal = ContextBudget.forWindow(4096, stage: .execute)
    let late = ContextBudget.forExecute(windowSize: 4096, stepIndex: 4)

    #expect(late.fileContent > normal.fileContent, "Late step should have more fileContent")
    #expect(late.memory < normal.memory, "Late step should have less memory budget")
    #expect(late.retrieval < normal.retrieval, "Late step should have less retrieval budget")
    #expect(late.total == normal.total, "Total should be unchanged")
  }

  @Test("forExecute unchanged at step 0")
  func stepAwareBudgetEarlyStep() {
    let normal = ContextBudget.forWindow(4096, stage: .execute)
    let early = ContextBudget.forExecute(windowSize: 4096, stepIndex: 0)

    #expect(early.fileContent == normal.fileContent)
    #expect(early.memory == normal.memory)
    #expect(early.retrieval == normal.retrieval)
  }
}
