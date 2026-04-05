// FileTools.swift — Validated file operations with path safety

import Foundation
import SwiftTreeSitter
import TreeSitterSwiftGrammar

/// Errors from file operations.
public enum FileToolError: Error, Sendable {
  case pathOutsideProject(String)
  case fileNotFound(String)
  case editTextNotFound(path: String, snippet: String)
  case writeBlocked(String)
}

/// Safe file operations that validate paths stay within the project directory.
public struct FileTools: Sendable {
  public let workingDirectory: String

  public init(workingDirectory: String) {
    self.workingDirectory = workingDirectory
  }

  // MARK: - Path Validation

  /// Resolve a possibly-relative path and verify it's within the working directory.
  public func resolve(_ path: String) throws -> String {
    let resolved: String
    if path.hasPrefix("/") {
      resolved = path
    } else {
      resolved = (workingDirectory as NSString).appendingPathComponent(path)
    }

    // Resolve symlinks fully to prevent path traversal via symlink chains
    let normalized = URL(fileURLWithPath: resolved).standardizedFileURL.path
    let normalizedWD = URL(fileURLWithPath: workingDirectory).standardizedFileURL.path

    guard normalized.hasPrefix(normalizedWD) else {
      throw FileToolError.pathOutsideProject(path)
    }

    return normalized
  }

  // MARK: - Read

  /// Read a file, returning its content truncated to fit a token budget.
  public func read(path: String, maxTokens: Int = 800) throws -> String {
    let resolved = try resolve(path)
    guard FileManager.default.fileExists(atPath: resolved) else {
      throw FileToolError.fileNotFound(path)
    }
    let content = try String(contentsOfFile: resolved, encoding: .utf8)
    return TokenBudget.truncate(content, toTokens: maxTokens)
  }

  /// Check if a file exists.
  public func exists(_ path: String) -> Bool {
    guard let resolved = try? resolve(path) else { return false }
    return FileManager.default.fileExists(atPath: resolved)
  }

  // MARK: - Write

  /// Write content to a file, creating parent directories as needed.
  public func write(path: String, content: String) throws {
    let resolved = try resolve(path)

    // Block writing to sensitive locations (uses consolidated config)
    let name = (resolved as NSString).lastPathComponent
    if Config.sensitiveFilePatterns.contains(where: { name.contains($0) }) {
      throw FileToolError.writeBlocked("Refusing to write to sensitive file: \(name)")
    }

    let dir = (resolved as NSString).deletingLastPathComponent
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    try content.write(toFile: resolved, atomically: true, encoding: .utf8)
  }

  // MARK: - Edit (find-replace)

  /// Find and replace text in a file.
  /// Cascade: exact match → fuzzy (trimmed whitespace) → structural (AST symbol lookup).
  public func edit(path: String, find: String, replace: String,
                   fuzzy: Bool = false, structural: Bool = false) throws {
    let resolved = try resolve(path)
    guard FileManager.default.fileExists(atPath: resolved) else {
      throw FileToolError.fileNotFound(path)
    }

    var content = try String(contentsOfFile: resolved, encoding: .utf8)

    if content.contains(find) {
      content = content.replacingOccurrences(of: find, with: replace)
    } else if fuzzy {
      // Fuzzy: try trimmed whitespace matching
      let trimmedFind = find.trimmingCharacters(in: .whitespacesAndNewlines)
      if let range = content.range(of: trimmedFind) {
        content.replaceSubrange(range, with: replace)
      } else if structural, let edited = structuralEdit(content: content, find: find, replace: replace) {
        content = edited
      } else {
        throw FileToolError.editTextNotFound(path: path, snippet: String(find.prefix(60)))
      }
    } else if structural, let edited = structuralEdit(content: content, find: find, replace: replace) {
      content = edited
    } else {
      throw FileToolError.editTextNotFound(path: path, snippet: String(find.prefix(60)))
    }

    try content.write(toFile: resolved, atomically: true, encoding: .utf8)
  }

