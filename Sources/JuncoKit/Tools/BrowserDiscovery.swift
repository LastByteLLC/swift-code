// BrowserDiscovery.swift — Detect installed browsers and WebDriver support
//
// Scans /Applications for browsers, checks for matching WebDriver binaries,
// and reports what's available for E2E testing. Results are cached per session
// and injected into MicroSkill prompts so the agent knows what's on the system.

import Foundation

/// A detected browser with WebDriver capability info.
public struct DetectedBrowser: Sendable {
  public let name: String          // "Safari", "Google Chrome", "Firefox"
  public let path: String          // App bundle path
  public let version: String       // e.g., "146.0.7680.165"
  public let driverPath: String?   // Path to WebDriver binary (nil = not found)
  public let driverSource: String? // How to get the driver: "builtin", "npx", "brew", "download"
  public let headless: Bool        // Whether headless mode is supported
  public let setupNeeded: String?  // One-time setup instructions (nil = ready to use)

  /// Whether this browser is ready for WebDriver testing right now.
  public var isReady: Bool { driverPath != nil && setupNeeded == nil }
}

/// Discovers installed browsers and their WebDriver support.
public struct BrowserDiscovery: Sendable {
  public init() {}

  /// Scan the system and return all detected browsers with WebDriver info.
  public func discover() async -> [DetectedBrowser] {
    var browsers: [DetectedBrowser] = []

    // Safari
    if let safari = await detectSafari() {
      browsers.append(safari)
    }

    // Chrome
    if let chrome = await detectChrome() {
      browsers.append(chrome)
    }

    // Firefox
    if let firefox = await detectFirefox() {
      browsers.append(firefox)
    }

    return browsers
  }

  /// Format discovery results for prompt injection.
  public func formatForPrompt(_ browsers: [DetectedBrowser]) -> String {
    guard !browsers.isEmpty else {
      return "No browsers with WebDriver support detected."
    }

    var lines = ["Available browsers for E2E testing:"]
    for b in browsers {
      let status = b.isReady ? "ready" : "setup needed"
      lines.append("  \(b.name) \(b.version) [\(status)]\(b.headless ? " (headless)" : "")")
      if let setup = b.setupNeeded {
        lines.append("    Setup: \(setup)")
      }
      if let source = b.driverSource, source != "builtin" {
        lines.append("    Driver: \(source)")
      }
    }
    return lines.joined(separator: "\n")
  }

  /// Get the best browser for headless E2E testing.
  public func bestHeadlessBrowser(_ browsers: [DetectedBrowser]) -> DetectedBrowser? {
    // Prefer Chrome headless (most common, fewest issues)
    if let chrome = browsers.first(where: { $0.name == "Google Chrome" && $0.isReady }) {
      return chrome
    }
    // Fallback to Firefox
    if let firefox = browsers.first(where: { $0.name == "Firefox" && $0.isReady }) {
      return firefox
    }
    // Safari (no headless, but works)
    return browsers.first(where: { $0.name == "Safari" && $0.isReady })
  }

  // MARK: - Safari

  private func detectSafari() async -> DetectedBrowser? {
    let path = "/Applications/Safari.app"
    guard FileManager.default.fileExists(atPath: path) else { return nil }

    let version = await shellOutput("safaridriver --version 2>/dev/null") ?? "unknown"
    let versionClean = version.replacingOccurrences(of: "Included with Safari ", with: "")
      .components(separatedBy: " ").first ?? version

    // Check if remote automation is enabled
    let testResult = await shellOutput(
      "safaridriver -p 0 --diagnose 2>&1 | head -1"
    )
    let needsSetup = testResult?.contains("must enable") == true

    return DetectedBrowser(
      name: "Safari",
      path: path,
      version: versionClean,
      driverPath: "/usr/bin/safaridriver",
      driverSource: "builtin",
      headless: false,
      setupNeeded: needsSetup
        ? "Run: sudo safaridriver --enable && enable 'Allow Remote Automation' in Safari > Settings > Developer"
        : nil
    )
  }

  // MARK: - Chrome

  private func detectChrome() async -> DetectedBrowser? {
    let path = "/Applications/Google Chrome.app"
    guard FileManager.default.fileExists(atPath: path) else { return nil }

    let version = await shellOutput(
      "\"\(path)/Contents/MacOS/Google Chrome\" --version 2>/dev/null"
    )
    let versionClean = version?.replacingOccurrences(of: "Google Chrome ", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"

    // Check for chromedriver
    let localDriver = await shellOutput("which chromedriver 2>/dev/null")
    let npxAvailable = await shellOutput("npx --yes chromedriver --version 2>/dev/null") != nil

    let driverPath = localDriver?.trimmingCharacters(in: .whitespacesAndNewlines)

    return DetectedBrowser(
      name: "Google Chrome",
      path: path,
      version: versionClean,
      driverPath: driverPath.flatMap { $0.isEmpty ? nil : $0 },
      driverSource: driverPath != nil ? "local" : (npxAvailable ? "npx chromedriver" : "download from https://googlechromelabs.github.io/chrome-for-testing/"),
      headless: true,
      setupNeeded: nil  // Chrome needs no special setup
    )
  }

  // MARK: - Firefox

  private func detectFirefox() async -> DetectedBrowser? {
    let paths = ["/Applications/Firefox.app", "/Applications/Firefox Developer Edition.app"]
    guard let path = paths.first(where: { FileManager.default.fileExists(atPath: $0) }) else {
      return nil
    }

    let name = (path as NSString).lastPathComponent.replacingOccurrences(of: ".app", with: "")

    // Firefox version
    let version = await shellOutput(
      "\"\(path)/Contents/MacOS/firefox\" --version 2>/dev/null"
    )
    let versionClean = version?.replacingOccurrences(of: "Mozilla Firefox ", with: "")
      .trimmingCharacters(in: .whitespacesAndNewlines) ?? "unknown"

    let localDriver = await shellOutput("which geckodriver 2>/dev/null")
    let npxAvailable = await shellOutput("npx --yes geckodriver --version 2>/dev/null") != nil

    let driverPath = localDriver?.trimmingCharacters(in: .whitespacesAndNewlines)

    return DetectedBrowser(
      name: name,
      path: path,
      version: versionClean,
      driverPath: driverPath.flatMap { $0.isEmpty ? nil : $0 },
      driverSource: driverPath != nil ? "local" : (npxAvailable ? "npx geckodriver" : "brew install geckodriver"),
      headless: true,
      setupNeeded: nil
    )
  }

  // MARK: - Shell Helper

  private func shellOutput(_ command: String) async -> String? {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/bash")
    process.arguments = ["-c", command]
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = FileHandle.nullDevice

    do {
      try process.run()
      process.waitUntilExit()
      let data = pipe.fileHandleForReading.readDataToEndOfFile()
      let output = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
      return output?.isEmpty == true ? nil : output
    } catch {
      return nil
    }
  }
}
