// PromptsTests.swift — Verify tool lists are consistent and complete

import Testing
@testable import JuncoKit

@Suite("Prompts")
struct PromptsTests {
  @Test("plan system prompt includes all tools")
  func planToolList() {
    let system = Prompts.planSystem
    for tool in ["bash", "read", "write", "edit", "patch", "search"] {
      #expect(system.contains(tool), "Plan prompt missing tool: \(tool)")
    }
  }

  @Test("execute system prompt includes all tools")
  func executeToolList() {
    let system = Prompts.executeSystem()
    for tool in ["bash", "read", "write", "edit", "patch", "search"] {
      #expect(system.contains(tool), "Execute prompt missing tool: \(tool)")
    }
  }

  @Test("execute system prompt includes domain hint when provided")
  func domainHint() {
    let system = Prompts.executeSystem(domainHint: "Use Swift conventions")
    #expect(system.contains("Use Swift conventions"))
  }

  @Test("classify prompt includes query and file hints")
  func classifyPrompt() {
    let prompt = Prompts.classifyPrompt(query: "fix login", fileHints: "auth.swift")
    #expect(prompt.contains("fix login"))
    #expect(prompt.contains("auth.swift"))
  }

  @Test("reflect prompt includes task details")
  func reflectPrompt() {
    var memory = WorkingMemory(query: "test task")
    memory.addError("something broke")
    memory.touch("file.swift")
    let prompt = Prompts.reflectPrompt(memory: memory)
    #expect(prompt.contains("test task"))
    #expect(prompt.contains("something broke"))
    #expect(prompt.contains("file.swift"))
  }
}
