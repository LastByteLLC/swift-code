// ProjectResolverTests.swift

import Testing
import Foundation
@testable import JuncoKit

@Suite("ProjectResolver")
struct ProjectResolverTests {

  private func makeTempDir() throws -> String {
    let dir = NSTemporaryDirectory() + "junco-pr-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
  }

  @Test("detects Package.swift as project root")
  func detectsPackageSwift() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try "// swift-tools-version: 6.2".write(toFile: "\(dir)/Package.swift", atomically: true, encoding: .utf8)

    let result = ProjectResolver.resolve(from: dir)
    #expect(result.hasProjectMarkers)
    #expect(!result.wasAutoDetected)
    #expect(result.path == dir)
  }

  @Test("walks up to find parent project root")
  func walksUpToParent() throws {
    let root = try makeTempDir()
    defer { try? FileManager.default.removeItem(atPath: root) }
    try "// swift-tools-version: 6.2".write(toFile: "\(root)/Package.swift", atomically: true, encoding: .utf8)

    let sub = "\(root)/Training/lora"
    try FileManager.default.createDirectory(atPath: sub, withIntermediateDirectories: true)

    let result = ProjectResolver.resolve(from: sub)
    #expect(result.hasProjectMarkers)
    #expect(result.wasAutoDetected)
    #expect(result.path == root)
  }

  @Test("returns original dir when no project found")
  func noProjectFound() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    // Empty dir — no markers

    let result = ProjectResolver.resolve(from: dir)
    #expect(!result.hasProjectMarkers)
    #expect(!result.wasAutoDetected)
    #expect(result.path == dir)
  }

  @Test("isProjectRoot detects Package.swift")
  func isProjectRootPackage() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try "".write(toFile: "\(dir)/Package.swift", atomically: true, encoding: .utf8)

    #expect(ProjectResolver.isProjectRoot(dir))
  }

  @Test("isProjectRoot detects xcodeproj")
  func isProjectRootXcode() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    try FileManager.default.createDirectory(atPath: "\(dir)/MyApp.xcodeproj", withIntermediateDirectories: true)

    #expect(ProjectResolver.isProjectRoot(dir))
  }

  @Test("resolves the actual junco project root")
  func resolvesJuncoRoot() {
    // This test runs from the project root (swift test sets cwd)
    let cwd = FileManager.default.currentDirectoryPath
    let result = ProjectResolver.resolve(from: cwd)
    #expect(result.hasProjectMarkers, "Should find Package.swift in \(cwd)")
  }
}
