// SnapshotDrivenTemplateTests.swift — Tests for the snapshot-driven template system
//
// Phase 1: Template robustness (sanitization, validation)
// Phase 2: ObservableObject → @Observable linter
// Phase 3: SnapshotDeriver + reduced intents
// Phase 4: App scaffold recipe

import Foundation
import Testing
@testable import JuncoKit

// MARK: - Phase 1: Template Robustness

@Suite("Phase 1: Template Robustness")
struct TemplateRobustnessTests {

  @Test("Param name sanitization strips trailing =")
  func sanitizeParamNames() {
    let renderer = TemplateRenderer()
    let intent = ServiceFlatIntent(
      actorName: "TestService",
      methodName: "search",
      methodParams: "term: String",
      returnType: "String",
      baseURL: "https://example.com/api",
      queryParamNames: "term=,media=",  // Model adds trailing =
      fixedParams: "media=podcast"
    )
    let code = renderer.renderServiceFlat(intent)
    // Should produce "term", not "term="
    #expect(code.contains("\"term\""))
    #expect(!code.contains("\"term=\""))
    #expect(code.contains("\"media\""))
    #expect(!code.contains("\"media=\""))
  }

  @Test("validateTemplateOutput catches ViewModel without class or @Observable")
  func validateEmptyViewModel() {
    let renderer = TemplateRenderer()
    // A struct ViewModel should fail validation — needs class + @Observable
    let empty = "import Foundation\n\nstruct PodcastViewModel {\n    var x = 0\n}\n"
    let error = renderer.validateTemplateOutput(empty, filePath: "PodcastViewModel.swift")
    #expect(error != nil, "ViewModel without class or @Observable should fail validation")
  }

  @Test("validateTemplateOutput accepts valid ViewModel")
  func validateGoodViewModel() {
    let renderer = TemplateRenderer()
    let good = """
    import Foundation

    @Observable
    class PodcastViewModel {
        var podcasts: [Podcast] = []
        func search() async { }
    }
    """
    let error = renderer.validateTemplateOutput(good, filePath: "PodcastViewModel.swift")
    #expect(error == nil)
  }

  @Test("validateTemplateOutput catches unbalanced braces")
  func validateUnbalancedBraces() {
    let renderer = TemplateRenderer()
    let bad = "struct X {\n  func f() {\n  }\n"
    let error = renderer.validateTemplateOutput(bad, filePath: "test.swift")
    #expect(error?.contains("braces") == true)
  }

  @Test("validateTemplateOutput catches too-short output")
  func validateTooShort() {
    let renderer = TemplateRenderer()
    let error = renderer.validateTemplateOutput("import X\n", filePath: "test.swift")
    #expect(error?.contains("too short") == true)
  }

  @Test("validateTemplateOutput passes non-Swift files")
  func validateNonSwift() {
    let renderer = TemplateRenderer()
    let error = renderer.validateTemplateOutput("", filePath: "data.json")
    #expect(error == nil)
  }
}

// MARK: - Phase 2: ObservableObject → @Observable

@Suite("Phase 2: ObservableObject Linter")
struct ObservableObjectLinterTests {

  private func lint(_ code: String) -> String {
    PostGenerationLinter().lint(content: code, filePath: "test.swift")
  }

  @Test("struct ObservableObject → @Observable class")
  func structToObservableClass() {
    let input = """
    import SwiftUI

    struct MyViewModel: ObservableObject {
        @Published var items: [String] = []
        @Published var isLoading = false
    }
    """
    let result = lint(input)
    #expect(result.contains("@Observable"))
    #expect(result.contains("class MyViewModel"))
    #expect(!result.contains("struct MyViewModel"))
    #expect(!result.contains("ObservableObject"))
    #expect(!result.contains("@Published"))
  }

  @Test("class ObservableObject → @Observable class")
  func classToObservableClass() {
    let input = """
    import Combine

    class SettingsViewModel: ObservableObject {
        @Published var theme: String = "light"
    }
    """
    let result = lint(input)
    #expect(result.contains("@Observable"))
    #expect(result.contains("class SettingsViewModel"))
    #expect(!result.contains("ObservableObject"))
    #expect(!result.contains("@Published"))
    #expect(!result.contains("import Combine"))
  }

  @Test("Multiple conformances: keeps non-ObservableObject")
  func multipleConformances() {
    let input = """
    struct VM: ObservableObject, Identifiable {
        let id = UUID()
        @Published var name = ""
    }
    """
    let result = lint(input)
    #expect(result.contains("@Observable"))
    #expect(result.contains("class VM: Identifiable"))
    #expect(!result.contains("ObservableObject"))
  }

