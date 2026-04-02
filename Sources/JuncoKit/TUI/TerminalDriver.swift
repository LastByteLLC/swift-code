// TerminalDriver.swift — Low-level terminal I/O with buffered rendering
//
// Foundation for all interactive TUI components. Handles:
// - Raw mode (no line buffering, no echo)
// - Keystroke reading (including multi-byte escape sequences and UTF-8)
// - Buffered output (collect all writes, flush once to prevent tearing)
// - Cursor positioning and screen geometry
// - ANSI escape code generation
//
// All interactive TUI components should use TerminalDriver, never raw print().

import Foundation

// MARK: - Keyboard Input

/// A parsed keyboard event.
public enum Key: Equatable, Sendable {
  case char(Character)
  case enter, shiftEnter, tab, shiftTab, backspace, delete, escape
  case up, down, left, right
  case home, end
  case ctrlC, ctrlD, ctrlU, ctrlW, ctrlL
  case eof
  case unknown(UInt8)
}

// MARK: - Terminal IO Protocol

/// Abstraction for terminal I/O, allowing real and virtual implementations.
/// Used by LineEditor and other TUI components.
public protocol TerminalIO: AnyObject {
  func readKey() -> Key
  func write(_ text: String)
  func flush()
  func beginRedraw()
  func clearToEndOfScreen()
  func clearLine()
  func moveTo(column: Int)
  func moveUp(_ n: Int)
  func moveDown(_ n: Int)
  func newline()
  var screenWidth: Int { get }
  var screenHeight: Int { get }
}

// MARK: - Terminal Driver

/// Low-level terminal driver for interactive TUI rendering.
/// Manages raw mode, input, and buffered output.
public final class TerminalDriver: @unchecked Sendable, TerminalIO {
  private var originalTermios = termios()
  private var isRaw = false
  private var outputBuffer = Data()

  /// Whether stdin is connected to a real terminal.
  public static var isInteractive: Bool { isatty(STDIN_FILENO) != 0 }

  public init?() {
    guard Self.isInteractive else { return nil }
  }

  deinit {
    if isRaw { restoreMode() }
  }

  // MARK: - Terminal Mode

