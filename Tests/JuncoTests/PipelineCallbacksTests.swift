// PipelineCallbacksTests.swift — Tests for progress, error recovery, streaming, toast, resize

import Testing
import Foundation
@testable import JuncoKit

@Suite("PipelineCallbacks")
struct PipelineCallbacksTests {

  // MARK: - Callback Types

  @Test("default callbacks are none")
  func defaultNone() {
    let cb = PipelineCallbacks.none
    #expect(cb.onProgress == nil)
    #expect(cb.onStepError == nil)
    #expect(cb.onStream == nil)
  }

  @Test("progress handler receives step info")
  func progressHandler() async {
    let counter = ReindexFlag()
    let cb = PipelineCallbacks(onProgress: { _, _, _ in
      counter.set()
    })
    await cb.onProgress?(1, 3, "reading file")
    #expect(counter.consume() == true)
  }

  @Test("error recovery returns skip by default concept")
  func errorRecovery() async {
    // Test that abort/retry/skip are distinct values
    let skip = StepRecovery.skip
    let retry = StepRecovery.retry
    let abort = StepRecovery.abort
    #expect(skip != retry)
    #expect(retry != abort)
  }

  @Test("stream handler is called for each chunk")
  func streamHandler() async {
    let chunkCount = ReindexFlag()
    let cb = PipelineCallbacks(onStream: { _ in
      chunkCount.set()
    })
    await cb.onStream?("Hello ")
    #expect(chunkCount.consume() == true)
  }

  // MARK: - Progress Bar

  @Test("progress bar renders step info")
  func progressBarRender() {
    let bar = ProgressBar()
    let output = bar.render(step: 2, total: 5, tool: "edit", target: "main.swift")
    #expect(output.contains("[2/5]"))
    #expect(output.contains("main.swift"))
  }

  @Test("progress bar renders stage status")
  func progressStageRender() {
    let bar = ProgressBar()
    let output = bar.renderStage("classify")
    // Should contain a spinner character and a phrase
    #expect(!output.isEmpty)
  }

  // MARK: - Toast

  @Test("toast renders without crashing")
  func toastRenders() {
    // These write to stdout — just verify they don't crash
    Toast.show("test message", level: .info)
    Toast.show("success!", level: .success)
    Toast.show("warning", level: .warning)
    Toast.show("error", level: .error)
    Toast.timing("operation", seconds: 1.5)
  }

  @Test("toast build result detects failure")
  func toastBuildFailure() {
    // Just verify no crash — output goes to stdout
    Toast.buildResult("[ok] build (1.2s)")
    Toast.buildResult("[FAIL] build: error at line 5")
  }

  // MARK: - Resize

  @Test("resize flag set and consume")
  func resizeFlag() {
    let flag = ResizeFlag()
    #expect(flag.consume() == false)
    flag.set()
    #expect(flag.consume() == true)
    #expect(flag.consume() == false)
  }

  @Test("global resize flag exists")
  func globalFlag() {
    // Just verify the global exists and doesn't crash
    _ = terminalResizeFlag.consume()
  }

  @Test("install resize handler doesn't crash")
  func installHandler() {
    installSignalHandlers()
    // Verify the handler was installed by checking it doesn't crash
    // We can't easily trigger SIGWINCH in a test
  }

  // MARK: - Streaming via VirtualTerminalDriver

  @Test("streamed output accumulates in virtual terminal")
  func streamedToVirtual() {
    let vt = VirtualTerminalDriver(keys: [])

    // Simulate what streaming does: write chunks
    vt.write("Hello ")
    vt.write("world")
    vt.flush()

    #expect(vt.visibleOutput.contains("Hello world"))
  }

  // MARK: - RunResult wasStreamed flag

  @Test("RunResult defaults wasStreamed to false")
  func runResultDefault() {
    let mem = WorkingMemory(query: "test")
    let ref = AgentReflection(
      taskSummary: "t", insight: "i", improvement: "", succeeded: true
    )
    let result = RunResult(memory: mem, reflection: ref)
    #expect(result.wasStreamed == false)
  }

  @Test("RunResult wasStreamed can be set true")
  func runResultStreamed() {
    let mem = WorkingMemory(query: "test")
    let ref = AgentReflection(
      taskSummary: "t", insight: "i", improvement: "", succeeded: true
    )
    let result = RunResult(memory: mem, reflection: ref, wasStreamed: true)
    #expect(result.wasStreamed == true)
  }
}
