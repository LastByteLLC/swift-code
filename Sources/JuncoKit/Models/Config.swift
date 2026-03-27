// Config.swift — Consolidated static configuration
//
// All tunable thresholds and limits in one place.
// No magic numbers scattered across the codebase.

import Foundation

/// Centralized configuration for the junco agent.
public enum Config {

  // MARK: - Token Budgets

  /// AFM context window size in tokens.
  public static let contextWindow = 4096

  /// Approximate characters per token (conservative for mixed code/English).
  public static let charsPerToken = 4

  // MARK: - Session

  /// Character threshold above which input is treated as a paste.
  public static let pasteThreshold = 500

  /// Maximum number of turns to keep in multi-turn context.
  public static let maxTurnHistory = 5

  /// Maximum number of observations kept in working memory.
  public static let maxObservations = 5

  /// Maximum number of errors kept in working memory.
  public static let maxErrors = 5

  // MARK: - Tools

  /// Default bash command timeout in seconds.
  public static let bashTimeout: TimeInterval = 30

  /// Maximum retries when code validation (JSC/Swift) fails.
  public static let maxValidationRetries = 2

  /// Whether to sandbox bash commands via sandbox-exec.
  public static let sandboxEnabled = true

  /// Maximum tokens for tool output before truncation.
  public static let toolOutputMaxTokens = 400

  /// Maximum tokens for file reads in execute stage.
  public static let fileReadMaxTokens = 800

  /// Maximum tokens for file reads in plan context.
  public static let planFileReadMaxTokens = 200

  // MARK: - RAG

  /// Maximum files to index per project.
  public static let maxIndexFiles = 100

  /// Maximum directory depth for file scanning.
  public static let maxScanDepth = 4

  /// Maximum files in quick listing.
  public static let maxListFiles = 50

  // MARK: - Reflections

  /// Maximum reflections before auto-compaction (JSONL store).
  public static let maxReflections = 100

  /// Minimum confidence for ML classifier before falling back to LLM.
  public static let mlClassifierConfidence = 0.7

  // MARK: - Skills

  /// Maximum token budget for skill hints injected into prompts.
  public static let skillHintBudget = 200

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
    "passwd", "visudo", "crontab -e",
  ]

  // MARK: - File Extensions by Domain

  public static let swiftExtensions = ["swift"]
  public static let jsExtensions = ["js", "ts", "jsx", "tsx", "css", "html"]
  public static let generalExtensions = [
    "swift", "js", "ts", "py", "rb", "go", "rs", "c", "cpp", "h",
    "css", "html", "json", "yaml", "md",
  ]
}
