// TreeSitterRepairTests.swift — Tests for AST-guided structural repair

import Foundation
import Testing
@testable import JuncoKit

@Suite("TreeSitterRepair")
struct TreeSitterRepairTests {

  let repair = TreeSitterRepair()

  // MARK: - Clean Input (no-op)

  @Test("Clean code passes through unchanged")
  func cleanCodeNoOp() {
    let code = """
      import Foundation

      struct Podcast: Codable, Identifiable {
          var id = UUID()
          var name: String
      }

      """
    let (result, fixes) = repair.repair(code)
    #expect(fixes.isEmpty)
    #expect(result == code)
  }

  // MARK: - Strip Leading Prose

  @Test("Strip leading prose before import")
  func stripLeadingProse() {
    let code = """
      Here is the Swift code you requested:

      import SwiftUI

      struct ContentView: View {
          var body: some View {
              Text("Hello")
          }
      }
      """
    let (result, fixes) = repair.repair(code)
    #expect(fixes.contains("stripped leading prose"))
    #expect(result.hasPrefix("import SwiftUI"))
    #expect(!result.contains("Here is the Swift"))
  }

  @Test("Strip multi-line prose before code")
  func stripMultiLineProse() {
    let code = """
      Below is the implementation.
      This creates a simple model type.

      struct Item: Identifiable {
          var id = UUID()
      }
      """
    let (result, fixes) = repair.repair(code)
    #expect(fixes.contains("stripped leading prose"))
    #expect(result.hasPrefix("struct Item"))
  }

  @Test("Preserve leading comments")
  func preserveLeadingComments() {
    let code = """
      // MARK: - Models

      struct Item: Identifiable {
          var id = UUID()
      }
      """
    let (result, fixes) = repair.repair(code)
    #expect(!fixes.contains("stripped leading prose"))
    #expect(result.contains("// MARK:"))
  }

  // MARK: - Strip Trailing Junk

  @Test("Strip trailing prose after code")
  func stripTrailingJunk() {
    let code = """
      import Foundation

      struct Item {
          var name: String
      }

      This completes the implementation.
      Let me know if you need changes.
      """
    let (result, fixes) = repair.repair(code)
    #expect(fixes.contains("stripped trailing junk"))
    #expect(!result.contains("This completes"))
    #expect(result.contains("struct Item"))
  }

  // MARK: - Balance Braces

  @Test("Append one missing closing brace")
  func missingOneBrace() {
    let code = """
      struct Foo {
          func bar() {
              print("hello")
          }
      """
    let (result, fixes) = repair.repair(code)
    #expect(fixes.contains("balanced braces"))
    // Count braces in result
    let opens = result.filter { $0 == "{" }.count
    let closes = result.filter { $0 == "}" }.count
    #expect(opens == closes)
  }

  @Test("Append two missing closing braces")
  func missingTwoBraces() {
    let code = """
      struct Foo {
          func bar() {
              print("hello")
      """
    let (result, fixes) = repair.repair(code)
    #expect(fixes.contains("balanced braces"))
    let opens = result.filter { $0 == "{" }.count
    let closes = result.filter { $0 == "}" }.count
    #expect(opens == closes)
  }

  @Test("Remove extra trailing braces")
  func extraTrailingBraces() {
    let code = """
      struct Foo {
          var x: Int
      }
      }
      }
      """
    let (result, fixes) = repair.repair(code)
    #expect(fixes.contains("balanced braces"))
    let opens = result.filter { $0 == "{" }.count
    let closes = result.filter { $0 == "}" }.count
    #expect(opens == closes)
  }

  @Test("Already balanced braces are unchanged")
  func balancedBraces() {
    let code = """
      struct Foo {
          func bar() {
              print("hello")
          }
      }
      """
    let result = repair.balanceBraces(code)
    #expect(result == code)
  }

  // MARK: - Unterminated Strings

  @Test("Close unterminated string literal")
  func unterminatedString() {
    let code = """
      let greeting = "hello
      let x = 42
      """
    let (result, fixes) = repair.repair(code)
    #expect(fixes.contains("closed unterminated string"))
    // The first line should now have a closing quote
    let firstLine = result.components(separatedBy: "\n").first ?? ""
    let quoteCount = firstLine.filter { $0 == "\"" }.count
    #expect(quoteCount % 2 == 0)
  }

  // MARK: - Combined Defects

  @Test("Fix prose + missing brace together")
  func combinedProseAndBrace() {
    let code = """
      Here's your code:

      import SwiftUI

      struct ContentView: View {
          var body: some View {
              Text("Hello")
          }
      """
    let (result, fixes) = repair.repair(code)
    #expect(fixes.contains("stripped leading prose"))
    #expect(fixes.contains("balanced braces"))
    #expect(result.hasPrefix("import SwiftUI"))
    let opens = result.filter { $0 == "{" }.count
    let closes = result.filter { $0 == "}" }.count
    #expect(opens == closes)
  }

