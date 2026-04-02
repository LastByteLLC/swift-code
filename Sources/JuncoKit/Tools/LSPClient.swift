// LSPClient.swift — sourcekit-lsp integration for code intelligence
//
// Communicates with sourcekit-lsp over JSON-RPC via stdin/stdout pipes.
// Provides: diagnostics, hover (type info), go-to-definition, completions.
// Used to enrich RAG context and validate edits.

import Foundation

/// A diagnostic from the LSP server.
public struct LSPDiagnostic: Sendable {
  public let file: String
  public let line: Int
  public let column: Int
  public let severity: String  // "error", "warning", "information"
  public let message: String
}

/// Manages a sourcekit-lsp subprocess for code intelligence.
public actor LSPClient {
  private var process: Process?
  private var stdin: FileHandle?
  private var stdout: FileHandle?
  private var requestId: Int = 0
  private let workingDirectory: String
  private var initialized = false
  // Use Data instead of [String: Any] to cross actor boundaries safely
  private var pendingResponses: [Int: CheckedContinuation<Data?, Never>] = [:]
  private var readTask: Task<Void, Never>?

  public init(workingDirectory: String) {
    self.workingDirectory = workingDirectory
  }

  // MARK: - Lifecycle

  /// Start the LSP server.
  public func start() async -> Bool {
    let proc = Process()
    proc.executableURL = URL(fileURLWithPath: "/usr/bin/sourcekit-lsp")
    proc.currentDirectoryURL = URL(fileURLWithPath: workingDirectory)

    let stdinPipe = Pipe()
    let stdoutPipe = Pipe()
    proc.standardInput = stdinPipe
    proc.standardOutput = stdoutPipe
    proc.standardError = FileHandle.nullDevice

    do {
      try proc.run()
    } catch {
      return false
    }

    self.process = proc
    self.stdin = stdinPipe.fileHandleForWriting
    self.stdout = stdoutPipe.fileHandleForReading

    // Start reading responses in background
    let outHandle = stdoutPipe.fileHandleForReading
    readTask = Task.detached { [weak self] in
      await self?.readLoop(handle: outHandle)
    }

    // Initialize
    let initResult = await sendRequest(method: "initialize", params: [
      "processId": ProcessInfo.processInfo.processIdentifier,
      "rootUri": "file://\(workingDirectory)",
      "capabilities": [:] as [String: Any],
    ] as [String: Any])

    if initResult != nil {
      sendNotification(method: "initialized", params: [:] as [String: Any])
      initialized = true
      return true
    }
    return false
  }

  /// Stop the LSP server.
  public func stop() {
    readTask?.cancel()
    _ = sendRequestSync(method: "shutdown", params: [:] as [String: Any])
    sendNotificationSync(method: "exit", params: [:] as [String: Any])
    process?.terminate()
    process = nil
    initialized = false
  }

  // MARK: - Public API

  /// Get diagnostics for a file (errors, warnings).
  public func diagnostics(file: String) async -> [LSPDiagnostic] {
    guard initialized else { return [] }

    let uri = fileURI(file)

    // Open the document
    let content = (try? String(contentsOfFile: resolvePath(file), encoding: .utf8)) ?? ""
    sendNotification(method: "textDocument/didOpen", params: [
      "textDocument": [
        "uri": uri,
        "languageId": "swift",
        "version": 1,
        "text": content,
      ],
    ] as [String: Any])

    // Wait briefly for diagnostics to be published
    try? await Task.sleep(for: .milliseconds(500))

    // Close the document
    sendNotification(method: "textDocument/didClose", params: [
      "textDocument": ["uri": uri],
    ] as [String: Any])

    // Diagnostics come via notifications, not requests.
    // For now return empty — full implementation needs notification handling.
    return []
  }

  /// Get hover information (type, documentation) at a position.
  public func hover(file: String, line: Int, column: Int) async -> String? {
    guard initialized else { return nil }

    let uri = fileURI(file)
    let content = (try? String(contentsOfFile: resolvePath(file), encoding: .utf8)) ?? ""

    sendNotification(method: "textDocument/didOpen", params: [
      "textDocument": [
        "uri": uri, "languageId": "swift", "version": 1, "text": content,
      ],
    ] as [String: Any])

    let result = await sendRequest(method: "textDocument/hover", params: [
      "textDocument": ["uri": uri],
      "position": ["line": line - 1, "character": column - 1],
    ] as [String: Any])

    sendNotification(method: "textDocument/didClose", params: [
      "textDocument": ["uri": uri],
    ] as [String: Any])

    if let contents = result?["contents"] as? [String: Any],
       let value = contents["value"] as? String {
      return value
    }
    return nil
  }

  /// Get the definition location of a symbol at a position.
  public func definition(file: String, line: Int, column: Int) async -> (file: String, line: Int)? {
    guard initialized else { return nil }

    let uri = fileURI(file)
    let content = (try? String(contentsOfFile: resolvePath(file), encoding: .utf8)) ?? ""

    sendNotification(method: "textDocument/didOpen", params: [
      "textDocument": [
        "uri": uri, "languageId": "swift", "version": 1, "text": content,
      ],
    ] as [String: Any])

    let result = await sendRequest(method: "textDocument/definition", params: [
      "textDocument": ["uri": uri],
      "position": ["line": line - 1, "character": column - 1],
    ] as [String: Any])

    sendNotification(method: "textDocument/didClose", params: [
      "textDocument": ["uri": uri],
    ] as [String: Any])

    // Result can be a single Location or array of Locations
    if let targetUri = result?["uri"] as? String,
       let range = result?["range"] as? [String: Any],
       let start = range["start"] as? [String: Any],
       let line = start["line"] as? Int {
      let path = targetUri.replacingOccurrences(of: "file://", with: "")
      return (file: path, line: line + 1)
    }
    return nil
  }

  /// Search for symbols across the workspace by name (fuzzy match).
  /// Returns matching symbols with their location and kind.
  public func workspaceSymbol(query: String) async -> [(name: String, kind: String, file: String, line: Int)] {
    guard initialized else { return [] }

    guard let resultData = await sendRequest(method: "workspace/symbol", params: [
      "query": query,
    ] as [String: Any]) else { return [] }

    // Result is SymbolInformation[]
    guard let symbols = resultData["result"] as? [[String: Any]] ?? (
      // Some LSP servers return array directly
      try? JSONSerialization.jsonObject(with: resultData.values.first as? Data ?? Data()) as? [[String: Any]]
    ) else {
      // Try parsing resultData itself as array (it may be the unwrapped result)
      return parseSymbolArray(resultData)
    }

    return symbols.compactMap { parseSymbolInfo($0) }
  }

  private func parseSymbolArray(_ obj: [String: Any]) -> [(name: String, kind: String, file: String, line: Int)] {
    // The sendRequest already extracts "result" — try parsing as array items
    // If it's a single symbol, wrap it
    if let name = obj["name"] as? String {
      if let parsed = parseSymbolInfo(obj) { return [parsed] }
    }
    return []
  }

  private func parseSymbolInfo(_ info: [String: Any]) -> (name: String, kind: String, file: String, line: Int)? {
    guard let name = info["name"] as? String,
          let location = info["location"] as? [String: Any],
          let uri = location["uri"] as? String,
          let range = location["range"] as? [String: Any],
          let start = range["start"] as? [String: Any],
          let line = start["line"] as? Int
    else { return nil }

    let kind = symbolKindName(info["kind"] as? Int ?? 0)
    let file = uri.replacingOccurrences(of: "file://", with: "")
      .replacingOccurrences(of: workingDirectory + "/", with: "")
    return (name: name, kind: kind, file: file, line: line + 1)
  }

  private func symbolKindName(_ kind: Int) -> String {
    switch kind {
    case 5: return "class"
    case 6: return "method"
    case 11: return "interface"  // protocol
    case 12: return "function"
    case 13: return "variable"
    case 23: return "struct"
    case 25: return "enum"
    default: return "symbol"
    }
  }

  // MARK: - JSON-RPC Communication

  private func sendRequest(method: String, params: [String: Any]) async -> [String: Any]? {
    requestId += 1
    let id = requestId

    let body: [String: Any] = [
      "jsonrpc": "2.0",
      "id": id,
      "method": method,
      "params": params,
    ]

    guard let json = try? JSONSerialization.data(withJSONObject: body),
          let content = String(data: json, encoding: .utf8)
    else { return nil }

    let message = "Content-Length: \(json.count)\r\n\r\n\(content)"
    stdin?.write(message.data(using: .utf8)!)

    let responseData: Data? = await withCheckedContinuation { continuation in
      pendingResponses[id] = continuation
      Task {
        try? await Task.sleep(for: .seconds(5))
        if let cont = pendingResponses.removeValue(forKey: id) {
          cont.resume(returning: nil)
        }
      }
    }

    guard let data = responseData else { return nil }
    return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
  }

  private func sendNotification(method: String, params: [String: Any]) {
    let body: [String: Any] = [
      "jsonrpc": "2.0",
      "method": method,
      "params": params,
    ]
    guard let json = try? JSONSerialization.data(withJSONObject: body),
          let content = String(data: json, encoding: .utf8)
    else { return }
    let message = "Content-Length: \(json.count)\r\n\r\n\(content)"
    stdin?.write(message.data(using: .utf8)!)
  }

  private func sendRequestSync(method: String, params: [String: Any]) -> [String: Any]? {
    // Fire and forget for shutdown
    sendNotification(method: method, params: params)
    return nil
  }

  private func sendNotificationSync(method: String, params: [String: Any]) {
    sendNotification(method: method, params: params)
  }

  private func readLoop(handle: FileHandle) async {
    var buffer = Data()

    while !Task.isCancelled {
      let chunk = handle.availableData
      guard !chunk.isEmpty else { break }
      buffer.append(chunk)

      // Parse JSON-RPC messages from buffer
      while let (_, parsed) = extractMessage(from: &buffer) {
        if let id = parsed["id"] as? Int, parsed["result"] != nil {
          // Re-serialize just the result portion
          if let resultObj = parsed["result"],
             let resultData = try? JSONSerialization.data(withJSONObject: resultObj) {
            if let cont = pendingResponses.removeValue(forKey: id) {
              cont.resume(returning: resultData)
            }
          }
        }
      }
    }
  }

  private func extractMessage(from buffer: inout Data) -> (Data, [String: Any])? {
    guard let separator = "\r\n\r\n".data(using: .utf8),
          let headerEnd = buffer.range(of: separator)
    else { return nil }
    let headerData = buffer[buffer.startIndex..<headerEnd.lowerBound]
    guard let header = String(data: headerData, encoding: .utf8),
          let lengthLine = header.split(separator: "\r\n").first(where: { $0.hasPrefix("Content-Length:") }),
          let length = Int(lengthLine.split(separator: ":")[1].trimmingCharacters(in: .whitespaces))
    else { return nil }

    let bodyStart = headerEnd.upperBound
    let needed = buffer.distance(from: buffer.startIndex, to: bodyStart) + length
    guard buffer.count >= needed else { return nil }

    let bodyEnd = buffer.index(bodyStart, offsetBy: length)
    let bodyData = Data(buffer[bodyStart..<bodyEnd])
    buffer.removeSubrange(buffer.startIndex..<bodyEnd)

    guard let parsed = try? JSONSerialization.jsonObject(with: bodyData) as? [String: Any] else {
      return nil
    }
    return (bodyData, parsed)
  }

  // MARK: - Helpers

  private func fileURI(_ path: String) -> String {
    "file://\(resolvePath(path))"
  }

  private func resolvePath(_ path: String) -> String {
    if path.hasPrefix("/") { return path }
    return (workingDirectory as NSString).appendingPathComponent(path)
  }
}
