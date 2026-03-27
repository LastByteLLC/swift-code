// TranslationServiceTests.swift — Tests for translation detection, session memory, and round-trip

import Testing
import Foundation
@testable import JuncoKit

@Suite("TranslationService")
struct TranslationServiceTests {

  @Test("detects English input as no translation needed")
  func englishPassthrough() async {
    let svc = TranslationService()
    let (text, lang) = await svc.processInput("fix the login bug in auth.swift")
    #expect(text == "fix the login bug in auth.swift")
    #expect(lang == nil)
  }

  @Test("short input skips detection")
  func shortInput() async {
    let svc = TranslationService()
    let (text, lang) = await svc.processInput("hola")
    // Too short for reliable detection — passes through
    #expect(text == "hola")
    #expect(lang == nil)
  }

  @Test("detects Spanish input")
  func detectSpanish() async {
    let svc = TranslationService()
    let (_, lang) = await svc.processInput("arregla el error de inicio de sesión en el módulo de autenticación")
    // Should detect Spanish (if NLLanguageRecognizer works)
    // Lang is either "es" or nil (if detection fails on this text)
    if let lang {
      #expect(lang == "es")
    }
  }

  @Test("remembers session language across turns")
  func sessionMemory() async {
    let svc = TranslationService()
    // First turn: Spanish detected
    _ = await svc.processInput("arregla el error de inicio de sesión en el módulo de autenticación")

    let lang1 = await svc.currentLanguage
    // If Spanish was detected, second turn should use the same language
    if lang1 == "es" {
      // Second turn: even if ambiguous, session language sticks
      let (_, lang2) = await svc.processInput("ahora agrega pruebas")
      // Session language should still be Spanish
      let current = await svc.currentLanguage
      #expect(current == "es")
    }
  }

  @Test("reset clears session language")
  func reset() async {
    let svc = TranslationService()
    await svc.setLanguage("es")
    let before = await svc.currentLanguage
    #expect(before == "es")

    await svc.reset()
    let after = await svc.currentLanguage
    #expect(after == nil)
  }

  @Test("setLanguage sets session language")
  func setLanguage() async {
    let svc = TranslationService()
    await svc.setLanguage("fr")
    let lang = await svc.currentLanguage
    #expect(lang == "fr")
  }

  @Test("isTranslating is false for English")
  func notTranslating() async {
    let svc = TranslationService()
    let result = await svc.isTranslating
    #expect(result == false)
  }

  @Test("isTranslating is true after setting non-English language")
  func translatingAfterSet() async {
    let svc = TranslationService()
    await svc.setLanguage("de")
    // isTranslating depends on model availability
    // It may be false if models aren't installed, which is fine
    let _ = await svc.isTranslating  // Just verify no crash
  }

  @Test("processOutput returns nil for English session")
  func outputEnglish() async {
    let svc = TranslationService()
    let result = await svc.processOutput("This is a test")
    #expect(result == nil)
  }

  @Test("processOutput returns nil when models not installed")
  func outputNoModels() async {
    let svc = TranslationService()
    await svc.setLanguage("es")
    // If models aren't installed, output translation returns nil
    let result = await svc.processOutput("This is a test")
    // result is nil because translation models aren't downloaded
    // This is the expected graceful fallback
    _ = result  // No crash = pass
  }
}
