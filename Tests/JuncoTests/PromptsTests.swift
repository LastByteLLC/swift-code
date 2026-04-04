// PromptsTests.swift — Verify tool lists are consistent and complete

import Testing
@testable import JuncoKit

@Suite("Prompts")
struct PromptsTests {
  @Test("plan system prompt includes all tools including create")
  func planToolList() {
    let system = Prompts.planSystem
    for tool in ["bash", "read", "create", "write", "edit", "patch", "search"] {
      #expect(system.contains(tool), "Plan prompt missing tool: \(tool)")
    }
  }

  @Test("plan system prompt guides create for new files")
  func planCreateGuidance() {
    let system = Prompts.planSystem
    #expect(system.contains("create a new file"))
    #expect(system.contains("use create"))
  }

  @Test("ToolName enum covers all plan tools")
  func toolNameCoverage() {
    let allTools: [ToolName] = [.bash, .read, .create, .write, .edit, .patch, .search]
    #expect(allTools.count == 7)
    #expect(ToolName.allCases.count == 7)
  }

  @Test("classify prompt includes query and file hints")
  func classifyPrompt() {
    let prompt = Prompts.classifyPrompt(query: "fix login", fileHints: "auth.swift")
    #expect(prompt.contains("fix login"))
    #expect(prompt.contains("auth.swift"))
  }

}
