// TranslationService.swift — Bidirectional translation for non-English sessions
//
// Detection: NLLanguageRecognizer identifies input language.
// Translation: 3-tier fallback:
//   1. Apple Translation framework (on-device, best quality)
//   2. AFM plain text generation (works with non-English, good quality)
//   3. Passthrough (no translation, agent sees original text)
//
// AFM's structured output (@Generable) rejects non-English prompts, so
// translation MUST happen before any generateStructured() call.

import Foundation
import NaturalLanguage
import Translation

public actor TranslationService {
  private var sessionLanguage: String?
  private var translationAvailable = false
  private var userNotified = false

  private let systemLanguage: String
  private let adapter: (any LLMAdapter)?

  nonisolated(unsafe) private static let availability = LanguageAvailability()

  /// Initialize with an optional AFM adapter for LLM-based translation fallback.
  public init(adapter: (any LLMAdapter)? = nil) {
    self.systemLanguage = Locale.current.language.languageCode?.identifier ?? "en"
    self.adapter = adapter
  }

  // MARK: - Input Processing

  /// Process user input: detect language, translate to English if needed.
  /// Returns (englishText, detectedLanguage, statusMessage).
  public func processInput(_ text: String) async -> (text: String, language: String?, message: String?) {
    let detected = detectLanguage(text)

    // Adopt non-English as session language
    if let detected, detected != "en", detected != "und" {
      if sessionLanguage == nil {
        sessionLanguage = detected
        translationAvailable = await checkInstalled(from: detected, to: "en")
      }
    }

    guard let lang = sessionLanguage, lang != "en" else {
      return (text, nil, nil)
    }

    // Tier 1: Apple Translation (installed on-device models)
    if translationAvailable {
      if let translated = await translateViaFramework(text, from: lang, to: "en") {
        return (translated, lang, nil)
      }
    }

    // Tier 2: AFM plain text (works with non-English)
    if adapter != nil {
      if let translated = await translateViaAFM(text, to: "English") {
        let message = userNotified ? nil : "afm-fallback:\(languageName(lang))"
        userNotified = true
        return (translated, lang, message)
      }
    }

    // Tier 3: Passthrough
    let message = userNotified ? nil : "not-installed:\(languageName(lang))"
    userNotified = true
    return (text, lang, message)
  }

  /// Translate agent output back to the session language.
  public func processOutput(_ text: String) async -> String? {
    guard let lang = sessionLanguage, lang != "en" else { return nil }

    // Tier 1: Apple Translation
    if translationAvailable {
      if let translated = await translateViaFramework(text, from: "en", to: lang) {
        return translated
      }
    }

    // Tier 2: AFM
    if adapter != nil {
      return await translateViaAFM(text, to: languageName(lang))
    }

    return nil
  }

  public var currentLanguage: String? { sessionLanguage }
  public var isTranslating: Bool { sessionLanguage != nil && sessionLanguage != "en" }

  public func setLanguage(_ code: String) async {
    if code != "en" {
      sessionLanguage = code
      translationAvailable = await checkInstalled(from: code, to: "en")
      userNotified = false
    }
  }

  public func reset() {
    sessionLanguage = nil
    translationAvailable = false
    userNotified = false
  }

  /// Check if models are installed and ready, or just supported.
  /// Returns a status message for the user.
  public func availabilityMessage(for langCode: String) async -> String {
    let installed = await checkInstalled(from: langCode, to: "en")
    if installed {
      return "\(languageName(langCode)) translation: installed and ready."
    }
    let supported = await checkSupported(from: langCode, to: "en")
    if supported {
      return "\(languageName(langCode)) translation: available but not downloaded. Download in System Settings > General > Language & Region > Translation Languages. Select 'On Device' for offline use."
    }
    return "\(languageName(langCode)) translation: not supported by Apple Translation. AFM will handle it directly."
  }

  // MARK: - Translation Backends

  private func translateViaFramework(_ text: String, from source: String, to target: String) async -> String? {
    let src = Locale.Language(identifier: source)
    let tgt = Locale.Language(identifier: target)

    do {
      let session = TranslationSession(installedSource: src, target: tgt)
      let result = try await session.translate(text)
      return result.targetText
    } catch {
      return nil
    }
  }

  private func translateViaAFM(_ text: String, to targetLanguage: String) async -> String? {
    guard let adapter else { return nil }
    do {
      let response = try await adapter.generate(
        prompt: text,
        system: "Translate the following text to \(targetLanguage). Output ONLY the translation, nothing else."
      )
      let trimmed = response.trimmingCharacters(in: .whitespacesAndNewlines)
      return trimmed.isEmpty ? nil : trimmed
    } catch {
      return nil
    }
  }

  // MARK: - Availability Checks

  private func checkInstalled(from source: String, to target: String) async -> Bool {
    let src = Locale.Language(identifier: source)
    let tgt = Locale.Language(identifier: target)
    let status = await Self.availability.status(from: src, to: tgt)
    return status == .installed
  }

  private func checkSupported(from source: String, to target: String) async -> Bool {
    let src = Locale.Language(identifier: source)
    let tgt = Locale.Language(identifier: target)
    let status = await Self.availability.status(from: src, to: tgt)
    return status == .supported || status == .installed
  }

  // MARK: - Helpers

  private func detectLanguage(_ text: String) -> String? {
    guard text.count >= 8 else { return nil }

    // Strip URLs and inline code — they confuse the recognizer
    // (e.g. "/lang=en/" in a URL triggers Dutch detection)
    var cleaned = text.replacingOccurrences(
      of: #"https?://\S+"#, with: "", options: .regularExpression)
    cleaned = cleaned.replacingOccurrences(
      of: #"`[^`]+`"#, with: "", options: .regularExpression)
    cleaned = cleaned.trimmingCharacters(in: .whitespacesAndNewlines)
    guard cleaned.count >= 8 else { return nil }

    let recognizer = NLLanguageRecognizer()
    recognizer.processString(cleaned)
    let hypotheses = recognizer.languageHypotheses(withMaximum: 1)
    guard let (lang, confidence) = hypotheses.first,
          confidence >= Config.languageDetectionConfidence else {
      return nil
    }

    // If detected language matches the system language, no translation needed
    let code = lang.rawValue
    if code == systemLanguage { return nil }
    return code
  }

  private func languageName(_ code: String) -> String {
    Locale.current.localizedString(forLanguageCode: code) ?? code
  }

  /// URL to open System Settings translation page.
  public static let settingsURL = "x-apple.systempreferences:com.apple.Localization-Settings"
}
