// FileWatcherTests.swift

import Testing
import Foundation
@testable import JuncoKit

@Suite("FileWatcher")
struct FileWatcherTests {
  @Test("ReindexFlag set and consume works")
  func reindexFlag() {
    let flag = ReindexFlag()
    #expect(flag.consume() == false)
    flag.set()
    #expect(flag.consume() == true)
    #expect(flag.consume() == false)  // Consumed, resets to false
  }

  @Test("ReindexFlag is thread-safe")
  func reindexFlagConcurrent() async {
    let flag = ReindexFlag()
    // Set from multiple tasks concurrently
    await withTaskGroup(of: Void.self) { group in
      for _ in 0..<100 {
        group.addTask { flag.set() }
      }
    }
    // Should have been set at least once
    #expect(flag.consume() == true)
  }

  @Test("FileWatcher initializes without crashing")
  func init_ok() {
    let watcher = FileWatcher(directory: NSTemporaryDirectory())
    // Just verify it doesn't crash on init
    _ = watcher
  }
}
