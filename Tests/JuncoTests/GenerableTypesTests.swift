// GenerableTypesTests.swift — Verify @Generable types are Codable round-trippable

import Testing
import Foundation
@testable import JuncoKit

@Suite("GenerableTypes")
struct GenerableTypesTests {

  @Test("AgentIntent round-trips through Codable")
  func intentCodable() throws {
    let intent = AgentIntent(
      domain: "swift",
      taskType: "fix",
      complexity: "simple",
      mode: "build",
      targets: ["Auth.swift", "Session.swift"]
    )
    let data = try JSONEncoder().encode(intent)
    let decoded = try JSONDecoder().decode(AgentIntent.self, from: data)
    #expect(decoded.domain == "swift")
    #expect(decoded.taskType == "fix")
    #expect(decoded.targets.count == 2)
  }

  @Test("AgentPlan with steps round-trips")
  func planCodable() throws {
    let plan = AgentPlan(steps: [
      PlanStep(instruction: "Read file", tool: "read", target: "main.swift"),
      PlanStep(instruction: "Edit function", tool: "edit", target: "main.swift"),
    ])
    let data = try JSONEncoder().encode(plan)
    let decoded = try JSONDecoder().decode(AgentPlan.self, from: data)
    #expect(decoded.steps.count == 2)
    #expect(decoded.steps[0].toolName == .read)
  }

  @Test("ToolName round-trips via JSON")
  func toolNameCodable() throws {
    let step = PlanStep(instruction: "list files", tool: "bash", target: ".")
    let data = try JSONEncoder().encode(step)
    let decoded = try JSONDecoder().decode(PlanStep.self, from: data)
    #expect(decoded.toolName == .bash)
  }

  @Test("EditParams round-trips")
  func editParamsCodable() throws {
    let params = EditParams(
      filePath: "main.swift",
      find: "func old()",
      replace: "func new()"
    )
    let data = try JSONEncoder().encode(params)
    let decoded = try JSONDecoder().decode(EditParams.self, from: data)
    #expect(decoded.find == "func old()")
    #expect(decoded.replace == "func new()")
  }

  @Test("AgentReflection round-trips")
  func reflectionCodable() throws {
    let ref = AgentReflection(
      taskSummary: "Fixed login bug",
      insight: "The issue was in token validation",
      improvement: "Check token expiry first",
      succeeded: true
    )
    let data = try JSONEncoder().encode(ref)
    let decoded = try JSONDecoder().decode(AgentReflection.self, from: data)
    #expect(decoded.succeeded == true)
    #expect(decoded.taskSummary == "Fixed login bug")
  }

  @Test("CreateParams round-trips")
  func createParamsCodable() throws {
    let params = CreateParams(filePath: "index.html", content: "<h1>Hello</h1>")
    let data = try JSONEncoder().encode(params)
    let decoded = try JSONDecoder().decode(CreateParams.self, from: data)
    #expect(decoded.filePath == "index.html")
    #expect(decoded.content == "<h1>Hello</h1>")
  }

  @Test("ToolAction enum covers all cases including create")
  func toolActionCases() {
    let actions: [ToolAction] = [
      .bash(command: "ls"),
      .read(path: "file.swift"),
      .create(path: "new.swift", content: "code"),
      .write(path: "file.swift", content: "code"),
      .edit(path: "file.swift", find: "old", replace: "new"),
      .search(pattern: "TODO"),
    ]
    #expect(actions.count == 6)
  }
}
