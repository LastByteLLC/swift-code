// APISurfaceProvider.swift — Protocol for runtime API signature discovery
//
// Abstracts the source of API knowledge behind a protocol.
// Implementations can use SDK parsing, LSP, or static tables.

import Foundation

/// Protocol for looking up correct API signatures at runtime.
/// Used by CandidateGenerator to provide fix hints when the model hallucinates API names.
public protocol APISurfaceProvider: Sendable {
  /// Find the correct API signature for a compiler error.
  /// Returns a hint string suitable for prompt injection (~80 chars).
  func lookupFix(compilerError: String) async -> String?

  /// Which framework provides this type?
  func frameworkFor(type: String) async -> String?

  /// All known type names in a framework (for import detection).
  func knownTypes(in framework: String) async -> Set<String>
}
