// ProgressBar.swift — Step-level progress display
//
// Shows "Step 2/5: editing auth.swift..." on the status line.
// Integrates with ThinkingPhrases for contextual messages.

import Foundation

/// Renders step-level progress on the terminal status line.
public struct ProgressBar: Sendable {
  private let phrases: ThinkingPhrases
  private var tick: Int = 0

  public init(phrases: ThinkingPhrases = ThinkingPhrases()) {
    self.phrases = phrases
  }

  /// Render a progress update for a pipeline step.
  public func render(step: Int, total: Int, tool: String, target: String) -> String {
    let spinner = ThinkingPhrases.spinner(tick: step)
    let phrase = phrases.phrase(for: tool)
    let progress = "[\(step)/\(total)]"
    let targetStr = target.isEmpty ? "" : " \(Style.dim(target))"
    return "\(spinner) \(Style.dim(progress)) \(phrase)\(targetStr)"
  }

  /// Render a generic stage status.
  public func renderStage(_ stage: String, detail: String = "") -> String {
    let spinner = ThinkingPhrases.spinner(tick: Int.random(in: 0..<10))
    let phrase = phrases.phrase(for: stage)
    if detail.isEmpty {
      return "\(spinner) \(phrase)"
    }
    return "\(spinner) \(phrase) \(Style.dim(detail))"
  }
}
