// AFMInstructions.swift — @InstructionsBuilder helpers for the AFM backend
//
// AFM's LanguageModelSession takes a typed `Instructions` value rather than a
// raw String. The LLMAdapter protocol stays String-based for cross-backend
// portability (Ollama, Mock, Replay don't have Instructions); AFMAdapter
// lifts those Strings into Instructions via these builders.
//
// The builders also let us compose tool-aware instructions: when the caller
// passes native AFM Tools, the framework injects each tool's schema into
// the Instructions automatically (via Tool.includesSchemaInInstructions).

import FoundationModels

public enum AFMInstructions {

  /// Lift a plain String system prompt into an Instructions value.
  /// Empty / nil strings produce empty Instructions (the session runs without a system turn).
  @InstructionsBuilder
  public static func fromString(_ system: String?) -> Instructions {
    if let system, !system.isEmpty {
      system
    }
  }

  /// Compose a system prompt with a fixed prelude reminding the model it is
  /// running on-device under tight token budgets.
  @InstructionsBuilder
  public static func onDevice(_ system: String?) -> Instructions {
    "You are junco, an on-device Apple Foundation Models assistant."
    "Be concise — every token costs context."
    if let system, !system.isEmpty {
      system
    }
  }
}
