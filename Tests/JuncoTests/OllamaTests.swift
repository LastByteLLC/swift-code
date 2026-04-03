// OllamaTests.swift — Tests for OllamaDetector and OllamaAdapter

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
