// TemplateEvalTests.swift — Diverse domain eval for template rendering
//
// Tests template output correctness across 5 app domains to avoid
// overfitting to the podcast sample. Each domain tests the full
// Model → Service → ViewModel → View pipeline.
//
// Scoring criteria per file:
//   1. Compiles (swiftc -typecheck)
//   2. Correct API patterns (URLSession, JSONDecoder)
//   3. Correct property names (references real type members)
//   4. @Observable used (not ObservableObject)
//   5. No hallucinated modifiers

import Foundation
import Testing
@testable import JuncoKit

// MARK: - Template Renderer Output Tests

@Suite("Template Render: Service (Flat)")
struct ServiceFlatRenderTests {

  private let renderer = TemplateRenderer()

  @Test("Podcast service renders with URLComponents and decode")
  func podcastService() {
    let intent = ServiceFlatIntent(
      actorName: "PodcastService",
      methodName: "searchPodcasts",
      methodParams: "term: String",
      returnType: "[Podcast]",
      baseURL: "https://itunes.apple.com/search",
      queryParamNames: "term,media",
      fixedParams: "media=podcast"
    )
    let code = renderer.renderServiceFlat(intent)
    #expect(code.contains("actor PodcastService"))
    #expect(code.contains("func searchPodcasts(term: String) async throws -> [Podcast]"))
    #expect(code.contains("URLComponents"))
    #expect(code.contains("URLQueryItem"))
    #expect(code.contains("URLSession.shared.data(from:"))
    #expect(code.contains("JSONDecoder().decode"))
    #expect(code.contains("\"term\", value: term"))
    #expect(code.contains("\"media\", value: \"podcast\""))
  }

  @Test("Weather service renders correctly")
  func weatherService() {
    let intent = ServiceFlatIntent(
      actorName: "WeatherService",
      methodName: "fetchWeather",
      methodParams: "city: String",
      returnType: "Weather",
      baseURL: "https://api.openweathermap.org/data/2.5/weather",
      queryParamNames: "q,units,appid",
      fixedParams: "units=metric"
    )
    let code = renderer.renderServiceFlat(intent)
    #expect(code.contains("actor WeatherService"))
    #expect(code.contains("fetchWeather(city: String"))
    #expect(code.contains("URLQueryItem(name: \"q\", value: city)"))
    #expect(code.contains("\"units\", value: \"metric\""))
    #expect(!code.contains("[Weather]")) // single object, not array
    #expect(code.contains("decode(Weather.self"))
  }

  @Test("Book search service renders array decode with wrapper")
  func bookService() {
    let intent = ServiceFlatIntent(
      actorName: "BookService",
      methodName: "searchBooks",
      methodParams: "query: String",
      returnType: "[Book]",
      baseURL: "https://www.googleapis.com/books/v1/volumes",
      queryParamNames: "q",
      fixedParams: ""
    )
    let code = renderer.renderServiceFlat(intent)
    #expect(code.contains("actor BookService"))
    #expect(code.contains("SearchResult"))
    #expect(code.contains("decoded.results"))
  }

  @Test("Recipe service with multiple dynamic params")
  func recipeService() {
    let intent = ServiceFlatIntent(
      actorName: "RecipeService",
      methodName: "searchRecipes",
      methodParams: "query: String",
      returnType: "[Recipe]",
      baseURL: "https://www.themealdb.com/api/json/v1/1/search.php",
      queryParamNames: "s",
      fixedParams: ""
    )
    let code = renderer.renderServiceFlat(intent)
    #expect(code.contains("func searchRecipes"))
    #expect(code.contains("URLQueryItem(name: \"s\""))
  }