  @Test("Fix trailing junk + extra braces")
  func combinedTrailingAndBraces() {
    let code = """
      struct Foo {
          var x: Int
      }
      }
      That's the implementation.
      """
    let (result, fixes) = repair.repair(code)
    #expect(!result.contains("That's the"))
    let opens = result.filter { $0 == "{" }.count
    let closes = result.filter { $0 == "}" }.count
    #expect(opens == closes)
  }

  // MARK: - Individual Pass Tests

  @Test("stripLeadingProse with @Observable attribute")
  func stripProseBeforeAttribute() {
    let code = """
      This is the ViewModel:

      @Observable
      class PodcastViewModel {
          var items: [String] = []
      }
      """
    let result = repair.stripLeadingProse(code)
    #expect(!result.contains("This is the"))
    #expect(result.contains("@Observable"))
  }

  @Test("balanceBraces ignores braces in strings")
  func bracesInStrings() {
    let code = """
      let json = "{\\"key\\": \\"value\\"}"
      let x = 1
      """
    let result = repair.balanceBraces(code)
    // Should not be modified — braces are inside a string
    #expect(result == code)
  }

  @Test("Deeply missing braces (>3) left unchanged")
  func tooManyMissing() {
    let code = """
      struct A {
          struct B {
              struct C {
                  func d() {
                      print("deep")
      """
    let result = repair.balanceBraces(code)
    // 4 missing braces — too many, should return original
    #expect(result == code)
  }

  @Test("Empty input returns empty")
  func emptyInput() {
    let (result, fixes) = repair.repair("")
    #expect(result.isEmpty)
    #expect(fixes.isEmpty)
  }

  // MARK: - Pass 5: Pull orphaned enum methods inside

  @Test("Free function using EnumName.hallucinated is moved inside enum")
  func pullOrphanMethodWithHallucinatedStatic() {
    // The exact AFM failure mode observed in Phase E create-traffic-enum:
    // method emitted outside the enum, referencing a non-existent `TrafficLight.current`.
    let code = """
      import Foundation

      enum TrafficLight: String {
          case red = "Red"
          case yellow = "Yellow"
          case green = "Green"
      }

      func next() -> TrafficLight {
          switch TrafficLight.current {
          case .red:
              return .green
          case .green:
              return .yellow
          case .yellow:
              return .red
          }
      }
      """
    let (fixed, moved) = repair.pullEnumExternalMethods(code)
    #expect(moved == 1)
    // Free function is gone from top level
    #expect(!fixed.contains("\nfunc next()"))
    // Its body is now inside the enum, with TrafficLight.current rewritten to self
    #expect(fixed.contains("switch self"))
    #expect(!fixed.contains("TrafficLight.current"))
    // Enum body still has its cases
    #expect(fixed.contains("case red = \"Red\""))
  }

  @Test("Free function with unrelated EnumName case references is unchanged")
  func noMoveWhenOnlyCaseRefs() {
    let code = """
      enum TrafficLight { case red, yellow, green }

      func defaultLight() -> TrafficLight {
          return TrafficLight.red
      }
      """
    let (fixed, moved) = repair.pullEnumExternalMethods(code)
    #expect(moved == 0)
    #expect(fixed == code)
  }

  @Test("Free function taking enum as parameter is not moved")
  func noMoveWhenHasParameter() {
    let code = """
      enum Direction { case north, south }

      func describe(_ d: Direction) -> String {
          switch Direction.north {
          case .north: return "N"
          case .south: return "S"
          }
      }
      """
    let (_, moved) = repair.pullEnumExternalMethods(code)
    // Has a parameter — skip, as a safety bound.
    #expect(moved == 0)
  }

  @Test("Clean enum method already inside is not disturbed")
  func noMoveWhenMethodAlreadyInside() {
    let code = """
      enum TrafficLight {
          case red, yellow, green
          func next() -> TrafficLight {
              switch self {
              case .red: return .green
              case .yellow: return .red
              case .green: return .yellow
              }
          }
      }
      """
    let (fixed, moved) = repair.pullEnumExternalMethods(code)
    #expect(moved == 0)
    #expect(fixed == code)
  }

  @Test("repair() integrates Pass 5 with other passes")
  func fullRepairIncludesEnumPull() {
    let code = """
      ```swift
      enum TrafficLight {
          case red, yellow, green
      }

      func next() -> TrafficLight {
          switch TrafficLight.now {
          case .red: return .green
          case .yellow: return .red
          case .green: return .yellow
          }
      }
      ```
      """
    let (fixed, fixes) = repair.repair(code)
    #expect(fixes.contains(where: { $0.contains("enum method") }))
    #expect(!fixed.contains("TrafficLight.now"))
    #expect(fixed.contains("switch self"))
  }
}
