// TranslationService.swift — Bidirectional translation for non-English sessions
//
// Detects input language via NLLanguageRecognizer. If non-English:
// 1. Translates user input to English for the agent pipeline
// 2. Translates agent output back to the user's language
// 3. Remembers the session language so subsequent turns stay consistent
//
// Uses Apple's Translation framework (on-device). Requires language models
// to be downloaded in System Settings > General > Language & Region > Translation.
// Falls back to passthrough with a hint when models aren't installed.

import Foundation
import NaturalLanguage
import Translation

/// Manages bidirectional translation for a session.
public actor TranslationService {
  /// The detected session language (nil = English, no translation needed).
  private var sessionLanguage: String?

  /// Whether translation models are available for the session language.
  private var translationAvailable = false

  /// System language (from Locale preferences).
  private let systemLanguage: String

  // LanguageAvailability is stateless — safe for concurrent reads.
  nonisolated(unsafe) private static let availability = LanguageAvailability()

  public init() {
    self.systemLanguage = Locale.current.language.languageCode?.identifier ?? "en"
  }

  // MARK: - Input Processing

  /// Process user input: detect language, translate to English if needed.
  /// Returns (englishText, detectedLanguage).
  public func processInput(_ text: String) async -> (text: String, language: String?) {
    let detected = detectLanguage(text)

    // If we already have a session language, use it
    // If newly detected non-English, adopt it as session language
    if let detected, detected != "en", detected != "und" {
      if sessionLanguage == nil {
        sessionLanguage = detected
        translationAvailable = await checkAvailability(from: detected, to: "en")
      }
    }

    // No translation needed for English
    guard let lang = sessionLanguage, lang != "en" else {
      return (text, nil)
    }

    // Translate to English for the pipeline
    if translationAvailable {
      if let translated = await translate(text, from: lang, to: "en") {
        return (translated, lang)
      }
    }

    // Passthrough — translation not available
    return (text, lang)
  }

  /// Translate agent output back to the session language.
  /// Returns nil if no translation needed (English session).
  public func processOutput(_ text: String) async -> String? {
    guard let lang = sessionLanguage, lang != "en", translationAvailable else {
      return nil
    }
    return await translate(text, from: "en", to: lang)
  }

  /// Get the current session language.
  public var currentLanguage: String? { sessionLanguage }

  /// Whether the session is non-English.
  public var isTranslating: Bool { sessionLanguage != nil && sessionLanguage != "en" }

  /// Force-set the session language (e.g., from system locale).
  public func setLanguage(_ code: String) async {
    if code != "en" {
      sessionLanguage = code
      translationAvailable = await checkAvailability(from: code, to: "en")
    }
  }

  /// Reset to English.
  public func reset() {
    sessionLanguage = nil
    translationAvailable = false
  }

  // MARK: - Translation

  private func translate(_ text: String, from source: String, to target: String) async -> String? {
    let src = Locale.Language(identifier: source)
    let tgt = Locale.Language(identifier: target)

    let status = await Self.availability.status(from: src, to: tgt)
    guard status == .installed else { return nil }

    do {
      let session = TranslationSession(installedSource: src, target: tgt)
      let result = try await session.translate(text)
      return result.targetText
    } catch {
      return nil
    }
  }

  private func checkAvailability(from source: String, to target: String) async -> Bool {
    let src = Locale.Language(identifier: source)
    let tgt = Locale.Language(identifier: target)
    let status = await Self.availability.status(from: src, to: tgt)
    return status == .installed
  }

  private func detectLanguage(_ text: String) -> String? {
    // Short text is unreliable for detection
    guard text.count >= 8 else { return nil }
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(text)
    return recognizer.dominantLanguage?.rawValue
  }
}