  @Test("News service with API key as fixed param")
  func newsService() {
    let intent = ServiceFlatIntent(
      actorName: "NewsService",
      methodName: "fetchHeadlines",
      methodParams: "country: String",
      returnType: "[Article]",
      baseURL: "https://newsapi.org/v2/top-headlines",
      queryParamNames: "country,apiKey",
      fixedParams: "apiKey=YOUR_KEY"
    )
    let code = renderer.renderServiceFlat(intent)
    #expect(code.contains("\"apiKey\", value: \"YOUR_KEY\""))
    #expect(code.contains("\"country\", value: country"))
  }
}

@Suite("Template Render: ViewModel (Flat)")
struct ViewModelFlatRenderTests {

  private let renderer = TemplateRenderer()

  @Test("Podcast ViewModel renders @Observable class")
  func podcastViewModel() {
    let intent = ViewModelFlatIntent(
      className: "PodcastViewModel",
      property1: "var podcasts: [Podcast] = []",
      property2: "var searchText: String = \"\"",
      property3: "",
      serviceName: "PodcastService",
      methodName: "search",
      serviceCall: "searchPodcasts(term: searchText)",
      targetProperty: "podcasts"
    )
    let code = renderer.renderViewModelFlat(intent)
    #expect(code.contains("@Observable"))
    #expect(code.contains("class PodcastViewModel"))
    #expect(!code.contains("ObservableObject"))
    #expect(!code.contains("struct PodcastViewModel"))
    #expect(code.contains("var podcasts: [Podcast] = []"))
    #expect(code.contains("var searchText"))
    #expect(code.contains("func search() async"))
    #expect(code.contains("podcasts = try await service.searchPodcasts(term: searchText)"))
    #expect(code.contains("private let service = PodcastService()"))
  }

  @Test("Weather ViewModel renders correctly")
  func weatherViewModel() {
    let intent = ViewModelFlatIntent(
      className: "WeatherViewModel",
      property1: "var weather: Weather?",
      property2: "var cityName: String = \"\"",
      property3: "var isLoading = false",
      serviceName: "WeatherService",
      methodName: "loadWeather",
      serviceCall: "fetchWeather(city: cityName)",
      targetProperty: "weather"
    )
    let code = renderer.renderViewModelFlat(intent)
    #expect(code.contains("@Observable"))
    #expect(code.contains("class WeatherViewModel"))
    #expect(code.contains("var weather: Weather?"))
    #expect(code.contains("var isLoading = false"))
    #expect(code.contains("weather = try await service.fetchWeather(city: cityName)"))
  }

  @Test("Todo ViewModel with local service")
  func todoViewModel() {
    let intent = ViewModelFlatIntent(
      className: "TodoViewModel",
      property1: "var items: [TodoItem] = []",
      property2: "var newItemTitle: String = \"\"",
      property3: "",
      serviceName: "TodoStore",
      methodName: "loadItems",
      serviceCall: "fetchAll()",
      targetProperty: "items"
    )
    let code = renderer.renderViewModelFlat(intent)
    #expect(code.contains("@Observable"))
    #expect(code.contains("class TodoViewModel"))
    #expect(code.contains("private let service = TodoStore()"))
  }

  @Test("ViewModel never generates ObservableObject regardless of domain")
  func neverObservableObject() {
    let domains = [
      ("RecipeViewModel", "RecipeService", "recipes: [Recipe]", "searchRecipes(query: query)"),
      ("BookViewModel", "BookService", "books: [Book]", "searchBooks(query: searchText)"),
      ("NewsViewModel", "NewsService", "articles: [Article]", "fetchHeadlines(country: country)"),
      ("FitnessViewModel", "FitnessTracker", "workouts: [Workout]", "fetchWorkouts()"),
    ]
    let renderer = TemplateRenderer()
    for (className, service, prop, call) in domains {
      let intent = ViewModelFlatIntent(
        className: className, property1: "var \(prop) = []", property2: "",
        property3: "", serviceName: service, methodName: "load",
        serviceCall: call, targetProperty: prop.split(separator: ":").first.map(String.init) ?? "items"
      )
      let code = renderer.renderViewModelFlat(intent)
      #expect(code.contains("@Observable"), "\(className) should use @Observable")
      #expect(!code.contains("ObservableObject"), "\(className) must NOT use ObservableObject")
      #expect(code.contains("class \(className)"), "\(className) should be a class")
    }
  }
}