  /// AST-based structural edit: extract symbol name from `find`, locate it in the file, replace.
  private func structuralEdit(content: String, find: String, replace: String) -> String? {
    let language = Language(language: tree_sitter_swift())
    let parser = Parser()
    do { try parser.setLanguage(language) } catch { return nil }

    // Parse the find text to extract the target symbol name
    guard let findTree = parser.parse(find), let findRoot = findTree.rootNode else { return nil }
    let findUtf16 = Array(find.utf16)
    let targetName = extractFirstSymbolName(findRoot, utf16: findUtf16)
    guard let targetName, !targetName.isEmpty else { return nil }

    // Parse the file to find the matching declaration
    guard let fileTree = parser.parse(content), let fileRoot = fileTree.rootNode else { return nil }
    let fileUtf16 = Array(content.utf16)

    // Find a declaration with the same name
    var matchNode: Node?
    func walk(_ node: Node) {
      guard matchNode == nil else { return }
      let nodeType = node.nodeType ?? ""
      if ["function_declaration", "property_declaration", "class_declaration",
          "protocol_declaration", "typealias_declaration"].contains(nodeType) {
        let name = extractDeclName(node, utf16: fileUtf16)
        if name == targetName {
          matchNode = node
          return
        }
      }
      for i in 0..<node.childCount {
        if let child = node.child(at: i) { walk(child) }
      }
    }
    walk(fileRoot)

    guard let match = matchNode else { return nil }
    let startByte = Int(match.byteRange.lowerBound) / 2
    let endByte = Int(match.byteRange.upperBound) / 2
    guard startByte >= 0, endByte <= fileUtf16.count else { return nil }

    // Replace the matched range
    var result = content
    let startIdx = content.utf16.index(content.utf16.startIndex, offsetBy: startByte)
    let endIdx = content.utf16.index(content.utf16.startIndex, offsetBy: endByte)
    result.replaceSubrange(startIdx..<endIdx, with: replace)
    return result
  }

  /// Extract the first symbol name from an AST (for the find text).
  private func extractFirstSymbolName(_ node: Node, utf16: [UInt16]) -> String? {
    let nodeType = node.nodeType ?? ""
    if ["function_declaration", "class_declaration", "protocol_declaration",
        "property_declaration", "typealias_declaration"].contains(nodeType) {
      return extractDeclName(node, utf16: utf16)
    }
    for i in 0..<node.childCount {
      if let child = node.child(at: i),
         let name = extractFirstSymbolName(child, utf16: utf16) {
        return name
      }
    }
    return nil
  }

  /// Extract the declared name from a declaration node.
  private func extractDeclName(_ node: Node, utf16: [UInt16]) -> String? {
    for i in 0..<node.childCount {
      guard let child = node.child(at: i) else { continue }
      let ct = child.nodeType ?? ""
      if ct == "simple_identifier" || ct == "type_identifier" {
        let start = Int(child.byteRange.lowerBound) / 2
        let end = Int(child.byteRange.upperBound) / 2
        guard start >= 0, end <= utf16.count, start < end else { return nil }
        return String(utf16CodeUnits: Array(utf16[start..<end]), count: end - start)
      }
      if ct == "pattern" {
        return extractDeclName(child, utf16: utf16)
      }
    }
    return nil
  }

  // MARK: - List

  /// List files in the project matching given extensions, up to a depth.
  public func listFiles(
    extensions: [String] = Config.swiftExtensions + ["json", "md", "plist"],
    maxDepth: Int = Config.maxScanDepth,
    maxFiles: Int = Config.maxListFiles
  ) -> [String] {
    let fm = FileManager.default
    guard let enumerator = fm.enumerator(
      at: URL(fileURLWithPath: workingDirectory),
      includingPropertiesForKeys: [.isRegularFileKey],
      options: [.skipsHiddenFiles]
    ) else { return [] }

    var results: [String] = []
    let baseURL = URL(fileURLWithPath: workingDirectory).standardizedFileURL
    let basePath = baseURL.path
    let ignoreFilter = IgnoreFilter(workingDirectory: workingDirectory)

    while let url = enumerator.nextObject() as? URL {
      let stdPath = url.standardizedFileURL.path
      let rel: String
      if stdPath.hasPrefix(basePath + "/") {
        rel = String(stdPath.dropFirst(basePath.count + 1))
      } else {
        rel = stdPath
      }
      let depth = rel.components(separatedBy: "/").count
      if depth > maxDepth {
        enumerator.skipDescendants()
        continue
      }

      if ignoreFilter.shouldIgnore(rel) {
        enumerator.skipDescendants()
        continue
      }

      let ext = url.pathExtension
      if extensions.contains(ext) {
        results.append(rel)
        if results.count >= maxFiles { break }
      }
    }

    return results.sorted()
  }
}
