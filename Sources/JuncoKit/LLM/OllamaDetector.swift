// OllamaDetector.swift — Auto-detect Ollama installation and running models

import Foundation

/// Detect whether Ollama is installed, running, and which models are available.
public struct OllamaDetector: Sendable {

  /// Default Ollama server URL.
  public static let defaultHost = "http://localhost:11434"

  /// Check if the `ollama` CLI is installed.
  public static func isInstalled() -> Bool {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
    process.arguments = ["ollama"]
    process.standardOutput = FileHandle.nullDevice
    process.standardError = FileHandle.nullDevice
    do {
      try process.run()
      process.waitUntilExit()
      return process.terminationStatus == 0
    } catch {
      return false
    }
  }

  /// Check if the Ollama server is reachable by hitting GET /api/tags.
  /// Returns true if the server responds within 2 seconds.
  public static func isRunning(host: String = defaultHost) async -> Bool {
    guard let url = URL(string: "\(host)/api/tags") else { return false }
    var request = URLRequest(url: url)
    request.timeoutInterval = 2
    do {
      let (_, response) = try await URLSession.shared.data(for: request)
      return (response as? HTTPURLResponse)?.statusCode == 200
    } catch {
      return false
    }
  }

  /// List locally available models from the Ollama server.
  public static func availableModels(host: String = defaultHost) async -> [OllamaModel] {
    guard let url = URL(string: "\(host)/api/tags") else { return [] }
    var request = URLRequest(url: url)
    request.timeoutInterval = 5
    do {
      let (data, response) = try await URLSession.shared.data(for: request)
      guard (response as? HTTPURLResponse)?.statusCode == 200 else { return [] }
      let parsed = try JSONDecoder().decode(OllamaTagsResponse.self, from: data)
      return parsed.models.map { model in
        OllamaModel(
          name: model.name,
          size: model.size,
          parameterSize: model.details?.parameterSize
        )
      }
    } catch {
      return []
    }
  }

  /// Pick the best coding model from available models.
  /// Prefers: qwen2.5-coder > codellama > deepseek-coder > qwen > llama > first available.
  public static func bestCodingModel(from models: [OllamaModel]) -> OllamaModel? {
    guard !models.isEmpty else { return nil }

    let preferences = [
      "qwen2.5-coder",
      "qwen3",
      "codellama",
      "deepseek-coder",
      "codegemma",
      "qwen2.5",
      "qwen2",
      "llama3",
      "llama",
      "mistral",
      "gemma",
    ]

    for prefix in preferences {
      if let match = models.first(where: { $0.name.lowercased().hasPrefix(prefix) }) {
        return match
      }
    }
    return models.first
  }

  /// Full auto-detection: check if Ollama is running and pick the best model.
  /// Returns nil if Ollama is not available.
  public static func autoDetect(host: String = defaultHost) async -> OllamaModel? {
    guard await isRunning(host: host) else { return nil }
    let models = await availableModels(host: host)
    return bestCodingModel(from: models)
  }
}

// MARK: - Models

/// A locally available Ollama model.
public struct OllamaModel: Sendable {
  public let name: String
  public let size: Int64
  public let parameterSize: String?

  public init(name: String, size: Int64, parameterSize: String?) {
    self.name = name
    self.size = size
    self.parameterSize = parameterSize
  }

  /// Human-readable size (e.g., "4.1 GB").
  public var formattedSize: String {
    let gb = Double(size) / 1_073_741_824
    if gb >= 1 {
      return String(format: "%.1f GB", gb)
    }
    let mb = Double(size) / 1_048_576
    return String(format: "%.0f MB", mb)
  }
}

// MARK: - API Response Types

private struct OllamaTagsResponse: Decodable {
  let models: [OllamaTagModel]
}

private struct OllamaTagModel: Decodable {
  let name: String
  let size: Int64
  let details: OllamaModelDetails?
}

private struct OllamaModelDetails: Decodable {
  let parameterSize: String?

  enum CodingKeys: String, CodingKey {
    case parameterSize = "parameter_size"
  }
}