@Suite("Template Render: ListView")
struct ListViewRenderTests {

  private let renderer = TemplateRenderer()

  @Test("Podcast ListView renders with correct property names")
  func podcastListView() {
    let intent = ListViewFlatIntent(
      viewName: "PodcastListView",
      viewModelType: "PodcastViewModel",
      listProperty: "podcasts",
      itemType: "Podcast",
      titleProperty: "trackName",
      subtitleProperty: "artistName",
      searchProperty: "searchText",
      loadMethod: "search",
      navigationTitle: "Podcasts"
    )
    let code = renderer.renderListView(intent)
    #expect(code.contains("struct PodcastListView: View"))
    #expect(code.contains("@State var viewModel = PodcastViewModel()"))
    #expect(code.contains("viewModel.podcasts"))
    #expect(code.contains("item.trackName"))
    #expect(code.contains("item.artistName"))
    #expect(code.contains(".searchable(text: $viewModel.searchText)"))
    #expect(code.contains("viewModel.search()"))
    #expect(code.contains(".navigationTitle(\"Podcasts\")"))
    // Must NOT contain generic exemplar names
    #expect(!code.contains("viewModel.items"))
    #expect(!code.contains("item.name"))
    #expect(!code.contains("viewModel.load"))
  }

  @Test("Weather view without search or subtitle")
  func weatherView() {
    let intent = ListViewFlatIntent(
      viewName: "WeatherView",
      viewModelType: "WeatherViewModel",
      listProperty: "forecasts",
      itemType: "Forecast",
      titleProperty: "day",
      subtitleProperty: "",
      searchProperty: "",
      loadMethod: "loadForecast",
      navigationTitle: "Weather"
    )
    let code = renderer.renderListView(intent)
    #expect(code.contains("viewModel.forecasts"))
    #expect(code.contains("item.day"))
    #expect(!code.contains(".searchable"))
    #expect(!code.contains("VStack")) // no subtitle = no VStack wrapper
    #expect(code.contains("viewModel.loadForecast()"))
  }

  @Test("Recipe grid view with subtitle")
  func recipeView() {
    let intent = ListViewFlatIntent(
      viewName: "RecipeListView",
      viewModelType: "RecipeViewModel",
      listProperty: "recipes",
      itemType: "Recipe",
      titleProperty: "name",
      subtitleProperty: "cuisine",
      searchProperty: "searchText",
      loadMethod: "search",
      navigationTitle: "Recipes"
    )
    let code = renderer.renderListView(intent)
    #expect(code.contains("item.name"))
    #expect(code.contains("item.cuisine"))
    #expect(code.contains(".foregroundStyle(.secondary)"))
  }

  @Test("ListView never uses generic property names")
  func noGenericNames() {
    let intent = ListViewFlatIntent(
      viewName: "BookListView",
      viewModelType: "BookViewModel",
      listProperty: "books",
      itemType: "Book",
      titleProperty: "title",
      subtitleProperty: "author",
      searchProperty: "query",
      loadMethod: "searchBooks",
      navigationTitle: "Books"
    )
    let code = renderer.renderListView(intent)
    // These generic names should NEVER appear in template output
    #expect(!code.contains("viewModel.items"))
    #expect(!code.contains("item.name)")) // "item.name)" not "item.name" to avoid substring of titleProperty
  }
}

// MARK: - Personalized Exemplar Tests

@Suite("Personalized Exemplar")
struct PersonalizedExemplarTests {

