// PermissionTests.swift — Tests for permission rules, callbacks, and all branches

import Testing
import Foundation
@testable import JuncoKit

@Suite("Permission")
struct PermissionTests {

  private func makeTempDir() -> String {
    let dir = NSTemporaryDirectory() + "junco-perm-\(UUID().uuidString)"
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    return dir
  }

  // MARK: - PermissionService (rules only, no stdin)

  @Test("isAllowed returns false when no rules exist")
  func noRules() {
    let dir = makeTempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let svc = PermissionService(workingDirectory: dir)
    #expect(!svc.isAllowed(tool: "write", target: "test.swift"))
  }

  @Test("isAllowed returns true after saveAlwaysAllow")
  func alwaysAllow() {
    let dir = makeTempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let svc = PermissionService(workingDirectory: dir)
    svc.saveAlwaysAllow(tool: "write", target: "test.swift")
    #expect(svc.isAllowed(tool: "write", target: "test.swift"))
  }

  @Test("isAllowed matches wildcard pattern")
  func wildcardAllow() {
    let dir = makeTempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let svc = PermissionService(workingDirectory: dir)
    svc.saveAlwaysAllow(tool: "edit", target: "*")
    #expect(svc.isAllowed(tool: "edit", target: "anything.swift"))
    #expect(svc.isAllowed(tool: "edit", target: "deep/path/file.js"))
  }

  @Test("isAllowed is tool-specific")
  func toolSpecific() {
    let dir = makeTempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let svc = PermissionService(workingDirectory: dir)
    svc.saveAlwaysAllow(tool: "write", target: "test.swift")
    #expect(svc.isAllowed(tool: "write", target: "test.swift"))
    #expect(!svc.isAllowed(tool: "edit", target: "test.swift"))
  }

  @Test("rules persist across instances")
  func persistence() {
    let dir = makeTempDir()
    defer { try? FileManager.default.removeItem(atPath: dir) }
    let svc1 = PermissionService(workingDirectory: dir)
    svc1.saveAlwaysAllow(tool: "bash", target: "*")

    let svc2 = PermissionService(workingDirectory: dir)
    #expect(svc2.isAllowed(tool: "bash", target: "any-command"))
  }

  @Test("promptText formats correctly")
  func promptFormat() {
    let text = PermissionService.promptText(tool: "write", target: "main.swift", detail: "42 chars")
    #expect(text.contains("write"))
    #expect(text.contains("main.swift"))
    #expect(text.contains("42 chars"))
  }

  // MARK: - PipelineCallbacks permission branching

  @Test("callback allow branch")
  func callbackAllow() async {
    let cb = PipelineCallbacks(onPermission: { _, _, _ in .allow })
    let decision = await cb.onPermission?("write", "test.swift", "10 chars")
    #expect(decision == .allow)
  }

  @Test("callback deny branch")
  func callbackDeny() async {
    let cb = PipelineCallbacks(onPermission: { _, _, _ in .deny })
    let decision = await cb.onPermission?("write", "test.swift", "10 chars")
    #expect(decision == .deny)
  }

  @Test("callback alwaysAllow branch")
  func callbackAlwaysAllow() async {
    let cb = PipelineCallbacks(onPermission: { _, _, _ in .alwaysAllow })
    let decision = await cb.onPermission?("write", "test.swift", "10 chars")
    #expect(decision == .alwaysAllow)
  }

  @Test("no callback means auto-allow (nil handler)")
  func noCallback() async {
    let cb = PipelineCallbacks.none
    // When there's no permission handler, the orchestrator auto-allows
    #expect(cb.onPermission == nil)
  }

  @Test("callback receives correct tool and target")
  func callbackReceivesParams() async {
    let receivedFlag = ReindexFlag()
    let cb = PipelineCallbacks(onPermission: { tool, target, detail in
      if tool == "edit" && target == "auth.swift" && detail == "replacing 10 chars" {
        receivedFlag.set()
      }
      return .allow
    })
    _ = await cb.onPermission?("edit", "auth.swift", "replacing 10 chars")
    #expect(receivedFlag.consume() == true)
  }

  // MARK: - PermissionDecision enum

  @Test("PermissionDecision values are distinct")
  func distinctValues() {
    let allow = PermissionDecision.allow
    let deny = PermissionDecision.deny
    let always = PermissionDecision.alwaysAllow
    #expect(allow != deny)
    #expect(deny != always)
    #expect(allow != always)
  }
}
