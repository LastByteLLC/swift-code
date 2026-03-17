// swiftlint:disable file_length
import Foundation

public enum Limits {
  public static let maxOutputSize = 50_000
  public static let defaultTokenThreshold = 50_000
  public static let defaultMaxTokens = 4096
  static let logPreviewLength = 200
}

public final class Agent {
  public static let version = "0.7.0"

  private static let todoReminderThreshold = 3

  private let apiClient: any APIClientProtocol
  private let model: String
  private let systemPrompt: String
  private let workingDirectory: String

  private let shellExecutor: ShellExecutor
  private let skillLoader: SkillLoader
  private let contextCompactor: ContextCompactor
  private let todoManager: TodoManager
  private let taskManager: TaskManager

  private var messages: [Message] = []

  public init(
    apiClient: APIClientProtocol,
    model: String,
    systemPrompt: String? = nil,
    workingDirectory: String = ".",
    skillsDirectory: String? = nil,
    tokenThreshold: Int = Limits.defaultTokenThreshold
  ) {
    self.apiClient = apiClient
    self.model = model
    self.workingDirectory = workingDirectory
    self.shellExecutor = ShellExecutor(workingDirectory: workingDirectory)
    self.skillLoader = SkillLoader(directory: skillsDirectory ?? "\(workingDirectory)/skills")
    self.contextCompactor = ContextCompactor(
      transcriptDirectory: "\(workingDirectory)/.transcripts",
      tokenThreshold: tokenThreshold
    )
    self.todoManager = TodoManager()
    self.taskManager = TaskManager(directory: "\(workingDirectory)/.tasks")
    self.systemPrompt =
      systemPrompt
      ?? Self.buildSystemPrompt(
        cwd: workingDirectory,
        skillDescriptions: self.skillLoader.descriptions
      )
  }

  // MARK: - Agent loop

  public func run(query: String) async throws -> String {
    messages.append(.user(query))

    let result = try await agentLoop(initialMessages: messages, config: .default)
    messages = result.messages

    return result.text
  }

  private func agentLoop(
    initialMessages: [Message],
    config: LoopConfig
  ) async throws -> (text: String, messages: [Message]) {
    var messages = initialMessages
    var turnsWithoutTodo = 0
    var iteration = 0
    var lastAssistantText = ""

    let allowedTools = Set(config.tools.map(\.name))

    while true {
      try Task.checkCancellation()

      iteration += 1
      if iteration > config.maxIterations {
        return (lastAssistantText + "\n(\(config.label) reached iteration limit)", messages)
      }

      messages = await applyCompaction(messages)

      let request = APIRequest(
        model: model,
        maxTokens: Limits.defaultMaxTokens,
        system: systemPrompt,
        messages: messages,
        tools: config.tools
      )

      let response = try await apiClient.createMessage(request: request)
      messages.append(Message(role: .assistant, content: response.content))
      lastAssistantText = response.content.textContent

      for block in response.content {
        if case .text(let text) = block {
          print("[\(config.label)] \(ANSIColor.cyan)\(text)\(ANSIColor.reset)")
        }
      }

      guard response.stopReason == .toolUse else {
        return (response.content.textContent, messages)
      }

      let toolProcessing = await processToolUses(
        response: response,
        allowedTools: allowedTools,
        label: config.label
      )

      var toolResults = toolProcessing.results
      if config.enableNag {
        turnsWithoutTodo = toolProcessing.didUseTodo ? 0 : turnsWithoutTodo + 1
        if turnsWithoutTodo >= Self.todoReminderThreshold && todoManager.hasOpenItems() {
          toolResults.append(.text("Update your todos."))
        }
      }

      messages.append(Message(role: .user, content: toolResults))

      if let compactFocus = toolProcessing.compactFocus {
        print("[manual compact]")
        messages = await contextCompactor.autoCompact(
          messages: messages, using: apiClient, model: model, focus: compactFocus
        )
      }
    }
  }

  // MARK: - Compaction

  private func applyCompaction(_ messages: [Message]) async -> [Message] {
    var compacted = messages
    contextCompactor.microCompact(messages: &compacted)

    if contextCompactor.estimateTokens(from: compacted) > contextCompactor.tokenThreshold {
      print("[auto_compact triggered]")
      return await contextCompactor.autoCompact(
        messages: compacted, using: apiClient, model: model, focus: nil
      )
    }

    return compacted
  }

