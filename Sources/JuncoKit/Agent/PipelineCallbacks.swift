// PipelineCallbacks.swift — Callbacks for progress, errors, permissions, and streaming
//
// The Orchestrator is an actor — it MUST NOT directly read from stdin.
// All user interaction goes through callbacks provided by the CLI layer.
// This ensures the CLI controls terminal mode (raw/cooked) at all times.

import Foundation

/// Recovery action when a step fails.
public enum StepRecovery: Sendable {
  case retry
  case skip
  case abort
}

/// Permission decision for file/shell operations.
public enum PermissionDecision: Sendable {
  case allow
  case deny
  case alwaysAllow
}

/// Called before each step executes. (currentStep, totalSteps, description)
public typealias ProgressHandler = @Sendable (Int, Int, String) async -> Void

/// Called when a step fails. Returns the user's recovery choice.
public typealias ErrorRecoveryHandler = @Sendable (Int, String) async -> StepRecovery

/// Called when the agent wants to write/edit/execute. Returns permission decision.
/// Parameters: (toolName, targetPath, detail)
public typealias PermissionHandler = @Sendable (String, String, String) async -> PermissionDecision

/// Called with each chunk of streamed text output.
public typealias StreamHandler = @Sendable (String) async -> Void

/// Called when the agent mode is detected (after classify).
public typealias ModeHandler = @Sendable (AgentMode) async -> Void

/// Called after each tool executes with the action and its output.
/// Parameters: (toolLabel, target, output)
public typealias ToolResultHandler = @Sendable (String, String, String) async -> Void

/// All pipeline callbacks bundled together.
public struct PipelineCallbacks: Sendable {
  public let onProgress: ProgressHandler?
  public let onStepError: ErrorRecoveryHandler?
  public let onPermission: PermissionHandler?
  public let onStream: StreamHandler?
  public let onMode: ModeHandler?
  public let onToolResult: ToolResultHandler?

  public init(
    onProgress: ProgressHandler? = nil,
    onStepError: ErrorRecoveryHandler? = nil,
    onPermission: PermissionHandler? = nil,
    onStream: StreamHandler? = nil,
    onMode: ModeHandler? = nil,
    onToolResult: ToolResultHandler? = nil
  ) {
    self.onProgress = onProgress
    self.onStepError = onStepError
    self.onPermission = onPermission
    self.onStream = onStream
    self.onMode = onMode
    self.onToolResult = onToolResult
  }

  /// Default callbacks: auto-allow permissions, skip errors, no progress.
  public static let none = PipelineCallbacks()
}
