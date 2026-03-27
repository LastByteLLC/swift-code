// ResizeHandler.swift — Signal handlers for resize, interrupt, and termination
//
// SIGWINCH: sets a flag for TUI components to detect terminal resize.
// SIGINT/SIGTERM: restores alternate screen buffer before exiting.
// Signal handlers must be minimal — no allocations, no locks, no async.

import Foundation

/// Thread-safe flag set by signal handlers.
public final class ResizeFlag: @unchecked Sendable {
  private var _value: Int32 = 0

  public init() {}

  /// Signal-safe set (no locks, no allocations).
  public func set() {
    OSAtomicIncrement32(&_value)
  }

  /// Check and consume. Returns true if the flag was set.
  public func consume() -> Bool {
    let v = _value
    if v > 0 {
      OSAtomicCompareAndSwap32(v, 0, &_value)
      return true
    }
    return false
  }
}

/// Global resize flag polled by TUI components.
public let terminalResizeFlag = ResizeFlag()

/// Install all signal handlers. Call once at startup.
public func installSignalHandlers() {
  // SIGWINCH: terminal resized
  signal(SIGWINCH) { _ in
    terminalResizeFlag.set()
  }

  // SIGINT (Ctrl-C): restore screen and exit cleanly
  signal(SIGINT) { _ in
    // Restore alternate screen buffer (signal-safe: just write bytes)
    let restore = "\u{1B}[?1049l\n"
    restore.withCString { ptr in
      _ = write(STDOUT_FILENO, ptr, strlen(ptr))
    }
    _exit(130)  // Standard Ctrl-C exit code
  }

  // SIGTERM: same cleanup
  signal(SIGTERM) { _ in
    let restore = "\u{1B}[?1049l\n"
    restore.withCString { ptr in
      _ = write(STDOUT_FILENO, ptr, strlen(ptr))
    }
    _exit(143)
  }
}
