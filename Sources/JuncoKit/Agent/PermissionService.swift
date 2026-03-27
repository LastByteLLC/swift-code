// PermissionService.swift — Permission rules with persistent always-allow
//
// IMPORTANT: This service NEVER reads from stdin. User interaction is handled
// by the CLI via PipelineCallbacks.onPermission. The orchestrator calls
// checkPermission() which returns .allow if pre-approved, .deny otherwise.
// The CLI wrapper in the orchestrator's executeTool calls the callback.

import Foundation

/// Manages persistent permission rules (always-allow).
/// Does NOT prompt the user — that's the CLI's job via PipelineCallbacks.
public struct PermissionService: Sendable {
  private let rulesPath: String

  public init(workingDirectory: String) {
    let dir = (workingDirectory as NSString).appendingPathComponent(Config.projectDirName)
    try? FileManager.default.createDirectory(atPath: dir, withIntermediateDirectories: true)
    self.rulesPath = (dir as NSString).appendingPathComponent("permissions.json")
  }

  /// Check if an action is pre-approved by a stored rule.
  /// Returns true if there's a matching always-allow rule.
  public func isAllowed(tool: String, target: String) -> Bool {
    let rules = loadRules()
    return rules.contains { $0.tool == tool && (target.contains($0.pattern) || $0.pattern == "*") }
  }

  /// Save an always-allow rule.
  public func saveAlwaysAllow(tool: String, target: String) {
    saveRule(tool: tool, pattern: target)
  }

  /// Format a permission prompt for display.
  public static func promptText(tool: String, target: String, detail: String = "") -> String {
    var msg = "junco wants to \(tool): \(target)"
    if !detail.isEmpty {
      msg += "\n  \(detail)"
    }
    return msg
  }

  // MARK: - Rules Persistence

  private func loadRules() -> [PermissionRule] {
    guard let data = FileManager.default.contents(atPath: rulesPath),
          let rules = try? JSONDecoder().decode([PermissionRule].self, from: data)
    else { return [] }
    return rules
  }

  private func saveRule(tool: String, pattern: String) {
    var rules = loadRules()
    if !rules.contains(where: { $0.tool == tool && $0.pattern == pattern }) {
      rules.append(PermissionRule(tool: tool, pattern: pattern))
      if let data = try? JSONEncoder().encode(rules) {
        try? data.write(to: URL(fileURLWithPath: rulesPath))
      }
    }
  }
}

struct PermissionRule: Codable, Sendable {
  let tool: String
  let pattern: String
}