  /// Enter raw mode: disable line buffering and echo.
  public func enableRawMode() {
    guard !isRaw else { return }
    tcgetattr(STDIN_FILENO, &originalTermios)
    var raw = originalTermios
    raw.c_lflag &= ~UInt(ICANON | ECHO | ISIG)
    raw.c_iflag &= ~UInt(IXON | ICRNL)
    withUnsafeMutablePointer(to: &raw.c_cc) { ptr in
      let cc = UnsafeMutableRawPointer(ptr).assumingMemoryBound(to: UInt8.self)
      cc[Int(VMIN)] = 1
      cc[Int(VTIME)] = 0
    }
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &raw)
    isRaw = true
  }

  /// Restore original terminal mode.
  public func restoreMode() {
    guard isRaw else { return }
    tcsetattr(STDIN_FILENO, TCSAFLUSH, &originalTermios)
    isRaw = false
  }

  // MARK: - Input

  /// Read a single byte from stdin.
  public func readByte() -> UInt8? {
    var byte: UInt8 = 0
    return read(STDIN_FILENO, &byte, 1) == 1 ? byte : nil
  }

  /// Read and parse a complete keystroke.
  public func readKey() -> Key {
    guard let byte = readByte() else { return .eof }

    switch byte {
    case 0x1B:
      guard let next = readByte() else { return .escape }

      // Alt+Enter → shiftEnter (most reliable multi-line trigger)
      if next == 0x0D || next == 0x0A { return .shiftEnter }

      if next == 0x5B {
        guard let code = readByte() else { return .escape }
        switch code {
        case 0x41: return .up
        case 0x42: return .down
        case 0x43: return .right
        case 0x44: return .left
        case 0x48: return .home
        case 0x46: return .end
        case 0x5A: return .shiftTab  // ESC [ Z = Shift+Tab
        case 0x33:
          _ = readByte() // consume ~
          return .delete
        case 0x31:
          // Kitty keyboard protocol: \x1b[13;2u = Shift+Enter
          // Read remaining bytes: 3;2u or other sequences
          var seqBuf: [UInt8] = [code]
          while let b = readByte() {
            seqBuf.append(b)
            if b == 0x75 || b == 0x7E || b.isASCIILetter { break } // u, ~, or letter terminates
          }
          let seq = String(bytes: seqBuf, encoding: .ascii) ?? ""
          if seq.contains("3;2u") { return .shiftEnter }  // \x1b[13;2u
          return .escape
        default: return .escape
        }
      }
      return .escape
    case 0x09: return .tab
    case 0x0A, 0x0D: return .enter
    case 0x7F, 0x08: return .backspace
    case 0x03: return .ctrlC
    case 0x04: return .ctrlD
    case 0x0C: return .ctrlL
    case 0x15: return .ctrlU
    case 0x17: return .ctrlW
    default:
      if byte >= 0x20 && byte < 0x7F {
        return .char(Character(UnicodeScalar(byte)))
      }
      if byte >= 0xC0 {
        return readUTF8(firstByte: byte)
      }
      return .unknown(byte)
    }
  }

  private func readUTF8(firstByte: UInt8) -> Key {
    var bytes = [firstByte]
    let expected: Int
    if firstByte & 0xE0 == 0xC0 { expected = 2 }
    else if firstByte & 0xF0 == 0xE0 { expected = 3 }
    else if firstByte & 0xF8 == 0xF0 { expected = 4 }
    else { return .unknown(firstByte) }

    for _ in 1..<expected {
      guard let b = readByte() else { break }
      bytes.append(b)
    }
    if let s = String(bytes: bytes, encoding: .utf8), let ch = s.first {
      return .char(ch)
    }
    return .unknown(firstByte)
  }

  // MARK: - Buffered Output

  /// Append text to the output buffer (not yet visible).
  public func write(_ text: String) {
    if let data = text.data(using: .utf8) {
      outputBuffer.append(data)
    }
  }

  /// Flush the output buffer to the terminal in a single write.
  public func flush() {
    guard !outputBuffer.isEmpty else { return }
    outputBuffer.withUnsafeBytes { ptr in
      _ = Foundation.write(STDOUT_FILENO, ptr.baseAddress!, ptr.count)
    }
    outputBuffer.removeAll(keepingCapacity: true)
  }

  // MARK: - Cursor & Screen Control

  /// Move cursor to column `col` (1-based) on the current line.
  public func moveTo(column col: Int) {
    write("\u{1B}[\(col)G")
  }

  /// Move cursor up `n` lines.
  public func moveUp(_ n: Int = 1) {
    if n > 0 { write("\u{1B}[\(n)A") }
  }

  /// Move cursor down `n` lines.
  public func moveDown(_ n: Int = 1) {
    if n > 0 { write("\u{1B}[\(n)B") }
  }

  /// Clear from cursor position to end of screen.
  public func clearToEndOfScreen() {
    write("\u{1B}[J")
  }

  /// Clear the entire current line.
  public func clearLine() {
    write("\u{1B}[2K")
  }

  /// Move to column 1 and clear to end of screen.
  /// This is the "full redraw" primitive — call this before rendering.
  public func beginRedraw() {
    write("\r")
    clearToEndOfScreen()
  }

  /// Write a newline (moves to next line).
  public func newline() {
    write("\n")
  }

  /// Get the terminal width in columns.
  public var screenWidth: Int {
    var w = winsize()
    if ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0, w.ws_col > 0 {
      return Int(w.ws_col)
    }
    return 80
  }

  /// Get the terminal height in rows.
  public var screenHeight: Int {
    var w = winsize()
    if ioctl(STDOUT_FILENO, TIOCGWINSZ, &w) == 0, w.ws_row > 0 {
      return Int(w.ws_row)
    }
    return 24
  }

  // MARK: - Styled Text Helpers

  /// Calculate the visible width of a string (strips ANSI escape codes).
  public static func visibleWidth(_ s: String) -> Int {
    s.replacingOccurrences(
      of: "\u{1B}\\[[0-9;]*[a-zA-Z]", with: "", options: .regularExpression
    ).count
  }

  /// Apply inverted (highlighted) style to text.
  public static func highlight(_ s: String) -> String {
    "\u{1B}[7m\(s)\u{1B}[0m"
  }

  /// Apply dim style to text.
  public static func dim(_ s: String) -> String {
    "\u{1B}[2m\(s)\u{1B}[0m"
  }
}

private extension UInt8 {
  var isASCIILetter: Bool {
    (0x41...0x5A).contains(self) || (0x61...0x7A).contains(self)
  }
}
