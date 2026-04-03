// OllamaTests.swift — Tests for OllamaDetector and OllamaAdapter

import Foundation
import Testing
@testable import JuncoKit

@Suite("OllamaDetector")
struct OllamaDetectorTests {

  @Test("bestCodingModel prefers coding-specific models")
  func bestCodingModel() {
    let models = [
      OllamaModel(name: "llama3:8b", size: 4_000_000_000, parameterSize: "8B"),
      OllamaModel(name: "qwen2.5-coder:7b", size: 3_500_000_000, parameterSize: "7B"),
      OllamaModel(name: "mistral:7b", size: 3_800_000_000, parameterSize: "7B"),
    ]
    let best = OllamaDetector.bestCodingModel(from: models)
    #expect(best?.name == "qwen2.5-coder:7b")
  }

  @Test("bestCodingModel falls back to first available")
  func bestCodingModelFallback() {
    let models = [
      OllamaModel(name: "custom-model:latest", size: 2_000_000_000, parameterSize: nil),
    ]
    let best = OllamaDetector.bestCodingModel(from: models)
    #expect(best?.name == "custom-model:latest")
  }

  @Test("bestCodingModel returns nil for empty list")
  func bestCodingModelEmpty() {
    let best = OllamaDetector.bestCodingModel(from: [])
    #expect(best == nil)
  }

  @Test("bestCodingModel prefers qwen3 over llama")
  func bestCodingModelQwen3() {
    let models = [
      OllamaModel(name: "llama3:8b", size: 4_000_000_000, parameterSize: "8B"),
      OllamaModel(name: "qwen3:8b", size: 4_200_000_000, parameterSize: "8B"),
    ]
    let best = OllamaDetector.bestCodingModel(from: models)
    #expect(best?.name == "qwen3:8b")
  }

  @Test("OllamaModel formattedSize shows GB for large models")
  func formattedSizeGB() {
    let model = OllamaModel(name: "test", size: 4_400_000_000, parameterSize: "7B")
    #expect(model.formattedSize == "4.1 GB")
  }

  @Test("OllamaModel formattedSize shows MB for small models")
  func formattedSizeMB() {
    let model = OllamaModel(name: "test", size: 500_000_000, parameterSize: "1B")
    #expect(model.formattedSize == "477 MB")
  }

  @Test("isInstalled checks for ollama binary")
  func isInstalled() {
    // This test just verifies the method runs without crashing.
    // Result depends on whether ollama is installed on the test machine.
    let _ = OllamaDetector.isInstalled()
  }
}

@Suite("OllamaAdapter")
struct OllamaAdapterTests {

  @Test("backendName includes model name")
  func backendName() {
    let adapter = OllamaAdapter(model: "qwen2.5-coder:7b")
    #expect(adapter.backendName == "Ollama (qwen2.5-coder:7b)")
  }

  @Test("contextSize defaults to 4096")
  func defaultContextSize() {
    let adapter = OllamaAdapter(model: "test")
    #expect(adapter.contextSize == 4096)
  }

  @Test("contextSize respects custom value")
  func customContextSize() {
    let adapter = OllamaAdapter(model: "test", contextSize: 8192)
    #expect(adapter.contextSize == 8192)
  }

  @Test("countTokens uses estimation")
  func countTokens() async {
    let adapter = OllamaAdapter(model: "test")
    let count = await adapter.countTokens("hello world")
    #expect(count > 0)
    #expect(count == TokenBudget.estimate("hello world"))
  }

  @Test("isAFM is false")
  func isNotAFM() {
    let adapter = OllamaAdapter(model: "test")
    #expect(!adapter.isAFM)
  }
}

@Suite("LLMAdapter Protocol")
struct LLMAdapterProtocolTests {

  @Test("MockAdapter conforms to widened protocol")
  func mockAdapterConforms() async throws {
    let adapter: any LLMAdapter = MockAdapter(fixedResponse: "test")
    let result = try await adapter.generate(prompt: "hello", system: nil)
    #expect(result == "test")
    #expect(adapter.backendName == "Mock")
    #expect(!adapter.isAFM)
  }

  @Test("MockAdapter streaming returns full text")
  func mockStreaming() async throws {
    let adapter = MockAdapter(fixedResponse: "streamed response")
    let result = try await adapter.generateStreaming(prompt: "test", system: nil) { _ in }
    #expect(result == "streamed response")
  }

  @Test("MockAdapter countTokens uses estimation")
  func mockCountTokens() async {
    let adapter = MockAdapter(fixedResponse: "test")
    let count = await adapter.countTokens("hello world test")
    #expect(count == TokenBudget.estimate("hello world test"))
  }

  @Test("AFMAdapter is AFM")
  func afmAdapterIsAFM() {
    let adapter = AFMAdapter()
    #expect(adapter.isAFM)
    #expect(adapter.backendName == "Apple Foundation Models (Neural Engine)")
  }
}

@Suite("Codable JSON Decoding")
struct CodableDecodingTests {

  @Test("AgentIntent decodes from standard JSON")
  func decodeAgentIntent() throws {
    let json = """
    {"domain":"swift","taskType":"fix","complexity":"simple","mode":"build","targets":["file.swift"]}
    """
    let data = json.data(using: .utf8)!
    let intent = try JSONDecoder().decode(AgentIntent.self, from: data)
    #expect(intent.domain == "swift")
    #expect(intent.taskType == "fix")
  }

  @Test("AgentPlan decodes from standard JSON")
  func decodeAgentPlan() throws {
    let json = """
    {"steps":[{"instruction":"create file","tool":"create","target":"hello.txt"}]}
    """
    let data = json.data(using: .utf8)!
    let plan = try JSONDecoder().decode(AgentPlan.self, from: data)
    #expect(plan.steps.count == 1)
    #expect(plan.steps[0].tool == "create")
  }

