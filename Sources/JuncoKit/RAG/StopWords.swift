// StopWords.swift — NLTK stop word list for search term filtering
//
// Based on the NLTK English stop word corpus (179 words).
// The word list is in Resources/stopwords.txt for reference;
// it's compiled directly into the binary as a Set<String> for O(1) lookup.
// See: https://www.nltk.org/nltk_data/ (English stop words)

import Foundation

/// NLTK-based English stop words for filtering search queries.
/// Compiled into the binary — no runtime file loading needed.
public enum StopWords {

  // NLTK English stop words (179 words, alphabetically sorted)
  // Source: Resources/stopwords.txt
  public static let set: Set<String> = [
    "a", "about", "above", "after", "again", "against", "all", "am", "an",
    "and", "any", "are", "as", "at", "be", "because", "been", "before",
    "being", "below", "between", "both", "but", "by", "can", "did", "do",
    "does", "doing", "don", "down", "during", "each", "few", "for", "from",
    "further", "had", "has", "have", "having", "he", "her", "here", "hers",
    "herself", "him", "himself", "his", "how", "i", "if", "in", "into",
    "is", "it", "its", "itself", "just", "me", "more", "most", "my",
    "myself", "no", "nor", "not", "now", "of", "off", "on", "once", "only",
    "or", "other", "our", "ours", "ourselves", "out", "over", "own", "s",
    "same", "she", "should", "so", "some", "such", "t", "than", "that",
    "the", "their", "theirs", "them", "themselves", "then", "there",
    "these", "they", "this", "those", "through", "to", "too", "under",
    "until", "up", "very", "was", "we", "were", "what", "when", "where",
    "which", "while", "who", "whom", "why", "will", "with", "you", "your",
    "yours", "yourself", "yourselves",
  ]

  /// Check if a word is a stop word.
  public static func contains(_ word: String) -> Bool {
    set.contains(word.lowercased())
  }

  /// Filter stop words from an array, preserving order.
  public static func filter(_ words: [String]) -> [String] {
    words.filter { !contains($0) }
  }
}
