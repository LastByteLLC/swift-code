// AFMInstructionsTests.swift — Verify @InstructionsBuilder helpers produce usable Instructions

import Foundation
import FoundationModels
import Testing
@testable import JuncoKit

@Suite("AFMInstructions")
struct AFMInstructionsTests {

  @Test("fromString preserves a non-empty system prompt")
  func fromStringPreserves() {
    let inst = AFMInstructions.fromString("Be terse and concrete.")
    let rendered = String(describing: inst)
    #expect(rendered.contains("terse"))
  }

  @Test("fromString tolerates nil and empty strings")
  func fromStringEmpty() {
    _ = AFMInstructions.fromString(nil)
    _ = AFMInstructions.fromString("")
    // Intent: building Instructions from nil/empty must not trap.
  }

  @Test("onDevice prepends the junco prelude")
  func onDevicePrelude() {
    let inst = AFMInstructions.onDevice("Prefer Swift 6 concurrency.")
    let rendered = String(describing: inst)
    #expect(rendered.contains("junco"))
    #expect(rendered.contains("Swift 6 concurrency"))
  }
}
