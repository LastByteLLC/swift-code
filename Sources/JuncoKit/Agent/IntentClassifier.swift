// IntentClassifier.swift — ML-based intent classification
//
// Uses a Core ML text classifier (CRF, trained on 9.5K examples)
// to classify task type in ~10ms instead of ~2s LLM call.
// Falls back to LLM if the model isn't available.

import CoreML
import Foundation
import NaturalLanguage

/// Fast intent classification using trained Core ML models.
/// NLModel is not Sendable but is safe for our use: loaded once at init, read-only after.
public struct IntentClassifier: @unchecked Sendable {
  /// Task type classifier: fix/add/refactor/explain/test/explore
  private let taskTypeModel: NLModel?
  /// Mode classifier: build/search/plan/research
  private let modeModel: NLModel?

  public init() {
    self.taskTypeModel = Self.loadModel(name: "IntentClassifier")
    self.modeModel = Self.loadModel(name: "ModeClassifier")
  }

  /// Whether the task type ML model is available.
  public var isAvailable: Bool { taskTypeModel != nil }

  /// Whether the mode ML model is available.
  public var isModeAvailable: Bool { modeModel != nil }

  /// Classify task type from a query. Returns nil if model unavailable.
  public func classifyTaskType(_ query: String) -> String? {
    guard let model = taskTypeModel else { return nil }
    return model.predictedLabel(for: query)
  }

  /// Classify with confidence. Returns (label, confidence) or nil.
  public func classifyWithConfidence(_ query: String) -> (label: String, confidence: Double)? {
    guard let model = taskTypeModel else { return nil }
    guard let label = model.predictedLabel(for: query) else { return nil }
    let hypotheses = model.predictedLabelHypotheses(for: query, maximumCount: 1)
    let confidence = hypotheses[label] ?? 0.0
    return (label, confidence)
  }

  /// Classify mode from a query. Returns nil if model unavailable.
  public func classifyMode(_ query: String) -> (mode: String, confidence: Double)? {
    guard let model = modeModel else { return nil }
    guard let label = model.predictedLabel(for: query) else { return nil }
    let hypotheses = model.predictedLabelHypotheses(for: query, maximumCount: 1)
    let confidence = hypotheses[label] ?? 0.0
    return (label, confidence)
  }

  // MARK: - Embedding Prototype Mode Classifier

  /// Classify mode using NLEmbedding cosine similarity against prototype vectors.
  /// Faster than ML model (~0.02ms classification, ~5ms embedding), no model file needed.
  /// Returns nil if NLEmbedding unavailable or confidence too low.
  public func classifyModeByEmbedding(_ query: String) -> (mode: String, confidence: Double)? {
    guard let embedding = NLEmbedding.sentenceEmbedding(for: .english) else { return nil }
    guard let queryVector = embedding.vector(for: query) else { return nil }

    var bestMode = ""
    var bestSimilarity = -1.0

    for (mode, seeds) in Self.modePrototypeSeeds {
      // Average similarity against all seed queries for this mode
      var totalSim = 0.0
      var count = 0
      for seed in seeds {
        if let seedVector = embedding.vector(for: seed) {
          totalSim += Self.cosineSimilarity(queryVector, seedVector)
          count += 1
        }
      }
      let avgSim = count > 0 ? totalSim / Double(count) : 0
      if avgSim > bestSimilarity {
        bestSimilarity = avgSim
        bestMode = mode
      }
    }

    guard bestSimilarity > 0.3 else { return nil }
    return (bestMode, bestSimilarity)
  }

  /// Seed queries for each mode — used to compute prototype embeddings.
  /// Build: imperative actions that modify files.
  /// Answer: questions, searches, explanations, plans, research.
  private static let modePrototypeSeeds: [String: [String]] = [
    "build": [
      "fix the bug in auth", "create a new Swift file", "add error handling",
      "implement OAuth login", "refactor the network layer", "write tests for User",
      "this is broken", "make it conform to Sendable", "the tests are failing",
      "add a loading spinner", "convert to async/await", "clean up the imports",
      "delete the old migration", "rename the variable", "update the README",
      "fix the memory leak", "change the return type", "extract into a protocol",
      "needs error handling", "missing import",
    ],
    "answer": [
      // Search queries
      "where is AgentMode defined?", "what does the Orchestrator do?",
      "find TokenBudget", "show me the error handling", "how many Swift files?",
      "what protocols exist?", "where is the entry point?", "count the test cases",
      "who calls classify?", "what is the default timeout?",
      "list all enums", "where is the build target?", "find the config values",
      "which file has the login logic?", "what parameters does run take?",
      "what dependencies does this project use?",
      // Plan queries
      "plan how to add OAuth", "outline the migration steps",
      "design a caching strategy", "how should I structure the auth module?",
      "what would it take to add dark mode?", "scope out the refactor",
      "break down the feature", "architect the new module",
      // Research queries
      "research SwiftData API", "how does Apple's Keychain work?",
      "what's new in Swift 6?", "documentation for URLSession",
      "look up the Combine framework", "how does async/await work in Swift?",
      "research the Observable macro", "docs for MapKit",
      "how does CloudKit sync work?", "check the developer docs",
      "how to implement push notifications?",
      // Explain queries
      "explain this code", "what does this function do?", "how does this work?",
      "why is this structured this way?", "describe the architecture",
    ],
  ]

  /// Cosine similarity between two NLEmbedding vectors.
  private static func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var dot = 0.0, normA = 0.0, normB = 0.0
    for i in 0..<a.count {
      dot += a[i] * b[i]
      normA += a[i] * a[i]
      normB += b[i] * b[i]
    }
    let denom = sqrt(normA) * sqrt(normB)
    return denom > 0 ? dot / denom : 0
  }

  /// Load a model from common locations by name.
  private static func loadModel(name: String) -> NLModel? {
    let searchPaths = [
      Bundle.main.bundleURL.appendingPathComponent("\(name).mlmodelc"),
      URL(fileURLWithPath: "Training/\(name).mlmodelc"),
      URL(fileURLWithPath: NSHomeDirectory())
        .appendingPathComponent(".junco/models/\(name).mlmodelc"),
    ]

    for path in searchPaths {
      if FileManager.default.fileExists(atPath: path.path) {
        if let compiled = try? MLModel(contentsOf: path),
           let model = try? NLModel(mlModel: compiled) {
          return model
        }
      }
    }
    return nil
  }
}

/// Uses NLLanguageRecognizer to detect input language.
public struct LanguageDetector: Sendable {
  public init() {}

  /// Detect the dominant language of the input text.
  /// Returns ISO 639-1 code (e.g., "en", "es", "zh") or nil.
  public func detect(_ text: String) -> String? {
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(text)
    guard let language = recognizer.dominantLanguage else { return nil }
    return language.rawValue
  }

  /// Check if the input is likely English.
  public func isEnglish(_ text: String) -> Bool {
    let lang = detect(text)
    return lang == nil || lang == "en"
  }
}