  @Test("Already @Observable: ObservableObject rule is no-op")
  func alreadyObservable() {
    let input = """
    import Foundation

    @Observable
    class VM {
        var items: [String] = []
    }
    """
    let result = lint(input)
    // The ObservableObject rule should be a no-op. Other rules may add imports,
    // so just check the core structure is preserved.
    #expect(result.contains("@Observable"))
    #expect(result.contains("class VM"))
    #expect(!result.contains("ObservableObject"))
    #expect(!result.contains("struct VM"))
  }

  @Test("No ObservableObject: no change")
  func noObservableObject() {
    let input = """
    struct Model: Codable {
        let name: String
    }
    """
    let result = lint(input)
    #expect(result == input)
  }

  @Test("Preserves Combine import when other Combine types used")
  func preservesCombineImport() {
    let input = """
    import Combine

    class VM: ObservableObject {
        @Published var x = 0
        var cancellables = Set<AnyCancellable>()
    }
    """
    let result = lint(input)
    #expect(result.contains("@Observable"))
    #expect(result.contains("import Combine"))
  }

  @Test("Handles access modifier")
  func accessModifier() {
    let input = "public struct VM: ObservableObject {\n    @Published var x = 0\n}"
    let result = lint(input)
    #expect(result.contains("public class VM"))
    #expect(result.contains("@Observable"))
  }
}

// MARK: - Phase 3: SnapshotDeriver

@Suite("Phase 3: SnapshotDeriver")
struct SnapshotDeriverTests {

  @Test("deriveViewModel fills fields from snapshot")
  func deriveViewModel() {
    let deriver = SnapshotDeriver()
    let snapshot = ProjectSnapshot(
      models: [
        TypeSummary(name: "Podcast", file: "m.swift", kind: "struct",
                    properties: ["trackName", "artistName"],
                    conformances: ["Codable"]),
      ],
      views: [],
      services: [
        TypeSummary(name: "PodcastService", file: "s.swift", kind: "actor",
                    methods: ["searchPodcasts(term: String)"]),
      ],
      navigationPattern: nil, testPattern: nil, keyFiles: [:]
    )
    let reduced = ViewModelReducedIntent(
      className: "PodcastViewModel",
      property1: "var podcasts: [Podcast] = []",
      property2: "var searchText: String = \"\"",
      methodName: "search"
    )
    let result = deriver.deriveViewModel(reduced: reduced, snapshot: snapshot)
    #expect(result != nil)
    if let result {
      #expect(result.className == "PodcastViewModel")
      #expect(result.serviceName == "PodcastService")
      #expect(result.targetProperty == "podcasts")
      #expect(result.serviceCall.contains("searchPodcasts"))
      #expect(result.serviceCall.contains("searchText"))
    }
  }

  @Test("deriveViewModel returns nil without services")
  func deriveViewModelNoServices() {
    let deriver = SnapshotDeriver()
    let snapshot = ProjectSnapshot.empty
    let reduced = ViewModelReducedIntent(
      className: "VM", property1: "var x: [Int] = []",
      property2: "", methodName: "load"
    )
    #expect(deriver.deriveViewModel(reduced: reduced, snapshot: snapshot) == nil)
  }

  @Test("deriveListView fills fields from snapshot")
  func deriveListView() {
    let deriver = SnapshotDeriver()
    let snapshot = ProjectSnapshot(
      models: [
        TypeSummary(name: "Podcast", file: "m.swift", kind: "struct",
                    properties: ["trackName", "artistName"]),
        TypeSummary(name: "PodcastViewModel", file: "vm.swift", kind: "class",
                    properties: ["podcasts", "searchText"],
                    methods: ["search"]),
      ],
      views: [],
      services: [
        TypeSummary(name: "PodcastService", file: "s.swift", kind: "actor",
                    methods: ["searchPodcasts"]),
      ],
      navigationPattern: nil, testPattern: nil, keyFiles: [:]
    )
    let reduced = ListViewReducedIntent(
      viewName: "PodcastListView",
      navigationTitle: "Podcasts",
      itemType: "Podcast"
    )
    let result = deriver.deriveListView(reduced: reduced, snapshot: snapshot)
    #expect(result != nil)
    if let result {
      #expect(result.viewModelType == "PodcastViewModel")
      #expect(result.listProperty == "podcasts")
      #expect(result.titleProperty == "trackName")
      #expect(result.subtitleProperty == "artistName")
      #expect(result.searchProperty == "searchText")
      #expect(result.loadMethod == "search")
      #expect(result.navigationTitle == "Podcasts")
    }
  }

