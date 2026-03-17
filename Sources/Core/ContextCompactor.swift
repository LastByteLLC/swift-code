import Foundation

public final class ContextCompactor: Sendable {
  public static let keepRecent = 3
  public static let minContentLength = 100

  public let transcriptDirectory: String
  public let tokenThreshold: Int

  public init(
    transcriptDirectory: String,
    tokenThreshold: Int = Limits.defaultTokenThreshold
  ) {
    self.transcriptDirectory = transcriptDirectory
    self.tokenThreshold = tokenThreshold
  }

  // MARK: - Micro compact

  public func microCompact(messages: inout [Message]) {
    let toolResultLocations = findToolResultLocations(in: messages)
    guard toolResultLocations.count > Self.keepRecent else {
      return
    }

    let toolNameMap = buildToolNameMap(from: messages)
    let oldResults = toolResultLocations.dropLast(Self.keepRecent)
    var modifiedContents: [Int: [ContentBlock]] = [:]

    for (msgIdx, contentIdx) in oldResults {
      guard
        case .toolResult(let toolUseId, let content, let isError) = messages[msgIdx].content[contentIdx],
        content.count > Self.minContentLength
      else {
        continue
      }

      let toolName = toolNameMap[toolUseId] ?? "unknown"
      let replacement = ContentBlock.toolResult(
        toolUseId: toolUseId,
        content: "[Previous: used \(toolName)]",
        isError: isError
      )

      if modifiedContents[msgIdx] == nil {
        modifiedContents[msgIdx] = messages[msgIdx].content
      }
      modifiedContents[msgIdx]![contentIdx] = replacement
    }

    for (msgIdx, newContent) in modifiedContents {
      messages[msgIdx] = Message(role: messages[msgIdx].role, content: newContent)
    }
  }

  private func findToolResultLocations(
    in messages: [Message]
  ) -> [(msgIdx: Int, contentIdx: Int)] {
    var locations: [(msgIdx: Int, contentIdx: Int)] = []

    for (msgIdx, message) in messages.enumerated() {
      for case (let contentIdx, .toolResult) in message.content.enumerated() {
        locations.append((msgIdx, contentIdx))
      }
    }

    return locations
  }

  private func buildToolNameMap(from messages: [Message]) -> [String: String] {
    var map: [String: String] = [:]

    for message in messages where message.role == .assistant {
      for case .toolUse(let id, let name, _) in message.content {
        map[id] = name
      }
    }

    return map
  }

  // MARK: - Token estimation

  static let maxSummaryInputLength = 80_000

  public func estimateTokens(from messages: [Message]) -> Int {
    let data = (try? JSONEncoder().encode(messages)) ?? Data()
    return data.count / 4
  }

  // MARK: - Transcript saving

  public func saveTranscript(_ messages: [Message]) throws -> String {
    let fileManager = FileManager.default
    if !fileManager.fileExists(atPath: transcriptDirectory) {
      try fileManager.createDirectory(
        atPath: transcriptDirectory,
        withIntermediateDirectories: true
      )
    }

    let timestamp = Int(Date().timeIntervalSince1970)
    let unique = UUID().uuidString.prefix(8)
    let path = "\(transcriptDirectory)/transcript_\(timestamp)_\(unique).jsonl"

    let encoder = JSONEncoder()
    var lines: [String] = []

    for message in messages {
      let data = try encoder.encode(message)
      if let line = String(data: data, encoding: .utf8) {
        lines.append(line)
      }
    }

    let content = lines.joined(separator: "\n")
    try content.write(toFile: path, atomically: true, encoding: .utf8)

    return path
  }

  // MARK: - Auto compact

  public func autoCompact(
    messages: [Message],
    using apiClient: APIClientProtocol,
    model: String,
    focus: String?
  ) async -> [Message] {
    do {
      let path = try saveTranscript(messages)
      let encoder = JSONEncoder()
      let data = (try? encoder.encode(messages)) ?? Data()
      var transcript = String(data: data, encoding: .utf8) ?? "[]"
      if transcript.count > Self.maxSummaryInputLength {
        transcript = String(transcript.prefix(Self.maxSummaryInputLength)) + "\n[truncated]"
      }

      var prompt = ""
      if let focus, !focus.isEmpty {
        prompt += "Focus on: \(focus). "
      }
      prompt += """
        Summarize this conversation for continuity. Include: \
        1) What was accomplished, 2) Current state, 3) Key decisions made. \
        Be concise but preserve critical details.

        \(transcript)
        """

      let request = APIRequest(
        model: model,
        maxTokens: 2000,
        messages: [.user(prompt)]
      )
      let response = try await apiClient.createMessage(request: request)
      let summary = response.content.textContent

      return [
        .user("[Conversation compressed. Transcript: \(path)]\n\n\(summary)"),
        .assistant("Understood. I have the context from the summary. Continuing.")
      ]
    } catch {
      print("[warning] Auto-compact failed: \(error). Keeping original messages.")
      return messages
    }
  }
}
