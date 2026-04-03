// ProjectResolver.swift — Detect and resolve to the project root directory
//
// Walks up from the current directory looking for Swift project markers
// (Package.swift, *.xcodeproj, *.xcworkspace). If found in a parent,
// returns the parent as the resolved project root.
//
// Prevents Junco from running in a subdirectory (e.g., Training/lora/)
// where grep would find wrong-project files.

import Foundation

/// Resolves the working directory to the nearest Swift project root.
public struct ProjectResolver: Sendable {

  /// Files/patterns that indicate a Swift project root.
  private static let markerFiles = ["Package.swift"]
  private static let markerExtensions = [".xcodeproj", ".xcworkspace"]

  /// Maximum number of parent directories to walk up.
  private static let maxDepth = 8

  /// Result of project resolution.
  public struct Resolution: Sendable {
    /// The resolved project root path.
    public let path: String
    /// Whether the root was auto-detected in a parent directory.
    public let wasAutoDetected: Bool
    /// Whether the resolved path has project markers.
    public let hasProjectMarkers: Bool
  }

  /// Resolve the project root from a starting directory.
  /// Walks up parent directories looking for Swift project markers.
  public static func resolve(from startDir: String) -> Resolution {
    let fm = FileManager.default

    // Check the starting directory first (common case)
    if isProjectRoot(startDir) {
      return Resolution(path: startDir, wasAutoDetected: false, hasProjectMarkers: true)
    }

    // Walk up parent directories
    var current = (startDir as NSString).standardizingPath
    for _ in 0..<maxDepth {
      let parent = (current as NSString).deletingLastPathComponent
      guard parent != current else { break }  // Hit filesystem root
      current = parent

      if isProjectRoot(current) {
        return Resolution(path: current, wasAutoDetected: true, hasProjectMarkers: true)
      }
    }

    // No project found — use original directory with a warning flag
    return Resolution(path: startDir, wasAutoDetected: false, hasProjectMarkers: false)
  }

  /// Check if a directory looks like a Swift project root.
  public static func isProjectRoot(_ dir: String) -> Bool {
    let fm = FileManager.default

    // Check for Package.swift
    for marker in markerFiles {
      if fm.fileExists(atPath: (dir as NSString).appendingPathComponent(marker)) {
        return true
      }
    }

    // Check for Xcode project/workspace
    if let contents = try? fm.contentsOfDirectory(atPath: dir) {
      for item in contents {
        for ext in markerExtensions {
          if item.hasSuffix(ext) { return true }
        }
      }
    }

    return false
  }
}
