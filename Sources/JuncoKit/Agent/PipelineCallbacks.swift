// PipelineCallbacks.swift — Callbacks for progress, errors, and streaming
//
// The Orchestrator is an actor — it can't directly interact with the terminal.
// These callback types let the CLI layer provide handlers that the Orchestrator
// calls during pipeline execution for progress updates, error recovery, and
// streamed text output.

import Foundation

/// Recovery action when a step fails.
public enum StepRecovery: Sendable {
  case retry    // Re-generate the action and try again
  case skip     // Move to the next step
  case abort    // Stop the pipeline
}

/// Called before each step executes. (currentStep, totalSteps, description)
public typealias ProgressHandler = @Sendable (Int, Int, String) async -> Void

/// Called when a step fails. Returns the user's recovery choice.
/// Parameters: (stepNumber, errorDescription)
public typealias ErrorRecoveryHandler = @Sendable (Int, String) async -> StepRecovery

/// Called with each chunk of streamed text output.
public typealias StreamHandler = @Sendable (String) async -> Void

/// All pipeline callbacks bundled together.
/// Pass to Orchestrator.run() to receive progress, handle errors, and stream output.
public struct PipelineCallbacks: Sendable {
  public let onProgress: ProgressHandler?
  public let onStepError: ErrorRecoveryHandler?
  public let onStream: StreamHandler?

  public init(
    onProgress: ProgressHandler? = nil,
    onStepError: ErrorRecoveryHandler? = nil,
    onStream: StreamHandler? = nil
  ) {
    self.onProgress = onProgress
    self.onStepError = onStepError
    self.onStream = onStream
  }

  /// Default callbacks (no-op): skip errors, no progress, no streaming.
  public static let none = PipelineCallbacks()
}