  public static func buildSystemPrompt(cwd: String, skillDescriptions: String = "") -> String {
    var prompt = """
      You are a coding agent at \(cwd). Use tools to solve tasks. \
      Act, don't explain.

      - Prefer read_file/write_file/edit_file over bash for file operations
      - Always check tool results before proceeding
      - Use the todo tool to plan multi-step tasks. Mark in_progress before starting, completed when done.
      - Use task tools for persistent multi-step work with dependencies. \
      Tasks survive context compaction and process restarts.
      """

    if !skillDescriptions.isEmpty {
      prompt += "\nUse load_skill to access specialized knowledge.\n\nSkills available:\n\(skillDescriptions)"
    }

    return prompt
  }
}

// MARK: - Tools

extension Agent {
  public enum ToolError: Error, Equatable {
    case unknownTool(String)
    case missingParameter(String)
    case executionFailed(String)
  }

  static let toolDefinitions: [ToolDefinition] = [
    ToolDefinition(
      name: "bash",
      description: "Run a shell command.",
      inputSchema: .object([
        "type": "object",
        "properties": .object([
          "command": .object([
            "type": "string",
            "description": "The shell command to execute"
          ])
        ]),
        "required": .array(["command"])
      ])
    ),
    ToolDefinition(
      name: "read_file",
      description: "Read file contents.",
      inputSchema: .object([
        "type": "object",
        "properties": .object([
          "path": .object([
            "type": "string",
            "description": "The file path to read"
          ]),
          "limit": .object([
            "type": "integer",
            "description": "Maximum number of lines to read"
          ])
        ]),
        "required": .array(["path"])
      ])
    ),
    ToolDefinition(
      name: "write_file",
      description: "Write content to a file.",
      inputSchema: .object([
        "type": "object",
        "properties": .object([
          "path": .object([
            "type": "string",
            "description": "The file path to write"
          ]),
          "content": .object([
            "type": "string",
            "description": "The content to write"
          ])
        ]),
        "required": .array(["path", "content"])
      ])
    ),
    ToolDefinition(
      name: "edit_file",
      description: "Replace exact text in a file.",
      inputSchema: .object([
        "type": "object",
        "properties": .object([
          "path": .object([
            "type": "string",
            "description": "The file path to edit"
          ]),
          "old_text": .object([
            "type": "string",
            "description": "The exact text to find and replace"
          ]),
          "new_text": .object([
            "type": "string",
            "description": "The replacement text"
          ])
        ]),
        "required": .array(["path", "old_text", "new_text"])
      ])
    ),
    ToolDefinition(
      name: "todo",
      description: "Update task list. Track progress on multi-step tasks.",
      inputSchema: .object([
        "type": "object",
        "properties": .object([
          "items": .object([
            "type": "array",
            "items": .object([
              "type": "object",
              "properties": .object([
                "id": .object(["type": "string"]),
                "text": .object(["type": "string"]),
                "status": .object([
                  "type": "string",
                  "enum": .array(["pending", "in_progress", "completed"])
                ])
              ]),
              "required": .array(["id", "text", "status"])
            ])
          ])
        ]),
        "required": .array(["items"])
      ])
    ),
    ToolDefinition(
      name: "agent",
      description: "Spawn a subagent to handle a complex subtask independently.",
      inputSchema: .object([
        "type": "object",
        "properties": .object([
          "prompt": .object([
            "type": "string",
            "description": "The task for the subagent to complete"
          ])
        ]),
        "required": .array(["prompt"])
      ])
    ),
    ToolDefinition(
      name: "load_skill",
      description: "Load specialized knowledge by name.",
      inputSchema: .object([
        "type": "object",
        "properties": .object([
          "name": .object([
            "type": "string",
            "description": "Skill name to load"
          ])
        ]),
        "required": .array(["name"])
      ])
    ),
    ToolDefinition(
      name: "compact",
      description: "Compress conversation history to free context space. Use when working on long tasks.",
      inputSchema: .object([
        "type": "object",
        "properties": .object([
          "focus": .object([
            "type": "string",
            "description": "What to preserve in the summary (e.g., 'file paths edited', 'current task progress')"
          ])
        ]),
        "required": .array([])
      ])
    ),
    ToolDefinition(
      name: "task_create",
      description: "Create a persistent task. Tasks survive context compaction and process restarts.",
      inputSchema: .object([
        "type": "object",
        "properties": .object([
          "subject": .object([
            "type": "string",
            "description": "Short title for the task"
          ]),
          "description": .object([
            "type": "string",
            "description": "Detailed description of the task"
          ])
        ]),
        "required": .array(["subject"])
      ])
    ),
    ToolDefinition(
      name: "task_update",
      description: "Update a task's status or dependencies.",
      inputSchema: .object([
        "type": "object",
        "properties": .object([
          "task_id": .object([
            "type": "integer",
            "description": "The task ID to update"
          ]),
          "status": .object([
            "type": "string",
            "enum": .array(["pending", "in_progress", "completed"]),
            "description": "New status for the task"
          ]),
          "add_blocked_by": .object([
            "type": "array",
            "items": .object(["type": "integer"]),
            "description": "Task IDs that block this task"
          ]),
          "add_blocks": .object([
            "type": "array",
            "items": .object(["type": "integer"]),
            "description": "Task IDs that this task blocks"
          ])
        ]),
        "required": .array(["task_id"])
      ])
    ),
    ToolDefinition(
      name: "task_list",
      description: "List all tasks with status markers and dependency info.",
      inputSchema: .object([
        "type": "object",
        "properties": .object([:]),
        "required": .array([])
      ])
    ),
    ToolDefinition(
      name: "task_get",
      description: "Get detailed info about a specific task.",
      inputSchema: .object([
        "type": "object",
        "properties": .object([
          "task_id": .object([
            "type": "integer",
            "description": "The task ID to retrieve"
          ])
        ]),
        "required": .array(["task_id"])
      ])
    )
  ]

