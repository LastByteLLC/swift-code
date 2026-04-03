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
    // Build a simple example JSON shape from the @Generable schema.
    // We show the model what keys to use and their types, not the full JSON Schema.
    // Build a JSON Schema for Ollama's structured output format parameter.
    // This constrains the model to output valid JSON matching our type.
    let schemaForFormat = Self.jsonSchema(for: T.self)
    let exampleJSON = Self.exampleJSON(from: T.generationSchema)
    let jsonHint = "Respond with a JSON object. Example:\n\(exampleJSON)\nFill in real values. Output ONLY JSON."
    let effectiveSystem = system.map { $0 + "\n" + jsonHint } ?? jsonHint

    var body = OllamaChatRequest(
      model: modelName,
      messages: buildMessages(prompt: prompt, system: effectiveSystem),
      stream: false,
      formatSchema: schemaForFormat
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

    guard let jsonData = jsonText.data(using: .utf8) else {
      throw LLMError.generationFailed("Ollama: invalid UTF-8 in response")
    }

    // T is GenerableContent (Generable & Codable & Sendable).
    // Use JSONDecoder directly — all our types are Codable.
    do {
      return try JSONDecoder().decode(T.self, from: jsonData)
    } catch let decodingError as DecodingError {
      // Provide detailed error context for debugging
      let detail: String
      switch decodingError {
      case .keyNotFound(let key, _): detail = "missing key '\(key.stringValue)'"
      case .typeMismatch(let type, let ctx): detail = "type mismatch for \(type) at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))"
      case .valueNotFound(let type, let ctx): detail = "null value for \(type) at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))"
      case .dataCorrupted(let ctx): detail = "corrupted at \(ctx.codingPath.map(\.stringValue).joined(separator: "."))"
      @unknown default: detail = decodingError.localizedDescription
      }
      throw LLMError.generationFailed("Ollama \(T.self): \(detail)")
    } catch {
      throw LLMError.generationFailed("Ollama \(T.self): \(error.localizedDescription)")
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

  // MARK: - Schema → Example JSON

  /// Build a minimal example JSON object from a GenerationSchema.
  /// Shows the model the expected keys and value types without the full JSON Schema.
  private static func exampleJSON(from schema: GenerationSchema) -> String {
    // Encode the schema, parse it to extract just the property names and types
    guard let data = try? JSONEncoder().encode(schema),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
          let properties = obj["properties"] as? [String: Any] else {
      return "{}"
    }

    // Extract property names in order (use x-order if available, else sorted keys)
    let order: [String]
    if let xOrder = obj["x-order"] as? [String] {
      order = xOrder
    } else {
      order = properties.keys.sorted()
    }

    var parts: [String] = []
    for key in order {
      guard let prop = properties[key] as? [String: Any] else { continue }
      let value = Self.exampleValue(for: prop)
      parts.append("  \"\(key)\": \(value)")
    }
    return "{\n\(parts.joined(separator: ",\n"))\n}"
  }

  /// Generate a placeholder value string for a schema property.
  private static func exampleValue(for prop: [String: Any]) -> String {
    if let type = prop["type"] as? String {
      switch type {
      case "string":
        // If there's a description or enum, use it as hint
        if let desc = prop["description"] as? String {
          return "\"<\(desc)>\""
        }
        return "\"...\""
      case "integer", "number":
        return "0"
      case "boolean":
        return "true"
      case "array":
        if let items = prop["items"] as? [String: Any] {
          let itemVal = exampleValue(for: items)
          return "[\(itemVal)]"
        }
        return "[\"...\"]"
      case "object":
        if let nested = prop["properties"] as? [String: Any] {
          let nestedParts = nested.keys.sorted().prefix(3).map { k -> String in
            let v = exampleValue(for: nested[k] as? [String: Any] ?? [:])
            return "\"\(k)\": \(v)"
          }
          return "{\(nestedParts.joined(separator: ", "))}"
        }
        return "{}"
      default:
        return "\"...\""
      }
    }
    return "\"...\""
  }

  /// Build a JSON Schema dictionary from a GenerationSchema for Ollama's format parameter.
  private static func jsonSchema(for type: (some GenerableContent).Type) -> [String: Any] {
    let schema = type.generationSchema
    guard let data = try? JSONEncoder().encode(schema),
          let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
      return ["type": "object"]
    }
    // The GenerationSchema encodes to a valid JSON Schema that Ollama understands
    return obj
  }
}

// MARK: - Ollama API Types

private struct OllamaChatRequest: Encodable {
  let model: String
  let messages: [OllamaMessage]
  let stream: Bool
  var formatSchema: [String: Any]?
  var options: OllamaOptions?

  enum CodingKeys: String, CodingKey {
    case model, messages, stream, format, options
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    try container.encode(model, forKey: .model)
    try container.encode(messages, forKey: .messages)
    try container.encode(stream, forKey: .stream)
    if let schema = formatSchema {
      // Ollama accepts a JSON Schema object as the "format" field
      let jsonData = try JSONSerialization.data(withJSONObject: schema)
      let rawJSON = try JSONDecoder().decode(AnyCodable.self, from: jsonData)
      try container.encode(rawJSON, forKey: .format)
    }
    try container.encodeIfPresent(options, forKey: .options)
  }
}

/// Type-erased Codable wrapper for encoding arbitrary JSON.
private struct AnyCodable: Codable {
  let value: Any

  init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let dict = try? container.decode([String: AnyCodable].self) {
      value = dict.mapValues(\.value)
    } else if let arr = try? container.decode([AnyCodable].self) {
      value = arr.map(\.value)
    } else if let str = try? container.decode(String.self) {
      value = str
    } else if let num = try? container.decode(Double.self) {
      value = num
    } else if let bool = try? container.decode(Bool.self) {
      value = bool
    } else {
      value = NSNull()
    }
  }

  func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch value {
    case let dict as [String: Any]:
      try container.encode(dict.mapValues { AnyCodable(value: $0) })
    case let arr as [Any]:
      try container.encode(arr.map { AnyCodable(value: $0) })
    case let str as String:
      try container.encode(str)
    case let num as Double:
      try container.encode(num)
    case let num as Int:
      try container.encode(num)
    case let bool as Bool:
      try container.encode(bool)
    default:
      try container.encodeNil()
    }
  }

  init(value: Any) { self.value = value }
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