  @Test("Generates exemplar with real property names from snapshot")
  func personalizedWithSnapshot() {
    let snapshot = ProjectSnapshot(
      models: [
        TypeSummary(name: "Podcast", file: "m.swift", kind: "struct",
                    properties: ["trackName", "artistName", "feedUrl"],
                    conformances: ["Codable"]),
      ],
      views: [],
      services: [
        TypeSummary(name: "PodcastViewModel", file: "vm.swift", kind: "class",
                    properties: ["podcasts", "searchText"],
                    methods: ["search"]),
      ],
      navigationPattern: nil, testPattern: nil, keyFiles: [:]
    )

    let exemplar = TaskResolver.personalizedExemplar(for: "view", snapshot: snapshot)
    #expect(exemplar != nil)
    if let exemplar {
      #expect(exemplar.contains("viewModel.podcasts"))
      #expect(exemplar.contains("item.trackName"))
      #expect(exemplar.contains("item.artistName"))
      #expect(exemplar.contains("viewModel.search()"))
      #expect(exemplar.contains("viewModel.searchText"))
      // Must NOT contain generic names
      #expect(!exemplar.contains("viewModel.items"))
      #expect(!exemplar.contains("item.name"))
      #expect(!exemplar.contains("viewModel.load"))
    }
  }

  @Test("Falls back to nil for non-view roles")
  func noExemplarForNonView() {
    let snapshot = ProjectSnapshot.empty
    #expect(TaskResolver.personalizedExemplar(for: "service", snapshot: snapshot) == nil)
    #expect(TaskResolver.personalizedExemplar(for: "model", snapshot: snapshot) == nil)
  }

  @Test("Falls back to nil when snapshot has no models")
  func noExemplarWithoutModels() {
    let snapshot = ProjectSnapshot(
      models: [], views: [], services: [],
      navigationPattern: nil, testPattern: nil, keyFiles: [:]
    )
    #expect(TaskResolver.personalizedExemplar(for: "view", snapshot: snapshot) == nil)
  }

  @Test("Weather domain produces correct exemplar")
  func weatherExemplar() {
    let snapshot = ProjectSnapshot(
      models: [
        TypeSummary(name: "Forecast", file: "m.swift", kind: "struct",
                    properties: ["day", "tempHigh", "tempLow"],
                    conformances: ["Codable"]),
      ],
      views: [],
      services: [
        TypeSummary(name: "WeatherViewModel", file: "vm.swift", kind: "class",
                    properties: ["forecasts"],
                    methods: ["loadForecast"]),
      ],
      navigationPattern: nil, testPattern: nil, keyFiles: [:]
    )

    let exemplar = TaskResolver.personalizedExemplar(for: "view", snapshot: snapshot)
    #expect(exemplar != nil)
    if let exemplar {
      #expect(exemplar.contains("viewModel.forecasts"))
      #expect(exemplar.contains("item.day"))
      #expect(exemplar.contains("viewModel.loadForecast()"))
    }
  }
}

// MARK: - Template Retry Guard

@Suite("Template Retry Guard")
struct TemplateRetryGuardTests {

  @Test("shouldUseTemplate recognizes view files")
  func viewTemplateRecognition() {
    let renderer = TemplateRenderer()
    #expect(renderer.shouldUseTemplate(filePath: "PodcastListView.swift"))
    #expect(renderer.shouldUseTemplate(filePath: "WeatherView.swift"))
    #expect(renderer.shouldUseTemplate(filePath: "Sources/App/RecipeDetailView.swift"))
    // Should NOT match preview files
    #expect(!renderer.shouldUseTemplate(filePath: "ContentView_Previews.swift"))
  }

  @Test("shouldUseTemplate recognizes service and viewmodel files")
  func serviceViewModelRecognition() {
    let renderer = TemplateRenderer()
    #expect(renderer.shouldUseTemplate(filePath: "PodcastService.swift"))
    #expect(renderer.shouldUseTemplate(filePath: "PodcastViewModel.swift"))
    #expect(renderer.shouldUseTemplate(filePath: "WeatherService.swift"))
  }
}
