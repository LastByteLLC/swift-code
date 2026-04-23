// PromptOverrides.swift — Runtime overlay for system prompts in Prompts.swift.
//
// When $PROMPT_OVERRIDES_JSON points to a readable JSON file, fields present
// override their compiled-in defaults. Absent keys leave defaults intact.
// Only the static `*System` prompts are overridable in v1; template functions
// (e.g., planPrompt) still compose from code.

import Foundation

public struct PromptOverrides: Sendable, Codable {
  public var modeClassifySystem: String?
  public var classifySystem: String?
  public var planSystem: String?
  public var searchQuerySystem: String?
  public var searchSynthesizeSystem: String?
  public var planModeSystem: String?
  public var researchQuerySystem: String?
  public var researchSynthesizeSystem: String?
  public var observeSystem: String?

  public init() {}

  public static let shared: PromptOverrides = loadFromEnv()

  private static func loadFromEnv() -> PromptOverrides {
    guard let path = ProcessInfo.processInfo.environment["PROMPT_OVERRIDES_JSON"] else {
      return PromptOverrides()
    }
    guard let data = FileManager.default.contents(atPath: path) else {
      FileHandle.standardError.write(Data("[PromptOverrides] File not found: \(path)\n".utf8))
      return PromptOverrides()
    }
    do {
      return try JSONDecoder().decode(PromptOverrides.self, from: data)
    } catch {
      FileHandle.standardError.write(Data("[PromptOverrides] Parse failed \(path): \(error)\n".utf8))
      return PromptOverrides()
    }
  }
}
