// SwiftCodeBuilder.swift — Result builder DSL for generating syntactically-correct Swift code
//
// Guarantees structural correctness: matched braces, proper nesting, automatic indentation.
// Used by TemplateRenderer for Swift source templates (App entry points, test files, etc.)
// instead of fragile string concatenation.
//
// Usage:
//   let code = SwiftCode {
//     Import("SwiftUI")
//     Blank()
//     Struct("MyApp", attributes: ["@main"], conformances: ["App"]) {
//       Property("@State private var vm = ViewModel()")
//       ComputedVar("body", type: "some Scene") {
//         Line("WindowGroup {")
//         Line("    ContentView()")
//         Line("}")
//       }
//     }
//   }
//   let source = code.render()

import Foundation

// MARK: - Node Types

/// A node in the Swift code tree. Each node renders itself with automatic indentation.
public indirect enum SwiftNode: Sendable {
  /// `import Module`
  case importDecl(String)
  /// Empty line
  case blank
  /// A type declaration (struct, class, actor, enum) with attributes, conformances, and members.
  /// Automatically renders opening/closing braces.
  case typeDecl(keyword: String, name: String, attributes: [String], conformances: [String], members: [SwiftNode])
  /// A stored property declaration (rendered as-is with indentation).
  case property(String)
  /// A computed property with automatic `var name: Type { ... }` wrapping.
  case computedProperty(name: String, type: String, body: [SwiftNode])
  /// A function with automatic `signature { ... }` wrapping.
  case function(signature: String, body: [SwiftNode])
  /// A raw line of code (rendered as-is with indentation).
  case line(String)
  /// A comment line.
  case comment(String)

  /// Render this node to a string with the given indentation level.
  public func render(indent: Int) -> String {
    let pad = String(repeating: "    ", count: indent)
    switch self {

    case .importDecl(let module):
      return "\(pad)import \(module)"

    case .blank:
      return ""

    case .typeDecl(let keyword, let name, let attributes, let conformances, let members):
      let conf = conformances.isEmpty ? "" : ": \(conformances.joined(separator: ", "))"
      var lines: [String] = []
      for attr in attributes {
        lines.append("\(pad)\(attr)")
      }
      lines.append("\(pad)\(keyword) \(name)\(conf) {")
      for member in members {
        lines.append(member.render(indent: indent + 1))
      }
      lines.append("\(pad)}")
      return lines.joined(separator: "\n")

    case .property(let decl):
      return "\(pad)\(decl)"

    case .computedProperty(let name, let type, let body):
      var lines = ["\(pad)var \(name): \(type) {"]
      for node in body {
        lines.append(node.render(indent: indent + 1))
      }
      lines.append("\(pad)}")
      return lines.joined(separator: "\n")

    case .function(let sig, let body):
      var lines = ["\(pad)\(sig) {"]
      for node in body {
        lines.append(node.render(indent: indent + 1))
      }
      lines.append("\(pad)}")
      return lines.joined(separator: "\n")

    case .line(let text):
      return text.isEmpty ? "" : "\(pad)\(text)"

    case .comment(let text):
      return "\(pad)// \(text)"
    }
  }
}

// MARK: - Result Builder

/// Result builder for composing Swift code trees with natural syntax.
@resultBuilder
public struct SwiftCodeBuilder {
  public static func buildBlock(_ components: [SwiftNode]...) -> [SwiftNode] {
    components.flatMap { $0 }
  }

  public static func buildExpression(_ node: SwiftNode) -> [SwiftNode] {
    [node]
  }

  public static func buildOptional(_ component: [SwiftNode]?) -> [SwiftNode] {
    component ?? []
  }

  public static func buildArray(_ components: [[SwiftNode]]) -> [SwiftNode] {
    components.flatMap { $0 }
  }

  public static func buildEither(first component: [SwiftNode]) -> [SwiftNode] {
    component
  }

  public static func buildEither(second component: [SwiftNode]) -> [SwiftNode] {
    component
  }
}

// MARK: - Top-Level Container

/// A complete Swift source file built from nodes.
public struct SwiftCode: Sendable {
  public let nodes: [SwiftNode]

  public init(@SwiftCodeBuilder _ builder: () -> [SwiftNode]) {
    self.nodes = builder()
  }

  /// Render the complete file to a String, with trailing newline.
  public func render() -> String {
    nodes.map { $0.render(indent: 0) }.joined(separator: "\n") + "\n"
  }
}

// MARK: - Convenience Functions (used inside @SwiftCodeBuilder blocks)

/// `import Module`
public func Import(_ module: String) -> SwiftNode { .importDecl(module) }

/// Empty line separator.
public func Blank() -> SwiftNode { .blank }

/// A stored property or other single-line declaration.
public func Property(_ decl: String) -> SwiftNode { .property(decl) }

/// A raw line of code.
public func Line(_ text: String) -> SwiftNode { .line(text) }

/// A comment line.
public func Comment(_ text: String) -> SwiftNode { .comment(text) }

/// A struct declaration with automatic brace matching.
public func Struct(
  _ name: String,
  attributes: [String] = [],
  conformances: [String] = [],
  @SwiftCodeBuilder members: () -> [SwiftNode]
) -> SwiftNode {
  .typeDecl(keyword: "struct", name: name, attributes: attributes, conformances: conformances, members: members())
}

/// A class declaration with automatic brace matching.
public func Class(
  _ name: String,
  attributes: [String] = [],
  conformances: [String] = [],
  @SwiftCodeBuilder members: () -> [SwiftNode]
) -> SwiftNode {
  .typeDecl(keyword: "class", name: name, attributes: attributes, conformances: conformances, members: members())
}

/// An actor declaration with automatic brace matching.
public func Actor(
  _ name: String,
  attributes: [String] = [],
  conformances: [String] = [],
  @SwiftCodeBuilder members: () -> [SwiftNode]
) -> SwiftNode {
  .typeDecl(keyword: "actor", name: name, attributes: attributes, conformances: conformances, members: members())
}

/// An enum declaration with automatic brace matching.
public func Enum(
  _ name: String,
  attributes: [String] = [],
  conformances: [String] = [],
  @SwiftCodeBuilder members: () -> [SwiftNode]
) -> SwiftNode {
  .typeDecl(keyword: "enum", name: name, attributes: attributes, conformances: conformances, members: members())
}

/// A computed property with automatic `var name: Type { ... }` wrapping.
public func ComputedVar(
  _ name: String,
  type: String,
  @SwiftCodeBuilder body: () -> [SwiftNode]
) -> SwiftNode {
  .computedProperty(name: name, type: type, body: body())
}

/// A function with automatic `signature { ... }` wrapping.
public func Function(
  _ signature: String,
  @SwiftCodeBuilder body: () -> [SwiftNode]
) -> SwiftNode {
  .function(signature: signature, body: body())
}