  func executeTool(name: String, input: JSONValue) async -> Result<String, ToolError> {
    let handlers = [
      "bash": executeBash,
      "read_file": executeReadFile,
      "write_file": executeWriteFile,
      "edit_file": executeEditFile,
      "todo": executeTodo,
      "agent": executeAgent,
      "load_skill": executeLoadSkill,
      "compact": executeCompact,
      "task_create": executeTaskCreate,
      "task_update": executeTaskUpdate,
      "task_list": executeTaskList,
      "task_get": executeTaskGet
    ]

    guard let handler = handlers[name] else {
      return .failure(.unknownTool(name))
    }

    return await handler(input)
  }

  // MARK: - Handlers

  private func executeBash(_ input: JSONValue) async -> Result<String, ToolError> {
    guard let command = input["command"]?.stringValue else {
      return .failure(.missingParameter("command"))
    }

    do {
      let result = try await shellExecutor.execute(command)
      return .success(result.formatted)
    } catch {
      return .failure(.executionFailed("\(error)"))
    }
  }

  private func executeReadFile(_ input: JSONValue) async -> Result<String, ToolError> {
    guard let path = input["path"]?.stringValue else {
      return .failure(.missingParameter("path"))
    }

    switch resolveSafePath(path) {
    case .failure(let error):
      return .failure(error)
    case .success(let resolvedPath):
      do {
        let text = try String(contentsOfFile: resolvedPath, encoding: .utf8)

        let lines = text.components(separatedBy: "\n")
        var output: String

        if let limit = input["limit"]?.intValue, limit < lines.count {
          output =
            lines.prefix(limit).joined(separator: "\n")
            + "\n... (\(lines.count - limit) more lines)"
        } else {
          output = text
        }

        if output.count > Limits.maxOutputSize {
          output = String(output.prefix(Limits.maxOutputSize))
        }

        return .success(output)
      } catch {
        return .failure(.executionFailed("\(error)"))
      }
    }
  }

  private func executeWriteFile(_ input: JSONValue) async -> Result<String, ToolError> {
    guard let path = input["path"]?.stringValue else {
      return .failure(.missingParameter("path"))
    }

    guard let content = input["content"]?.stringValue else {
      return .failure(.missingParameter("content"))
    }

    switch resolveSafePath(path) {
    case .failure(let error):
      return .failure(error)
    case .success(let resolvedPath):
      do {
        let fileURL = URL(fileURLWithPath: resolvedPath)

        try FileManager.default.createDirectory(
          at: fileURL.deletingLastPathComponent(),
          withIntermediateDirectories: true
        )
        try content.write(toFile: resolvedPath, atomically: true, encoding: .utf8)

        return .success("Wrote \(content.utf8.count) bytes to \(path)")
      } catch {
        return .failure(.executionFailed("\(error)"))
      }
    }
  }

