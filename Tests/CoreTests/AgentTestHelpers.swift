import Foundation
import Testing

@testable import Core

final class MockAPIClient: APIClientProtocol, @unchecked Sendable {
  var responses: [APIResponse] = []
  var errorAtIndices: [Int: Error] = [:]
  private(set) var requests: [APIRequest] = []
  private var callIndex = 0

  func createMessage(request: APIRequest) async throws -> APIResponse {
    requests.append(request)

    let currentIndex = callIndex
    guard currentIndex < responses.count else {
      let message = "MockAPIClient: callIndex \(currentIndex) out of bounds (\(responses.count) responses configured)"
      Issue.record("\(message)")
      throw MockError.outOfResponses
    }

    callIndex += 1

    if let error = errorAtIndices[currentIndex] {
      throw error
    }

    return responses[currentIndex]
  }

  enum MockError: Error {
    case outOfResponses
    case simulatedError
  }
}

func makeAgent(
  mock: MockAPIClient = MockAPIClient(),
  skillsDirectory: String? = nil,
  workingDirectory: String = ".",
  tokenThreshold: Int = Limits.defaultTokenThreshold
) -> (Agent, MockAPIClient) {
  let agent = Agent(
    apiClient: mock,
    model: "test-model",
    systemPrompt: "You are a test agent.",
    workingDirectory: workingDirectory,
    skillsDirectory: skillsDirectory,
    tokenThreshold: tokenThreshold
  )
  return (agent, mock)
}

func makeResponse(
  content: [ContentBlock],
  stopReason: StopReason = .endTurn
) -> APIResponse {
  APIResponse(
    id: "msg_test",
    type: "message",
    role: "assistant",
    content: content,
    stopReason: stopReason,
    usage: Usage(inputTokens: 10, outputTokens: 5)
  )
}

func isToolResult(
  _ block: ContentBlock,
  where predicate: (String, String, Bool) -> Bool
) -> Bool {
  if case .toolResult(let id, let content, let isError) = block {
    return predicate(id, content, isError)
  }
  return false
}

func extractJobId(_ confirmation: String) throws -> String {
  // Parses "Background job {id} started: ..."
  let parts = confirmation.components(separatedBy: " ")
  guard parts.count >= 3, parts[0] == "Background", parts[1] == "job" else {
    throw TestError.unexpectedFormat("Expected 'Background job {id} started: ...', got: \(confirmation)")
  }
  return parts[2]
}

enum TestError: Error {
  case unexpectedFormat(String)
}

func backgroundRunResponse(id: String, command: String) -> APIResponse {
  makeResponse(
    content: [
      .toolUse(
        id: id,
        name: "background_run",
        input: .object(["command": .string(command)])
      )
    ],
    stopReason: .toolUse
  )
}

func toolUseResponses(count: Int) -> [APIResponse] {
  (0..<count).map { index in
    makeResponse(
      content: [
        .toolUse(
          id: "t\(index)",
          name: "bash",
          input: .object(["command": .string("echo \(index)")])
        )
      ],
      stopReason: .toolUse
    )
  }
}
