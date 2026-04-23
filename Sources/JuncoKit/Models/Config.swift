// Config.swift — Consolidated static configuration
//
// All tunable thresholds and limits in one place.
// Each knob reads through MetaConfig.shared to support runtime overrides via
// $META_CONFIG_JSON. Default values preserved when the overlay is absent.

import Foundation

/// Centralized configuration for the junco agent.
public enum Config {

  // MARK: - Token Budgets

  /// Approximate characters per token (conservative for code with short tokens).
  /// Used only when `adapter.contextSize` / `adapter.countTokens` is unavailable.
  public static var charsPerToken: Int { MetaConfig.shared.charsPerToken ?? 3 }

  // MARK: - Session

  /// Character threshold above which input is treated as a paste.
  public static let pasteThreshold = 500

  /// Maximum number of turns to keep in multi-turn context.
  public static var maxTurnHistory: Int { MetaConfig.shared.maxTurnHistory ?? 5 }

  /// Maximum number of observations kept in working memory.
  public static var maxObservations: Int { MetaConfig.shared.maxObservations ?? 5 }

  /// Maximum number of errors kept in working memory.
  public static var maxErrors: Int { MetaConfig.shared.maxErrors ?? 5 }

  // MARK: - Tools

  /// Default bash command timeout in seconds.
  public static var bashTimeout: TimeInterval { MetaConfig.shared.bashTimeout ?? 30 }

  /// Maximum retries when code validation (Swift) fails.
  public static var maxValidationRetries: Int { MetaConfig.shared.maxValidationRetries ?? 2 }

  /// Maximum CVF (compile-verify-fix) cycles for view files (SwiftUI bodies are harder).
  public static var maxCVFCyclesView: Int { MetaConfig.shared.maxCVFCyclesView ?? 3 }

  /// Number of candidates to generate for multi-sample compile-select.
  public static var candidateCount: Int { MetaConfig.shared.candidateCount ?? 3 }

  /// Temperature for candidate generation (higher = more diverse candidates).
  public static var candidateTemperature: Double { MetaConfig.shared.candidateTemperature ?? 0.8 }

  /// Whether two-phase generation (skeleton → fill) is used for complex Swift files.
  public static var twoPhaseDefault: Bool { MetaConfig.shared.twoPhaseDefault ?? true }

  /// Whether to sandbox bash commands via sandbox-exec.
  public static var sandboxEnabled: Bool { MetaConfig.shared.sandboxEnabled ?? true }

  /// Maximum tokens for tool output before truncation.
  public static var toolOutputMaxTokens: Int { MetaConfig.shared.toolOutputMaxTokens ?? 400 }

  /// Maximum tokens for file reads in execute stage.
  public static var fileReadMaxTokens: Int { MetaConfig.shared.fileReadMaxTokens ?? 800 }

  /// Maximum tokens for file reads in plan context.
  public static var planFileReadMaxTokens: Int { MetaConfig.shared.planFileReadMaxTokens ?? 200 }

  // MARK: - RAG

  /// Maximum files to index per project.
  public static var maxIndexFiles: Int { MetaConfig.shared.maxIndexFiles ?? 500 }

  /// Maximum directory depth for file scanning.
  public static var maxScanDepth: Int { MetaConfig.shared.maxScanDepth ?? 6 }

  /// Maximum files in quick listing.
  public static var maxListFiles: Int { MetaConfig.shared.maxListFiles ?? 200 }

  // MARK: - Reflections

  /// Maximum reflections before auto-compaction (JSONL store).
  public static var maxReflections: Int { MetaConfig.shared.maxReflections ?? 100 }

  /// Minimum confidence for ML classifier before falling back to LLM.
  public static var mlClassifierConfidence: Double { MetaConfig.shared.mlClassifierConfidence ?? 0.7 }

  // MARK: - Skills

  /// Maximum token budget for skill hints injected into prompts.
  public static var skillHintBudget: Int { MetaConfig.shared.skillHintBudget ?? 200 }

  /// Safety margin as percentage of context window.
  public static var tokenSafetyMarginPercent: Int { MetaConfig.shared.tokenSafetyMarginPercent ?? 5 }

  // MARK: - Language Detection

  /// Minimum confidence from NLLanguageRecognizer to treat detection as valid.
  public static var languageDetectionConfidence: Double {
    MetaConfig.shared.languageDetectionConfidence ?? 0.85
  }

  // MARK: - Swift Toolchain

  /// Default swift-tools-version when detection fails.
  public static let defaultSwiftToolsVersion = "6.0"

  // MARK: - Persistence Paths

  /// Per-project junco directory name.
  public static let projectDirName = ".junco"

  /// Global junco directory (for SQLite, models).
  public static var globalDir: String {
    (NSHomeDirectory() as NSString).appendingPathComponent(".junco")
  }

  /// Sensitive file names that should never be written.
  public static let sensitiveFilePatterns = [".env", "credentials.json", ".p12", ".pem", ".key"]

  /// Dangerous shell patterns that are blocked.
  public static let blockedShellPatterns = [
    "rm -rf /", "rm -rf ~", "rm -rf $HOME",
    "sudo ", "shutdown", "reboot", "halt",
    "> /dev/sd", "> /dev/disk", "mkfs",
    "dd if=", ":(){", "fork bomb",
    "passwd", "visudo", "crontab -e"
  ]

  // MARK: - File Extensions by Domain

  public static let swiftExtensions = ["swift"]
  public static let generalExtensions = [
    "swift", "c", "cpp", "h", "json", "yaml", "md", "plist"
  ]
}
