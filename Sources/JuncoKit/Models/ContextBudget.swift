// ContextBudget.swift — Domain-bucketed token allocation
//
// Independent token buckets with hard ceilings for each content domain.
// No section can steal from another — each has its own allocation.
// Safety margin absorbs token estimation errors.
// Inspired by Membrane's 9-bucket token algebra.

import Foundation

/// Independent token allocations for each content domain within a single LLM call.
/// Each bucket has a hard ceiling — no section can steal from another.
public struct ContextBudget: Sendable {
  /// System prompt (fixed, measured).
  public var system: Int
  /// Primary code context (file content, code snippets).
  public var fileContent: Int
  /// WorkingMemory compact description.
  public var memory: Int
  /// RAG results, search hits.
  public var retrieval: Int
  /// Past experience from ReflectionStore.
  public var reflections: Int
  /// MicroSkill hints.
  public var skillHints: Int
  /// Buffer for token estimation errors (~5%).
  public var safetyMargin: Int
  /// Reserved for model output.
  public var generation: Int

  /// Total tokens allocated across all buckets.
  public var total: Int {
    system + fileContent + memory + retrieval + reflections + skillHints + safetyMargin + generation
  }

  /// Tokens available for prompt content (everything except generation and safety).
  public var promptBudget: Int {
    system + fileContent + memory + retrieval + reflections + skillHints
  }

  /// Pipeline stage for proportional allocation.
  public enum Stage {
    case classify
    case plan
    case execute
    case reflect
  }

  /// Create a budget from a context window size with proportional allocation.
  /// Allocations are tuned per stage — execute gets most fileContent,
  /// plan gets more retrieval, etc.
  public static func forWindow(_ windowSize: Int, stage: Stage) -> ContextBudget {
    let margin = windowSize * Config.tokenSafetyMarginPercent / 100

    switch stage {
    case .classify:
      return ContextBudget(
        system: 100, fileContent: 0, memory: 0,
        retrieval: 200, reflections: 0, skillHints: 0,
        safetyMargin: margin, generation: 400
      )

    case .plan:
      return ContextBudget(
        system: 150, fileContent: 300, memory: 100,
        retrieval: 400, reflections: 50, skillHints: 50,
        safetyMargin: margin, generation: 800
      )

    case .execute:
      return ContextBudget(
        system: 150, fileContent: 800, memory: 200,
        retrieval: 300, reflections: 100, skillHints: 100,
        safetyMargin: margin, generation: 1500
      )

    case .reflect:
      return ContextBudget(
        system: 100, fileContent: 0, memory: 300,
        retrieval: 0, reflections: 0, skillHints: 0,
        safetyMargin: margin, generation: 400
      )
    }
  }

  /// Step-aware execute budget: at step 4+, reduce memory/retrieval and give tokens to fileContent.
  /// The model has established context by step 4 — needs more room for code generation.
  public static func forExecute(windowSize: Int, stepIndex: Int) -> ContextBudget {
    var budget = forWindow(windowSize, stage: .execute)
    if stepIndex >= 3 {
      let savedMemory = budget.memory - 100
      let savedRetrieval = budget.retrieval - 150
      budget.memory = 100
      budget.retrieval = 150
      budget.fileContent += savedMemory + savedRetrieval
    }
    return budget
  }
}
