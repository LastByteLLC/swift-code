// AFMTools.swift — Native AFM Tool implementations for read-only project exploration.
//
// Deliberately minimal: two tools is the sweet spot per TN3193 / Tool docs
// ("limit the number of tools you use to three to five"; fewer tools = fewer
// misfires on a 4K-context model). Both tools are read-only and safe:
// no filesystem mutation, no shell, no permission prompt required.
//
// Mutation tools (create/write/edit/patch) stay on the orchestrator's
// plan-execute router where permission flow and diff preview already live.

import Foundation
import FoundationModels

/// Tool: read a file from the project, truncated to fit a small token budget.
public struct ReadFileTool: FoundationModels.Tool {
  public let name = "read_file"
  public let description = "Read the contents of a file in the current project by its path."

  private let files: FileTools
  private let maxTokens: Int

  public init(workingDirectory: String, maxTokens: Int = Config.fileReadMaxTokens) {
    self.files = FileTools(workingDirectory: workingDirectory)
    self.maxTokens = maxTokens
  }

  @Generable
  public struct Arguments {
    @Guide(description: "Path relative to the project root, e.g. Sources/App/Main.swift")
    public var path: String
  }

  public func call(arguments: Arguments) async throws -> String {
    do {
      return try files.read(path: arguments.path, maxTokens: maxTokens)
    } catch FileToolError.fileNotFound {
      return "ERROR: file not found: \(arguments.path)"
    } catch FileToolError.pathOutsideProject {
      return "ERROR: path outside project: \(arguments.path)"
    } catch {
      return "ERROR: \(error.localizedDescription)"
    }
  }
}

/// Tool: grep the project for an exact string or regex pattern.
public struct ProjectSearchTool: FoundationModels.Tool {
  public let name = "search_project"
  public let description = "Search the project's source files for an exact string or regex pattern."

  private let shell: SafeShell
  private let maxTokens: Int

  public init(workingDirectory: String, maxTokens: Int = Config.toolOutputMaxTokens) {
    self.shell = SafeShell(workingDirectory: workingDirectory)
    self.maxTokens = maxTokens
  }

  @Generable
  public struct Arguments {
    @Guide(description: "Exact string or regex pattern to search for")
    public var pattern: String
  }

  public func call(arguments: Arguments) async throws -> String {
    let pattern = arguments.pattern.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !pattern.isEmpty else { return "ERROR: empty pattern" }

    let escaped = pattern.replacingOccurrences(of: "'", with: "'\\''")
    let hasRg = FileManager.default.isExecutableFile(atPath: "/opt/homebrew/bin/rg")
      || FileManager.default.isExecutableFile(atPath: "/usr/local/bin/rg")
    let command = hasRg
      ? "rg -n --no-heading --max-count=20 '\(escaped)' . 2>/dev/null | head -20"
      : "grep -rn --include='*.swift' '\(escaped)' . 2>/dev/null | head -20"

    do {
      let result = try await shell.execute(command, timeout: 10)
      let formatted = result.formatted(maxTokens: maxTokens)
      return formatted.isEmpty || formatted == "(no output)" ? "No matches." : formatted
    } catch {
      return "ERROR: \(error.localizedDescription)"
    }
  }
}