  private func executeEditFile(_ input: JSONValue) async -> Result<String, ToolError> {
    guard let path = input["path"]?.stringValue else {
      return .failure(.missingParameter("path"))
    }

    guard let oldText = input["old_text"]?.stringValue else {
      return .failure(.missingParameter("old_text"))
    }

    guard let newText = input["new_text"]?.stringValue else {
      return .failure(.missingParameter("new_text"))
    }

    switch resolveSafePath(path) {
    case .failure(let error):
      return .failure(error)
    case .success(let resolvedPath):
      do {
        var content = try String(contentsOfFile: resolvedPath, encoding: .utf8)

        guard let range = content.range(of: oldText) else {
          return .failure(.executionFailed("Text not found in \(path)"))
        }

        content.replaceSubrange(range, with: newText)
        try content.write(toFile: resolvedPath, atomically: true, encoding: .utf8)

        return .success("Edited \(path)")
      } catch {
        return .failure(.executionFailed("\(error)"))
      }
    }
  }

  private func executeAgent(_ input: JSONValue) async -> Result<String, ToolError> {
    guard let prompt = input["prompt"]?.stringValue else {
      return .failure(.missingParameter("prompt"))
    }

    do {
      let result = try await agentLoop(
        initialMessages: [Message.user(prompt)],
        config: .subagent
      )
      var output = result.text

      if output.isEmpty {
        output = "(no output)"
      } else if output.count > Limits.maxOutputSize {
        output = String(output.prefix(Limits.maxOutputSize))
      }

      return .success(output)
    } catch {
      return .failure(.executionFailed("Subagent failed: \(error)"))
    }
  }

  private func executeTodo(_ input: JSONValue) async -> Result<String, ToolError> {
    guard let itemsArray = input["items"]?.arrayValue else {
      return .failure(.missingParameter("items"))
    }

    var todoItems: [TodoItem] = []
    for element in itemsArray {
      guard let id = element["id"]?.stringValue else {
        return .failure(.missingParameter("items[].id"))
      }
      guard let text = element["text"]?.stringValue else {
        return .failure(.missingParameter("items[].text"))
      }
      guard let statusString = element["status"]?.stringValue else {
        return .failure(.missingParameter("items[].status"))
      }
      guard let status = TodoStatus(rawValue: statusString) else {
        return .failure(.executionFailed("Invalid status '\(statusString)' for item \(id)"))
      }
      todoItems.append(TodoItem(id: id, text: text, status: status))
    }

    do {
      try todoManager.update(items: todoItems)
      return .success(todoManager.render())
    } catch {
      return .failure(.executionFailed("\(error)"))
    }
  }

  private func executeLoadSkill(_ input: JSONValue) async -> Result<String, ToolError> {
    guard let name = input["name"]?.stringValue else {
      return .failure(.missingParameter("name"))
    }
    return .success(skillLoader.content(for: name))
  }

  private func executeCompact(_ input: JSONValue) async -> Result<String, ToolError> { .success("Compressing...") }

  private func executeTaskCreate(_ input: JSONValue) async -> Result<String, ToolError> {
    guard let subject = input["subject"]?.stringValue else {
      return .failure(.missingParameter("subject"))
    }

    let description = input["description"]?.stringValue ?? ""

    do {
      let result = try taskManager.create(subject: subject, description: description)
      return .success(result)
    } catch {
      return .failure(.executionFailed("\(error)"))
    }
  }

  private func executeTaskUpdate(_ input: JSONValue) async -> Result<String, ToolError> {
    guard let taskId = input["task_id"]?.intValue else {
      return .failure(.missingParameter("task_id"))
    }

    let status = input["status"]?.stringValue
    let addBlockedBy = input["add_blocked_by"]?.arrayValue?.compactMap(\.intValue) ?? []
    let addBlocks = input["add_blocks"]?.arrayValue?.compactMap(\.intValue) ?? []

    do {
      let result = try taskManager.update(
        taskId: taskId,
        status: status,
        addBlockedBy: addBlockedBy,
        addBlocks: addBlocks
      )
      return .success(result)
    } catch {
      return .failure(.executionFailed("\(error)"))
    }
  }

