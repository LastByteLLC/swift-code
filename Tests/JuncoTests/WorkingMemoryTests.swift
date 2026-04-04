// WorkingMemoryTests.swift

import Testing
@testable import JuncoKit

@Suite("WorkingMemory")
struct WorkingMemoryTests {

  @Test("compact description includes query")
  func compactIncludesQuery() {
    let memory = WorkingMemory(query: "fix the login bug")
    let desc = memory.compactDescription()
    #expect(desc.contains("fix the login bug"))
  }

  @Test("compact description includes intent after classification")
  func compactIncludesIntent() {
    var memory = WorkingMemory(query: "test")
    memory.intent = AgentIntent(
      domain: "swift",
      taskType: "fix",
      complexity: "simple",
      mode: "build",
      targets: ["Auth.swift"]
    )
    let desc = memory.compactDescription()
    #expect(desc.contains("swift"))
    #expect(desc.contains("fix"))
  }

  @Test("observations auto-compact to last 5")
  func observationCompaction() {
    var memory = WorkingMemory(query: "test")
    for i in 0..<10 {
      memory.addObservation(StepObservation(
        tool: "bash", outcome: .ok, keyFact: "step \(i)"
      ))
    }
    #expect(memory.observations.count == 5)
    #expect(memory.observations.first?.keyFact == "step 5")
  }

  @Test("errors auto-compact to last 5")
  func errorCompaction() {
    var memory = WorkingMemory(query: "test")
    for i in 0..<8 {
      memory.addError("error \(i)")
    }
    #expect(memory.errors.count == 5)
    #expect(memory.errors.first == "error 3")
  }

  @Test("touched files are tracked")
  func touchedFiles() {
    var memory = WorkingMemory(query: "test")
    memory.touch("a.swift")
    memory.touch("b.swift")
    memory.touch("a.swift")  // duplicate
    #expect(memory.touchedFiles.count == 2)
  }

  @Test("LLM call tracking accumulates")
  func callTracking() {
    var memory = WorkingMemory(query: "test")
    memory.trackCall(estimatedTokens: 800)
    memory.trackCall(estimatedTokens: 1500)
    #expect(memory.llmCalls == 2)
    #expect(memory.totalTokensUsed == 2300)
  }

  @Test("step advancement works")
  func stepAdvancement() {
    var memory = WorkingMemory(query: "test")
    #expect(memory.currentStepIndex == 0)
    memory.advanceStep()
    #expect(memory.currentStepIndex == 1)
  }

  @Test("didSucceed returns false when no observations")
  func didSucceedNoObs() {
    let memory = WorkingMemory(query: "test")
    #expect(!memory.didSucceed)
  }

  @Test("didSucceed returns false when all observations are errors")
  func didSucceedAllErrors() {
    var memory = WorkingMemory(query: "test")
    memory.addObservation(StepObservation(tool: "read", outcome: .error, keyFact: "file not found"))
    memory.addError("Step 1: file not found")
    #expect(!memory.didSucceed)
  }

  @Test("didSucceed returns true when last observation is ok and no errors")
  func didSucceedHappy() {
    var memory = WorkingMemory(query: "test")
    memory.addObservation(StepObservation(tool: "write", outcome: .ok, keyFact: "written file"))
    #expect(memory.didSucceed)
  }

  @Test("didSucceed returns true when errors exist but last observation is ok")
  func didSucceedRecovered() {
    var memory = WorkingMemory(query: "test")
    memory.addObservation(StepObservation(tool: "read", outcome: .error, keyFact: "not found"))
    memory.addError("Step 1 failed")
    memory.addObservation(StepObservation(tool: "write", outcome: .ok, keyFact: "created file"))
    #expect(memory.didSucceed)
  }

  @Test("didSucceed returns false when last observation is error despite earlier success")
  func didSucceedEndedBadly() {
    var memory = WorkingMemory(query: "test")
    memory.addObservation(StepObservation(tool: "write", outcome: .ok, keyFact: "written"))
    memory.addObservation(StepObservation(tool: "bash", outcome: .error, keyFact: "build failed"))
    memory.addError("Build failed")
    #expect(!memory.didSucceed)
  }

  @Test("compact description includes project root")
  func compactIncludesProjectRoot() {
    let memory = WorkingMemory(query: "test", workingDirectory: "/Users/dev/Projects/MyApp")
    let desc = memory.compactDescription()
    #expect(desc.contains("Projects/MyApp"))
  }

  @Test("compact description fits within budget")
  func compactFitsBudget() {
    var memory = WorkingMemory(query: "refactor the entire authentication module to use async/await")
    memory.intent = AgentIntent(
      domain: "swift", taskType: "refactor", complexity: "complex",
      mode: "build", targets: ["Auth.swift", "Session.swift", "Token.swift"]
    )
    for i in 0..<5 {
      memory.addObservation(StepObservation(
        tool: "edit", outcome: .ok, keyFact: "updated function \(i)"
      ))
    }

    let desc = memory.compactDescription(tokenBudget: 200)
    let tokens = TokenBudget.estimate(desc)
    // Allow some overhead from the truncation marker
    #expect(tokens <= 250, "Compact description used \(tokens) tokens, budget was 200")
  }
}
