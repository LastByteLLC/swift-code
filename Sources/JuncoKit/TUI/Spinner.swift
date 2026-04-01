// Spinner.swift — Animated terminal spinner with rotating thinking phrases
//
// Runs a background task that updates the terminal status line at ~10fps.
// Uses ThinkingPhrases for stage-appropriate messages. Phrases rotate
// every few seconds to give a sense of progress.
//
// Usage:
//   let spinner = Spinner(phrases: phrases)
//   await spinner.start(stage: "plan")
//   // ... do work ...
//   await spinner.update(stage: "execute", detail: "Step 2/5")
//   await spinner.stop()

import Foundation

/// An animated spinner that updates the terminal status line on a timer.
/// Safe to use from any async context — all mutation is actor-isolated.
public actor Spinner {
  private let phrases: ThinkingPhrases
  private let interval: TimeInterval
  private var task: Task<Void, Never>?
  private var tick: Int = 0
  private var currentStage: String = ""
  private var currentDetail: String = ""
  private var phraseText: String = ""
  private var phraseAge: Int = 0
  private let phraseRotateInterval: Int  // Rotate phrase every N ticks

  /// How the spinner renders its output. Replaceable for testing.
  private let render: @Sendable (String) -> Void

  /// Create a spinner with thinking phrases and rendering target.
  /// - Parameters:
  ///   - phrases: Source of stage-specific status phrases
  ///   - fps: Animation frame rate (default 10)
  ///   - phraseRotateSeconds: How often to pick a new phrase (default 3)
  ///   - render: Closure that displays the status text (default: Terminal.status)
  public init(
    phrases: ThinkingPhrases,
    fps: Int = 10,
    phraseRotateSeconds: Int = 3,
    render: @escaping @Sendable (String) -> Void = { Terminal.status($0) }
  ) {
    self.phrases = phrases
    self.interval = 1.0 / Double(max(1, fps))
    self.phraseRotateInterval = max(1, phraseRotateSeconds) * max(1, fps)
    self.render = render
  }

  /// Start the spinner for a pipeline stage.
  public func start(stage: String, detail: String = "") {
    currentStage = stage
    currentDetail = detail
    tick = 0
    phraseAge = 0
    phraseText = phrases.phrase(for: stage)

    task?.cancel()
    let sleepMs = max(50, Int(interval * 1000))
    task = Task { [weak self] in
      while !Task.isCancelled {
        await self?.renderFrame()
        try? await Task.sleep(for: .milliseconds(sleepMs))
      }
    }
  }

  /// Update the spinner's stage and/or detail without restarting.
  public func update(stage: String? = nil, detail: String? = nil) {
    if let s = stage, s != currentStage {
      currentStage = s
      phraseText = phrases.phrase(for: s)
      phraseAge = 0
    }
    if let d = detail {
      currentDetail = d
    }
  }

  /// Stop the spinner and clear the status line.
  public func stop() {
    task?.cancel()
    task = nil
    Terminal.clearLine()
  }

  /// Whether the spinner is currently running.
  public var isRunning: Bool { task != nil }

  // MARK: - Internal

  private func renderFrame() {
    tick += 1
    phraseAge += 1

    // Rotate phrase periodically
    if phraseAge >= phraseRotateInterval {
      phraseText = phrases.phrase(for: currentStage)
      phraseAge = 0
    }

    let frame = ThinkingPhrases.spinnerFrames[tick % ThinkingPhrases.spinnerFrames.count]
    let line: String
    if currentDetail.isEmpty {
      line = Style.red("\(frame) \(phraseText)...")
    } else {
      line = Style.red("\(frame) \(phraseText)...") + " " + Style.dim(currentDetail)
    }
    render(line)
  }
}
