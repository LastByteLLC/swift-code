// WelcomeMessage.swift — Terminal-responsive welcome display
//
// Adapts to terminal width: full art for wide, compact for narrow.
// Shows project context: domain, git info, file count, reflections.

import Foundation

/// Generates a welcome message sized to the terminal.
public struct WelcomeMessage: Sendable {
  public let domain: DomainConfig
  public let gitBranch: String?
  public let fileCount: Int
  public let reflectionCount: Int
  public let workingDirectory: String
  public let version: String
  public let modelInfo: String

  public init(
    domain: DomainConfig, gitBranch: String? = nil,
    fileCount: Int = 0, reflectionCount: Int = 0,
    workingDirectory: String, version: String = "0.3.0",
    modelInfo: String = "Apple Foundation Models (Neural Engine)"
  ) {
    self.domain = domain
    self.gitBranch = gitBranch
    self.fileCount = fileCount
    self.reflectionCount = reflectionCount
    self.workingDirectory = workingDirectory
    self.version = version
    self.modelInfo = modelInfo
  }

  /// Render the welcome message for the given terminal width.
  public func render(width: Int = 80) -> String {
    if width >= 80 {
      return renderFull(width: width)
    } else {
      return renderCompact()
    }
  }

  private func renderFull(width: Int) -> String {
    let bar = String(repeating: "\u{2500}", count: min(width, 60))
    let dir = abbreviatePath(workingDirectory)

    let lines = [
      Style.dim(bar),
      Style.bold("  junco v\(version)") + Style.dim(" \u{2014} on-device AI coding agent"),
      "",
      "  Domain: \(Style.cyan(domain.displayName))" + (gitBranch.map { "  \u{2502}  Git: \(Style.green($0))" } ?? ""),
      "  Dir: \(Style.dim(dir))",
      "  Files: \(fileCount)" + (reflectionCount > 0 ? "  \u{2502}  Reflections: \(reflectionCount)" : ""),
      "  Model: \(Style.dim(modelInfo))",
      "",
      Style.dim("  /help for commands  \u{2502}  @file to target  \u{2502}  exit to quit"),
      Style.dim(bar),
    ]
    return lines.joined(separator: "\n")
  }

  private func renderCompact() -> String {
    let dir = abbreviatePath(workingDirectory)
    return [
      Style.bold("junco v\(version)") + " \(Style.cyan(domain.displayName))",
      Style.dim("\(dir) | \(fileCount)f" + (gitBranch.map { " | \($0)" } ?? "")),
      Style.dim("/help | @file | exit"),
    ].joined(separator: "\n")
  }

  private func abbreviatePath(_ path: String) -> String {
    let home = NSHomeDirectory()
    if path.hasPrefix(home) {
      return "~" + path.dropFirst(home.count)
    }
    return path
  }
}