  @Test("deriveListView returns nil without ViewModel")
  func deriveListViewNoVM() {
    let deriver = SnapshotDeriver()
    let snapshot = ProjectSnapshot(
      models: [TypeSummary(name: "Podcast", file: "m.swift", kind: "struct", properties: ["name"])],
      views: [], services: [],
      navigationPattern: nil, testPattern: nil, keyFiles: [:]
    )
    let reduced = ListViewReducedIntent(viewName: "V", navigationTitle: "T", itemType: "Podcast")
    #expect(deriver.deriveListView(reduced: reduced, snapshot: snapshot) == nil)
  }

  @Test("extractPropertyName handles various formats")
  func extractPropertyName() {
    let d = SnapshotDeriver()
    #expect(d.extractPropertyName("var podcasts: [Podcast] = []") == "podcasts")
    #expect(d.extractPropertyName("let id: UUID") == "id")
    #expect(d.extractPropertyName("@Published var items: [Item] = []") == "items")
    #expect(d.extractPropertyName("searchText") == "searchText")
    #expect(d.extractPropertyName("var x: Int") == "x")
  }

  @Test("Derived ViewModel renders correctly")
  func derivedViewModelRenders() {
    let deriver = SnapshotDeriver()
    let snapshot = ProjectSnapshot(
      models: [], views: [],
      services: [
        TypeSummary(name: "WeatherService", file: "s.swift", kind: "actor",
                    methods: ["fetchWeather(city: String)"]),
      ],
      navigationPattern: nil, testPattern: nil, keyFiles: [:]
    )
    let reduced = ViewModelReducedIntent(
      className: "WeatherViewModel",
      property1: "var weather: Weather?",
      property2: "var city: String = \"\"",
      methodName: "load"
    )
    guard let full = deriver.deriveViewModel(reduced: reduced, snapshot: snapshot) else {
      Issue.record("Derivation returned nil")
      return
    }
    let code = TemplateRenderer().renderViewModelFlat(full)
    #expect(code.contains("@Observable"))
    #expect(code.contains("class WeatherViewModel"))
    #expect(code.contains("var weather: Weather?"))
    #expect(code.contains("private let service = WeatherService()"))
    #expect(code.contains("func load() async"))
  }
}

// MARK: - Phase 4: App Scaffold

@Suite("Phase 4: App Scaffold")
struct AppScaffoldTests {

  @Test("isAppScopeQuery detects app creation queries")
  func appScopeDetection() {
    #expect(TaskResolver.isAppScopeQuery("build a podcast app"))
    #expect(TaskResolver.isAppScopeQuery("create a weather application"))
    #expect(TaskResolver.isAppScopeQuery("make a recipe app with search"))
    #expect(TaskResolver.isAppScopeQuery("Build an iOS podcast app"))
  }

  @Test("isAppScopeQuery rejects non-app queries")
  func nonAppScope() {
    #expect(!TaskResolver.isAppScopeQuery("fix the login bug"))
    #expect(!TaskResolver.isAppScopeQuery("create PodcastService.swift"))
    #expect(!TaskResolver.isAppScopeQuery("explain how the app works"))
    #expect(!TaskResolver.isAppScopeQuery("add a search feature"))
  }

  @Test("inferAppDomain extracts domain noun")
  func inferDomain() {
    #expect(TaskResolver.inferAppDomain("build a podcast app") == "podcast")
    #expect(TaskResolver.inferAppDomain("create a weather application") == "weather")
    #expect(TaskResolver.inferAppDomain("make a recipe app") == "recipe")
    #expect(TaskResolver.inferAppDomain("build an expense app") == "expense")
  }

  @Test("inferAppDomain falls back to 'app' for unrecognized patterns")
  func inferDomainFallback() {
    #expect(TaskResolver.inferAppDomain("do something cool") == "app")
  }

  @Test("Reduced intents are Codable round-trippable")
  func reducedIntentCodable() throws {
    let vmIntent = ViewModelReducedIntent(
      className: "PodcastViewModel",
      property1: "var podcasts: [Podcast] = []",
      property2: "var searchText: String = \"\"",
      methodName: "search"
    )
    let vmData = try JSONEncoder().encode(vmIntent)
    let vmDecoded = try JSONDecoder().decode(ViewModelReducedIntent.self, from: vmData)
    #expect(vmDecoded.className == "PodcastViewModel")
    #expect(vmDecoded.methodName == "search")

    let lvIntent = ListViewReducedIntent(
      viewName: "PodcastListView",
      navigationTitle: "Podcasts",
      itemType: "Podcast"
    )
    let lvData = try JSONEncoder().encode(lvIntent)
    let lvDecoded = try JSONDecoder().decode(ListViewReducedIntent.self, from: lvData)
    #expect(lvDecoded.viewName == "PodcastListView")
    #expect(lvDecoded.itemType == "Podcast")
  }
}