  private func executeTaskList(_ input: JSONValue) async -> Result<String, ToolError> {
    .success(taskManager.listAll())
  }

  private func executeTaskGet(_ input: JSONValue) async -> Result<String, ToolError> {
    guard let taskId = input["task_id"]?.intValue else {
      return .failure(.missingParameter("task_id"))
    }

    do {
      let result = try taskManager.get(taskId: taskId)
      return .success(result)
    } catch {
      return .failure(.executionFailed("\(error)"))
    }
  }

  // MARK: Helpers

  struct ToolProcessingResult {
    let results: [ContentBlock]
    let didUseTodo: Bool
    let compactFocus: String?
  }

  private func processToolUses(
    response: APIResponse,
    allowedTools: Set<String>,
    label: String
  ) async -> ToolProcessingResult {
    var results: [ContentBlock] = []
    var didUseTodo = false
    var compactFocus: String?

    for case .toolUse(let id, let name, let input) in response.content {
      guard allowedTools.contains(name) else {
        let message = "Tool '\(name)' is not allowed in this context"
        print("[\(label)] \(ANSIColor.red)\(message)\(ANSIColor.reset)")
        results.append(.toolResult(toolUseId: id, content: message, isError: true))
        continue
      }

      printToolCall(name: name, input: input, label: label)
      let toolResult = await executeTool(name: name, input: input)

      if name == "todo" {
        didUseTodo = true
      }

      if name == "compact" {
        compactFocus = input["focus"]?.stringValue ?? ""
      }

      switch toolResult {
      case .success(let output):
        print("[\(label)] \(ANSIColor.dim)\(String(output.prefix(Limits.logPreviewLength)))\(ANSIColor.reset)")
        results.append(.toolResult(toolUseId: id, content: output, isError: false))
      case .failure(let error):
        let message = "\(error)"
        print("[\(label)] \(ANSIColor.red)\(message)\(ANSIColor.reset)")
        results.append(.toolResult(toolUseId: id, content: message, isError: true))
      }
    }

    return ToolProcessingResult(
      results: results,
      didUseTodo: didUseTodo,
      compactFocus: compactFocus
    )
  }

  private func resolveSafePath(_ relativePath: String) -> Result<String, ToolError> {
    let workDirURL = URL(fileURLWithPath: workingDirectory, isDirectory: true)
    let resolvedWorkDir = workDirURL.standardized

    let fullURL =
      if relativePath.hasPrefix("/") {
        URL(fileURLWithPath: relativePath).standardized
      } else {
        workDirURL.appendingPathComponent(relativePath).standardized
      }

    guard
      fullURL.path.hasPrefix(resolvedWorkDir.path + "/") || fullURL.path == resolvedWorkDir.path
    else {
      return .failure(.executionFailed("Path escapes workspace: \(relativePath)"))
    }

    return .success(fullURL.path)
  }

  private func printToolCall(name: String, input: JSONValue, label: String) {
    if name == "bash", let command = input["command"]?.stringValue {
      print("[\(label)] \(ANSIColor.yellow)$ \(command)\(ANSIColor.reset)")
    } else if let path = input["path"]?.stringValue {
      print("[\(label)] \(ANSIColor.yellow)> \(name): \(path)\(ANSIColor.reset)")
    } else {
      print("[\(label)] \(ANSIColor.yellow)> \(name)\(ANSIColor.reset)")
    }
  }
}

// MARK: - Configuration

extension Agent {
  fileprivate struct LoopConfig {
    let tools: [ToolDefinition]
    let maxIterations: Int
    let enableNag: Bool
    let label: String

    static let `default` = LoopConfig(
      tools: Agent.toolDefinitions,
      maxIterations: .max,
      enableNag: true,
      label: "agent"
    )

    static let subagent = LoopConfig(
      tools: Agent.toolDefinitions.filter {
        !Set(["agent", "todo", "compact", "task_create", "task_update"]).contains($0.name)
      },
      maxIterations: 30,
      enableNag: false,
      label: "subagent"
    )
  }
}
