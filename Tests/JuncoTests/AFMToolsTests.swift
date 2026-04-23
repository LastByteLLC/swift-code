// AFMToolsTests.swift — Validate native AFM Tool implementations
//
// These tests exercise the Tool.call() path directly without routing through
// a LanguageModelSession, so they run without Apple Intelligence assets.

import Foundation
import Testing
@testable import JuncoKit

@Suite("AFMTools")
struct AFMToolsTests {

  // MARK: - ReadFileTool

  @Test("read_file reports metadata and a usable name/description")
  func readFileIdentity() {
    let tool = ReadFileTool(workingDirectory: NSTemporaryDirectory())
    #expect(tool.name == "read_file")
    #expect(!tool.description.isEmpty)
    #expect(tool.description.contains("file"))
  }

  @Test("read_file returns file contents for a path inside the project")
  func readFileSuccess() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let target = (dir as NSString).appendingPathComponent("note.txt")
    try "hello world".write(toFile: target, atomically: true, encoding: .utf8)

    let tool = ReadFileTool(workingDirectory: dir)
    let output = try await tool.call(arguments: .init(path: "note.txt"))
    #expect(output.contains("hello world"))
  }

  @Test("read_file rejects paths outside the project")
  func readFileEscape() async throws {
    let tool = ReadFileTool(workingDirectory: NSTemporaryDirectory())
    let output = try await tool.call(arguments: .init(path: "/etc/passwd"))
    #expect(output.hasPrefix("ERROR"))
  }

  @Test("read_file reports missing files without throwing")
  func readFileMissing() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let tool = ReadFileTool(workingDirectory: dir)
    let output = try await tool.call(arguments: .init(path: "does-not-exist.swift"))
    #expect(output.contains("not found"))
  }

  // MARK: - ProjectSearchTool

  @Test("search_project rejects empty patterns")
  func searchEmptyPattern() async throws {
    let tool = ProjectSearchTool(workingDirectory: NSTemporaryDirectory())
    let result = try await tool.call(arguments: .init(pattern: "   "))
    #expect(result.hasPrefix("ERROR"))
  }

  @Test("search_project surfaces matching lines from the project")
  func searchFindsMatches() async throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let swift = (dir as NSString).appendingPathComponent("a.swift")
    try "let answer = 42\nprint(answer)\n".write(toFile: swift, atomically: true, encoding: .utf8)

    let tool = ProjectSearchTool(workingDirectory: dir)
    let result = try await tool.call(arguments: .init(pattern: "answer"))
    #expect(result.contains("a.swift"))
    #expect(result.contains("answer"))
  }

  // MARK: - Helpers

  private func makeTempDir() throws -> String {
    let dir = (NSTemporaryDirectory() as NSString)
      .appendingPathComponent("afmtools-\(UUID().uuidString)")
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
  }
}
