import Foundation
import Testing

@testable import Core

@Suite("SkillLoader")
struct SkillLoaderTests {
  private func createTempSkillsDir(
    skills: [(dir: String, content: String)]
  ) throws -> String {
    let tempDir = NSTemporaryDirectory() + "skill-tests-\(UUID().uuidString)"
    let fm = FileManager.default
    try fm.createDirectory(atPath: tempDir, withIntermediateDirectories: true)

    for skill in skills {
      let skillDir = "\(tempDir)/\(skill.dir)"
      try fm.createDirectory(atPath: skillDir, withIntermediateDirectories: true)
      try skill.content.write(
        toFile: "\(skillDir)/SKILL.md",
        atomically: true,
        encoding: .utf8
      )
    }

    return tempDir
  }

  @Test func loadsSkillsFromDirectory() throws {
    let dir = try createTempSkillsDir(skills: [
      (
        dir: "pdf",
        content: """
        ---
        name: pdf
        description: Process PDF files
        ---
        Full PDF processing instructions here.
        """
      ),
      (
        dir: "code-review",
        content: """
        ---
        name: code-review
        description: Review code quality
        ---
        Code review guidelines here.
        """
      )
    ])
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let loader = SkillLoader(directory: dir)
    #expect(!loader.isEmpty)
    #expect(loader.descriptions.contains("pdf: Process PDF files"))
    #expect(loader.descriptions.contains("code-review: Review code quality"))
  }

  @Test func descriptionsAreSorted() throws {
    let dir = try createTempSkillsDir(skills: [
      (dir: "zeta", content: "---\nname: zeta\ndescription: Last\n---\nBody"),
      (dir: "alpha", content: "---\nname: alpha\ndescription: First\n---\nBody")
    ])
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let loader = SkillLoader(directory: dir)
    let lines = loader.descriptions.components(separatedBy: "\n")
    try #require(lines.count == 2)
    #expect(lines[0].contains("alpha"))
    #expect(lines[1].contains("zeta"))
  }

  @Test func nonexistentDirectoryIsEmpty() {
    let loader = SkillLoader(directory: "/nonexistent/path/\(UUID().uuidString)")
    #expect(loader.isEmpty)
    #expect(loader.descriptions == "")
  }

  @Test func contentForValidSkill() throws {
    let dir = try createTempSkillsDir(skills: [
      (dir: "pdf", content: "---\nname: pdf\ndescription: Process PDFs\n---\nPDF body content")
    ])
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let loader = SkillLoader(directory: dir)
    let result = loader.content(for: "pdf")
    #expect(result == "<skill name=\"pdf\">\nPDF body content\n</skill>")
  }

  @Test func contentForUnknownSkill() throws {
    let dir = try createTempSkillsDir(skills: [
      (dir: "pdf", content: "---\nname: pdf\ndescription: Process PDFs\n---\nBody")
    ])
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let loader = SkillLoader(directory: dir)
    let result = loader.content(for: "unknown")
    #expect(result.contains("Unknown skill 'unknown'"))
    #expect(result.contains("pdf"))
  }

  @Test func noFrontmatterDelimiters() throws {
    let dir = try createTempSkillsDir(skills: [
      (dir: "plain", content: "Just plain text\nno frontmatter here")
    ])
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let loader = SkillLoader(directory: dir)
    #expect(loader.isEmpty)
  }

  @Test func missingDescriptionSkipsSkill() throws {
    let dir = try createTempSkillsDir(skills: [
      (dir: "nodesc", content: "---\nname: nodesc\n---\nBody without description")
    ])
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let loader = SkillLoader(directory: dir)
    #expect(loader.isEmpty)
  }

  @Test func nameDefaultsToDirectoryName() throws {
    let dir = try createTempSkillsDir(skills: [
      (dir: "my-skill", content: "---\ndescription: A skill with no name field\n---\nBody")
    ])
    defer { try? FileManager.default.removeItem(atPath: dir) }

    let loader = SkillLoader(directory: dir)
    #expect(!loader.isEmpty)
    #expect(loader.descriptions.contains("my-skill: A skill with no name field"))
    #expect(loader.content(for: "my-skill").contains("<skill name=\"my-skill\">"))
  }
}
