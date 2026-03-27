// SwiftValidatorTests.swift — Verify Swift syntax validation

import Testing
@testable import JuncoKit

@Suite("SwiftValidator")
struct SwiftValidatorTests {
  let validator = SwiftValidator()

  @Test("valid Swift passes validation")
  func validSwift() {
    let code = """
      struct Hello: Identifiable {
          let id: Int
          let name: String
      }
      """
    let result = validator.feedbackForLLM(code: code, filePath: "Hello.swift")
    #expect(result == nil, "Valid Swift should pass: \(result ?? "")")
  }

  @Test("syntax error is caught")
  func syntaxError() {
    let code = """
      struct Broken {
          let x: Int
      // missing closing brace
      """
    let result = validator.feedbackForLLM(code: code, filePath: "Broken.swift")
    #expect(result != nil, "Syntax error should be caught")
    #expect(result?.contains("error") == true)
  }

  @Test("non-Swift files are ignored")
  func nonSwiftIgnored() {
    let result = validator.feedbackForLLM(code: "not swift", filePath: "file.js")
    #expect(result == nil, "Non-Swift files should be skipped")
  }

  @Test("empty content is caught")
  func emptyContent() {
    let result = validator.feedbackForLLM(code: "   ", filePath: "Empty.swift")
    #expect(result != nil, "Empty content should be caught")
  }

  @Test("valid SwiftUI code passes")
  func validSwiftUI() {
    let code = """
      import SwiftUI

      struct ContentView: View {
          var body: some View {
              Text("Hello")
          }
      }
      """
    let result = validator.feedbackForLLM(code: code, filePath: "ContentView.swift")
    #expect(result == nil, "Valid SwiftUI should pass: \(result ?? "")")
  }

  @Test("extra braces caught")
  func extraBraces() {
    let code = """
      struct Foo {
          let x: Int
      }
      }
      """
    let result = validator.feedbackForLLM(code: code, filePath: "Foo.swift")
    #expect(result != nil, "Extra closing brace should be caught")
  }
}