  @Test("BashParams decodes from standard JSON")
  func decodeBashParams() throws {
    let json = """
    {"command":"ls -la"}
    """
    let data = json.data(using: .utf8)!
    let params = try JSONDecoder().decode(BashParams.self, from: data)
    #expect(params.command == "ls -la")
  }

  @Test("StructuredPlan decodes from standard JSON")
  func decodeStructuredPlan() throws {
    let json = """
    {"summary":"test","sections":[{"heading":"Phase 1","items":["step 1"],"files":["a.swift"]}],"questions":[],"concerns":[]}
    """
    let data = json.data(using: .utf8)!
    let plan = try JSONDecoder().decode(StructuredPlan.self, from: data)
    #expect(plan.summary == "test")
    #expect(plan.sections.count == 1)
  }
}

@Suite("LLMGenerationOptions")
struct LLMGenerationOptionsTests {

  @Test("default options have nil values")
  func defaultOptions() {
    let opts = LLMGenerationOptions()
    #expect(opts.maximumResponseTokens == nil)
    #expect(opts.temperature == nil)
  }

  @Test("options preserve values")
  func preserveValues() {
    let opts = LLMGenerationOptions(maximumResponseTokens: 2000, temperature: 0.7)
    #expect(opts.maximumResponseTokens == 2000)
    #expect(opts.temperature == 0.7)
  }
}

@Suite("OllamaDetector Live", .enabled(if: OllamaLiveCheck.available))
struct OllamaDetectorLiveTests {

  @Test("isRunning returns true when Ollama is up")
  func isRunning() async {
    let running = await OllamaDetector.isRunning()
    #expect(running)
  }

  @Test("availableModels returns at least one model")
  func availableModels() async {
    let models = await OllamaDetector.availableModels()
    #expect(!models.isEmpty)
    #expect(models[0].name.count > 0)
    #expect(models[0].size > 0)
  }

  @Test("autoDetect finds a model")
  func autoDetect() async {
    let model = await OllamaDetector.autoDetect()
    #expect(model != nil)
  }

  @Test("runningModels returns loaded models or empty")
  func runningModels() async {
    // Just verify it doesn't crash — result depends on what's loaded
    let models = await OllamaDetector.runningModels()
    // models may be empty if nothing is loaded, that's fine
    for model in models {
      #expect(!model.name.isEmpty)
    }
  }

  @Test("autoDetect prefers running model over preference ranking")
  func autoDetectPrefersRunning() async {
    // If a model is currently running, autoDetect should return it
    let running = await OllamaDetector.runningModels()
    let detected = await OllamaDetector.autoDetect()
    if let active = running.first {
      #expect(detected?.name == active.name)
    }
  }
}

@Suite("OllamaAdapter Live", .enabled(if: OllamaLiveCheck.available))
struct OllamaAdapterLiveTests {

  static var modelName: String {
    // Use the first available model
    "gemma4:e2b-it-q4_K_M"
  }

  @Test("plain text generation works")
  func plainTextGeneration() async throws {
    let adapter = OllamaAdapter(model: Self.modelName)
    let result = try await adapter.generate(prompt: "Reply with exactly one word: hello", system: "You are a helpful assistant. Be extremely brief.")
    #expect(!result.isEmpty)
  }

  @Test("streaming generation works")
  func streamingGeneration() async throws {
    let adapter = OllamaAdapter(model: Self.modelName)
    let result = try await adapter.generateStreaming(
      prompt: "Say hi in one word",
      system: "Be brief."
    ) { _ in }
    #expect(!result.isEmpty)
  }

  @Test("structured generation produces valid JSON")
  func structuredGeneration() async throws {
    let adapter = OllamaAdapter(model: Self.modelName)
    let result = try await adapter.generateStructured(
      prompt: "Classify this query: 'fix the login bug'. Return domain as 'swift', taskType as 'fix', complexity as 'simple', mode as 'build', targets as empty array.",
      system: "You generate JSON matching the requested schema. Output only valid JSON.",
      as: AgentIntent.self
    )
    #expect(!result.taskType.isEmpty)
    #expect(!result.domain.isEmpty)
  }
}

/// Helper to check if Ollama is reachable for conditional test enablement.
enum OllamaLiveCheck {
  // Check synchronously by attempting a quick connection.
  // This runs at test discovery time.
  static let available: Bool = {
    guard let url = URL(string: "http://localhost:11434/api/tags") else { return false }
    var request = URLRequest(url: url)
    request.timeoutInterval = 1
    let semaphore = DispatchSemaphore(value: 0)
    var result = false
    let task = URLSession.shared.dataTask(with: request) { _, response, _ in
      result = (response as? HTTPURLResponse)?.statusCode == 200
      semaphore.signal()
    }
    task.resume()
    semaphore.wait()
    return result
  }()
}

@Suite("WelcomeMessage Model Info")
struct WelcomeMessageModelTests {

  @Test("default modelInfo shows AFM")
  func defaultModelInfo() {
    let welcome = WelcomeMessage(
      domain: Domains.swift,
      workingDirectory: "/tmp"
    )
    let rendered = welcome.render(width: 80)
    #expect(rendered.contains("Apple Foundation Models"))
  }

  @Test("custom modelInfo shows Ollama")
  func customModelInfo() {
    let welcome = WelcomeMessage(
      domain: Domains.swift,
      workingDirectory: "/tmp",
      modelInfo: "Ollama (gemma:4b)"
    )
    let rendered = welcome.render(width: 80)
    #expect(rendered.contains("Ollama (gemma:4b)"))
    #expect(!rendered.contains("Apple Foundation Models"))
  }
}
