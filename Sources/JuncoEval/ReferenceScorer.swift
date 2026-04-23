// ReferenceScorer.swift — Text-layer quality via canonical-answer embedding similarity.
//
// Authors canonical answers for select cases; at eval time, compute cosine similarity
// via NLEmbedding between the candidate's answer and the reference. Cheap, deterministic
// — avoids the oracle-gaming surface an LLM-judge would introduce.
//
// Cases without a reference get no score (nil). Downstream aggregators treat nil as missing.

import Foundation
import NaturalLanguage

struct ReferenceScorer {
  private let embedding: NLEmbedding?
  let references: [String: String]

  init(workingDirectory: String) {
    self.embedding = NLEmbedding.sentenceEmbedding(for: .english)
    let path = (workingDirectory as NSString)
      .appendingPathComponent("fixtures/reference_answers.json")
    if let data = FileManager.default.contents(atPath: path),
       let refs = try? JSONDecoder().decode([String: String].self, from: data) {
      self.references = refs
    } else {
      self.references = [:]
    }
  }

  var hasReferences: Bool { !references.isEmpty && embedding != nil }

  /// Cosine similarity between the candidate answer and the reference for this case,
  /// or nil if no reference exists or NLEmbedding is unavailable.
  func score(caseName: String, answer: String) -> Double? {
    guard let embedding,
          let reference = references[caseName],
          let referenceVec = embedding.vector(for: reference),
          let answerVec = embedding.vector(for: answer)
    else { return nil }
    return Self.cosineSimilarity(Array(referenceVec), Array(answerVec))
  }

  static func cosineSimilarity(_ a: [Double], _ b: [Double]) -> Double {
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
}
