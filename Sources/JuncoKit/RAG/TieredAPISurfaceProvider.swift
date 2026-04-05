// TieredAPISurfaceProvider.swift — Three-tier API discovery
//
// Tier 1: SwiftInterfaceIndex (SDK .swiftinterface files — comprehensive, offline)
// Tier 2: LSPClient (sourcekit-lsp — handles ObjC-bridged methods)
// Tier 3: SignatureIndex (static fallback — REST APIs, critical ObjC methods)

import Foundation

/// Concrete APISurfaceProvider that chains three discovery tiers.
public actor TieredAPISurfaceProvider: APISurfaceProvider {
  private let swiftInterfaceIndex: SwiftInterfaceIndex
  private let lspClient: LSPClient?
  private let staticFallback: SignatureIndex

  public init(
    swiftInterfaceIndex: SwiftInterfaceIndex,
    lspClient: LSPClient? = nil,
    staticFallback: SignatureIndex = .builtIn()
  ) {
    self.swiftInterfaceIndex = swiftInterfaceIndex
    self.lspClient = lspClient
    self.staticFallback = staticFallback
  }

  // MARK: - APISurfaceProvider

  public func lookupFix(compilerError: String) async -> String? {
    // Parse "no member" errors: "value of type 'X' has no member 'Y'"
    if let (typeName, member) = Self.parseNoMemberError(compilerError) {
      // Tier 1: SwiftInterfaceIndex
      if let match = await swiftInterfaceIndex.closestMember(to: member, on: typeName) {
        return "Correct API: \(String(match.signature.prefix(100)))"
      }

      // Tier 2: LSP workspace symbol
      if let lsp = lspClient {
        let symbols = await lsp.workspaceSymbol(query: "\(typeName) \(member)")
        if let first = symbols.first(where: {
          $0.name.lowercased().contains(member.lowercased()) ||
          member.lowercased().contains($0.name.lowercased())
        }) {
          return "Correct API: \(first.name) (in \(first.file))"
        }
      }
    }

    // Tier 3: Static fallback (handles argument label errors, REST APIs, etc.)
    return staticFallback.lookup(compilerError: compilerError)
  }

  public func frameworkFor(type: String) async -> String? {
    await swiftInterfaceIndex.typeBelongsTo(type)
  }

  public func knownTypes(in framework: String) async -> Set<String> {
    await swiftInterfaceIndex.allTypes(in: framework)
  }

  /// Preload frameworks detected in the project's imports.
  public func preloadFrameworks(_ frameworks: Set<String>) async {
    for fw in frameworks {
      await swiftInterfaceIndex.preload(fw)
    }
  }

  // MARK: - Error Parsing

  /// Parse "value of type 'X' has no member 'Y'" from compiler errors.
  static func parseNoMemberError(_ error: String) -> (typeName: String, member: String)? {
    // Pattern: "type 'X' has no member 'Y'"
    if let match = error.firstMatch(of: /type '(\w+)' has no member '(\w+)'/) {
      return (String(match.1), String(match.2))
    }
    // Pattern: "has no member 'Y'" (without explicit type)
    if let match = error.firstMatch(of: /has no member '(\w+)'/) {
      return (typeName: "", member: String(match.1))
    }
    return nil
  }
}
