// OllamaAdapter.swift — Ollama backend via direct HTTP API

import Foundation
import FoundationModels

/// LLM adapter using Ollama's local HTTP server.
/// Calls the Ollama REST API directly and handles JSON-based structured output.
public actor OllamaAdapter: LLMAdapter {

  private let modelName: String
  private let baseURL: URL
  private let _contextSize: Int

  nonisolated public var backendName: String { "Ollama (\(modelName))" }

  /// Create an adapter for an Ollama model.
  /// - Parameters:
  ///   - model: Model name as shown in `ollama list` (e.g., "qwen2.5-coder:7b").
  ///   - host: Ollama server URL (default: http://localhost:11434).
  ///   - contextSize: Context window size for token budgeting (default: 4096).
  public init(model modelName: String, host: String = "http://localhost:11434", contextSize: Int = 4096) {
    self.modelName = modelName
    self._contextSize = contextSize
    self.baseURL = URL(string: host)!
  }

  // MARK: - Plain text generation

  public func generate(prompt: String, system: String?) async throws -> String {
    let body = OllamaChatRequest(
      model: modelName,
      messages: buildMessages(prompt: prompt, system: system),
      stream: false
    )
    let response: OllamaChatResponse = try await post(path: "/api/chat", body: body)
    return response.message.content
  }

  // MARK: - Streaming text generation

  public func generateStreaming(
    prompt: String,
    system: String?,
    onChunk: @escaping @Sendable (String) async -> Void
  ) async throws -> String {
    let body = OllamaChatRequest(
      model: modelName,
      messages: buildMessages(prompt: prompt, system: system),
      stream: true
    )

    let url = baseURL.appendingPathComponent("/api/chat")
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.httpBody = try JSONEncoder().encode(body)

    let (bytes, response) = try await URLSession.shared.bytes(for: request)
    guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
      throw LLMError.generationFailed("Ollama returned status \((response as? HTTPURLResponse)?.statusCode ?? 0)")
    }

    var fullText = ""
    for try await line in bytes.lines {
      guard let data = line.data(using: .utf8),
            let chunk = try? JSONDecoder().decode(OllamaChatResponse.self, from: data) else {
        continue
      }
      let delta = chunk.message.content
      if !delta.isEmpty {
        fullText += delta
        await onChunk(delta)
      }
    }
    return fullText
  }

  // MARK: - Structured generation

  public func generateStructured<T: GenerableContent>(
    prompt: String,
    system: String?,
    as type: T.Type,
    options: LLMGenerationOptions? = nil
  ) async throws -> T {
    // Ask the model to respond in JSON matching the expected structure.
    let jsonHint = "Respond ONLY with valid JSON. No markdown, no explanation."
    let effectiveSystem = system.map { $0 + "\n" + jsonHint } ?? jsonHint

    var body = OllamaChatRequest(
      model: modelName,
      messages: buildMessages(prompt: prompt, system: effectiveSystem),
      stream: false,
      format: "json"
    )
    if let maxTokens = options?.maximumResponseTokens {
      body.options = OllamaOptions(numPredict: maxTokens)
    }
    if let temp = options?.temperature {
      if body.options == nil { body.options = OllamaOptions() }
      body.options?.temperature = temp
    }

    let response: OllamaChatResponse = try await post(path: "/api/chat", body: body)
    let jsonText = response.message.content.trimmingCharacters(in: .whitespacesAndNewlines)

    // Parse JSON through FoundationModels' GeneratedContent → @Generable init
    do {
      let content = try GeneratedContent(json: jsonText)
      return try T(content)
    } catch {
      throw LLMError.generationFailed("Ollama: structured decode failed for \(T.self): \(error.localizedDescription)")
    }
  }

  // MARK: - Token counting

  public func countTokens(_ text: String) async -> Int {
    TokenBudget.estimate(text)
  }

  nonisolated public var contextSize: Int { _contextSize }

  // MARK: - HTTP helpers

  private func post<Body: Encodable, Response: Decodable>(
    path: String,
    body: Body
  ) async throws -> Response {
    let url = baseURL.appendingPathComponent(path)
    var request = URLRequest(url: url)
    request.httpMethod = "POST"
    request.setValue("application/json", forHTTPHeaderField: "Content-Type")
    request.timeoutInterval = 120
    request.httpBody = try JSONEncoder().encode(body)

    let (data, httpResponse) = try await URLSession.shared.data(for: request)
    guard let status = (httpResponse as? HTTPURLResponse)?.statusCode, status == 200 else {
      let statusCode = (httpResponse as? HTTPURLResponse)?.statusCode ?? 0
      let body = String(data: data, encoding: .utf8) ?? ""
      throw LLMError.generationFailed("Ollama HTTP \(statusCode): \(body.prefix(200))")
    }

    return try JSONDecoder().decode(Response.self, from: data)
  }

  private func buildMessages(prompt: String, system: String?) -> [OllamaMessage] {
    var messages: [OllamaMessage] = []
    if let system, !system.isEmpty {
      messages.append(OllamaMessage(role: "system", content: system))
    }
    messages.append(OllamaMessage(role: "user", content: prompt))
    return messages
  }
}

// MARK: - Ollama API Types

private struct OllamaChatRequest: Encodable {
  let model: String
  let messages: [OllamaMessage]
  let stream: Bool
  var format: String?
  var options: OllamaOptions?

  enum CodingKeys: String, CodingKey {
    case model, messages, stream, format, options
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(model, forKey: .model)
    try container.encode(messages, forKey: .messages)
    try container.encode(stream, forKey: .stream)
    try container.encodeIfPresent(format, forKey: .format)
    try container.encodeIfPresent(options, forKey: .options)
  }
}

private struct OllamaMessage: Codable {
  let role: String
  let content: String
}

private struct OllamaOptions: Encodable {
  var numPredict: Int?
  var temperature: Double?

  enum CodingKeys: String, CodingKey {
    case numPredict = "num_predict"
    case temperature
  }
}

private struct OllamaChatResponse: Decodable {
  let message: OllamaMessage
  let done: Bool
}
