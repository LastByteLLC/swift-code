// Junco.swift — CLI entry point with fully wired TUI
//
// All features connected: welcome message, session persistence,
// thinking phrases, markdown rendering, diff display, command history,
// notifications, web search, scratchpad, permissions.

import AppKit
import ArgumentParser
import Foundation
import FoundationModels
import JuncoKit

/// Thread-safe word counter for streaming progress display.
final class WordCounter: @unchecked Sendable {
  private let lock = NSLock()
  private var words = 0
  private var buffer = ""

  func add(_ chunk: String) {
    lock.withLock {
      buffer += chunk
      words = buffer.split(separator: " ").count
    }
  }

  var count: Int { lock.withLock { words } }
}

@main
struct Junco: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "junco",
    abstract: "An AI coding agent powered by on-device language models.",
    version: JuncoVersion.current,
    subcommands: [Update.self]
  )

  @Option(name: .shortAndLong, help: "Working directory (default: current)")
  var directory: String?

  @Flag(name: .long, help: "Run a single query from stdin, then exit")
  var pipe = false

  @Flag(name: .shortAndLong, help: "Show debug output for every pipeline stage (to stderr)")
  var verbose = false

  @Flag(name: .long, help: "Disable LoRA adapter (use base model only)")
  var noAdapter = false

  @Flag(name: .long, help: "Disable all networking (no adapter download, no web search)")
  var offline = false

  @Option(name: .long, help: "Path to a custom .fmadapter package (skips auto-download)")
  var adapter: String?

  @Option(name: .long, help: "Model backend (default: auto). Examples: afm, ollama:qwen2.5-coder")
  var model: String?

  // Shared services (lazy initialized)
  private var cwd: String { directory ?? FileManager.default.currentDirectoryPath }

  /// Check that Apple Intelligence is available. Prompts user to enable it if not.
  private func checkAppleIntelligence() -> Bool {
    let model = FoundationModels.SystemLanguageModel.default
    guard model.isAvailable else {
      print("Apple Intelligence is not available on this device.")
      print("")
      print("Junco requires Apple Intelligence to be enabled.")
      print("Go to System Settings → Apple Intelligence & Siri to enable it.")
      print("")

      if !pipe {
        print("Open System Settings now? [y/N] ", terminator: "")
        if let answer = readLine(), answer.lowercased().hasPrefix("y") {
          let url = URL(string: "x-apple.systempreferences:com.apple.preference.AppleIntelligence")!
          NSWorkspace.shared.open(url)
        }
      }
      return false
    }
    return true
  }

  /// Load LoRA adapter for AFM backend (extracted from old startup flow).
  private func loadLoRAIfNeeded(afm: AFMAdapter, cwd: String) async {
    guard !noAdapter else { return }

    if let path = adapter {
      // User-provided adapter — load directly, no auto-download
      let url = URL(fileURLWithPath: path)
      guard FileManager.default.fileExists(atPath: url.appendingPathComponent("adapter_weights.bin").path) else {
        FileHandle.standardError.write(Data("Error: No valid .fmadapter found at \(path)\n".utf8))
        return
      }
      await afm.loadAdapter(from: url)
      if verbose {
        FileHandle.standardError.write(Data("[junco] Custom adapter loaded from \(path)\n".utf8))
      }
    } else {
      // Auto-download from manifest
      let downloader = AdapterDownloader()
      let result = await downloader.resolve(
        offline: offline,
        askPermission: pipe ? nil : {
          print("A LoRA adapter is available to improve code generation quality.")
          print("Download it now? (~127 MB, cached for future use) [y/N] ", terminator: "")
          return readLine()?.lowercased().hasPrefix("y") ?? false
        },
        isPipe: pipe
      )

      switch result {
      case .cached(let url):
        await afm.loadAdapter(from: url)
        if verbose {
          FileHandle.standardError.write(Data("[junco] LoRA adapter loaded (cached)\n".utf8))
        }
      case .downloaded(let url):
        print("Adapter downloaded successfully.")
        await afm.loadAdapter(from: url)
        if verbose {
          FileHandle.standardError.write(Data("[junco] LoRA adapter loaded (downloaded)\n".utf8))
        }
      case .noRelease:
        if verbose {
          FileHandle.standardError.write(Data("[junco] No adapter available for this OS version\n".utf8))
        }
      case .declined:
        break
      case .failed(let error):
        FileHandle.standardError.write(Data("[junco] Adapter download failed: \(error)\n".utf8))
      case .offline:
        if verbose {
          FileHandle.standardError.write(Data("[junco] Offline mode — skipping adapter download\n".utf8))
        }
      }

      // Fall back to registered adapter name if download didn't work
      if await !afm.hasAdapter {
        await afm.loadAdapter()
      }
    }

    if await afm.hasAdapter && verbose {
      FileHandle.standardError.write(Data("[junco] LoRA adapter active\n".utf8))
    }
  }

  func run() async throws {
    // Resolve project root
    let cwd: String
    if directory != nil {
      // User explicitly specified --directory: respect it as the project root
      cwd = self.cwd
      if !ProjectResolver.isProjectRoot(cwd) && !pipe {
        FileHandle.standardError.write(Data(
          "\u{1B}[33m⚠ No Swift project detected in \(cwd). Create Package.swift or *.xcodeproj.\u{1B}[0m\n".utf8))
      }
    } else {
      // No --directory: walk up from current directory to find project root
      let resolution = ProjectResolver.resolve(from: self.cwd)
      cwd = resolution.path
      if resolution.wasAutoDetected {
        FileHandle.standardError.write(Data(
          "\u{1B}[2mℹ Detected project root: \(cwd)\u{1B}[0m\n".utf8))
      } else if !resolution.hasProjectMarkers && !pipe {
        FileHandle.standardError.write(Data(
          "\u{1B}[33m⚠ No Swift project detected. Create Package.swift or run from a project directory.\u{1B}[0m\n".utf8))
      }
    }

    // --- Resolve backend ---
    let resolvedAdapter: any LLMAdapter
    let isUsingAFM: Bool

    if let modelSpec = model {
      // Explicit --model flag
      if modelSpec.lowercased() == "afm" {
        if !checkAppleIntelligence() { return }
        let afm = AFMAdapter()
        await loadLoRAIfNeeded(afm: afm, cwd: cwd)
        resolvedAdapter = afm
        isUsingAFM = true
      } else if modelSpec.lowercased().hasPrefix("ollama") {
        // Parse "ollama" or "ollama:modelname"
        let parts = modelSpec.split(separator: ":", maxSplits: 1)
        if parts.count == 2 {
          let modelName = String(parts[1])
          let ctx = await OllamaDetector.contextSize(for: modelName) ?? 4096
          resolvedAdapter = OllamaAdapter(model: modelName, contextSize: ctx)
        } else {
          // No model specified — auto-detect best model
          if let best = await OllamaDetector.autoDetect() {
            let ctx = await OllamaDetector.contextSize(for: best.name) ?? 4096
            resolvedAdapter = OllamaAdapter(model: best.name, contextSize: ctx)
            FileHandle.standardError.write(Data(
              "\u{1B}[2mℹ Auto-selected Ollama model: \(best.name)\u{1B}[0m\n".utf8))
          } else {
            print("Ollama is not running or has no models available.")
            print("Start Ollama and pull a model: ollama pull qwen2.5-coder")
            return
          }
        }
        isUsingAFM = false
      } else {
        print("Unknown model backend: \(modelSpec)")
        print("Supported: afm, ollama, ollama:<model-name>")
        return
      }
    } else if let saved = ModelPreference.load() {
      // Saved preference from /model command — try to honor it
      if saved == "afm" {
        let afmAvailable = FoundationModels.SystemLanguageModel.default.isAvailable
        if afmAvailable {
          let afm = AFMAdapter()
          await loadLoRAIfNeeded(afm: afm, cwd: cwd)
          resolvedAdapter = afm
          isUsingAFM = true
        } else {
          // AFM unavailable — fall through to auto-detect
          FileHandle.standardError.write(Data(
            "\u{1B}[33m⚠ Saved preference is AFM but Apple Intelligence is unavailable. Falling back.\u{1B}[0m\n".utf8))
          if let best = await OllamaDetector.autoDetect() {
            let ctx = await OllamaDetector.contextSize(for: best.name) ?? 4096
            resolvedAdapter = OllamaAdapter(model: best.name, contextSize: ctx)
            isUsingAFM = false
          } else {
            if !checkAppleIntelligence() { return }
            return  // unreachable but satisfies compiler
          }
        }
      } else if saved.hasPrefix("ollama:") {
        let modelName = String(saved.dropFirst("ollama:".count))
        if await OllamaDetector.isRunning() {
          let ctx = await OllamaDetector.contextSize(for: modelName) ?? 4096
          resolvedAdapter = OllamaAdapter(model: modelName, contextSize: ctx)
          isUsingAFM = false
        } else {
          // Ollama not running — fall back to AFM
          FileHandle.standardError.write(Data(
            "\u{1B}[33m⚠ Saved preference is Ollama but server is not running. Using AFM.\u{1B}[0m\n".utf8))
          if !checkAppleIntelligence() { return }
          let afm = AFMAdapter()
          await loadLoRAIfNeeded(afm: afm, cwd: cwd)
          resolvedAdapter = afm
          isUsingAFM = true
        }
      } else {
        // Unknown saved preference — ignore, use default
        let afm = AFMAdapter()
        await loadLoRAIfNeeded(afm: afm, cwd: cwd)
        resolvedAdapter = afm
        isUsingAFM = true
      }
    } else {
      // No --model flag, no saved preference: default to AFM, fall back to Ollama
      let afmAvailable = FoundationModels.SystemLanguageModel.default.isAvailable
      if afmAvailable {
        let afm = AFMAdapter()
        await loadLoRAIfNeeded(afm: afm, cwd: cwd)
        resolvedAdapter = afm
        isUsingAFM = true
      } else {
        // AFM unavailable — try Ollama auto-detection
        if let best = await OllamaDetector.autoDetect() {
          FileHandle.standardError.write(Data(
            "\u{1B}[33m⚠ Apple Intelligence unavailable. Using Ollama (\(best.name)).\u{1B}[0m\n".utf8))
          let ctx = await OllamaDetector.contextSize(for: best.name) ?? 4096
          resolvedAdapter = OllamaAdapter(model: best.name, contextSize: ctx)
          isUsingAFM = false
        } else {
          // Neither AFM nor Ollama available
          print("No language model backend available.")
          print("")
          print("Options:")
          print("  1. Enable Apple Intelligence: System Settings > Apple Intelligence & Siri")
          print("  2. Install Ollama: https://ollama.com, then: ollama pull qwen2.5-coder")
          print("")
          if !pipe {
            print("Open System Settings now? [y/N] ", terminator: "")
            if let answer = readLine(), answer.lowercased().hasPrefix("y") {
              let url = URL(string: "x-apple.systempreferences:com.apple.preference.AppleIntelligence")!
              NSWorkspace.shared.open(url)
            }
          }
          return
        }
      }
    }

    var orchestrator = Orchestrator(adapter: resolvedAdapter, workingDirectory: cwd)
    if verbose { await orchestrator.setVerbose(true) }

    // Background update check (non-blocking, respects offline and pipe mode)
    if !offline {
      let checker = UpdateChecker()
      await checker.checkInBackground(currentVersion: JuncoVersion.current, isPipe: pipe)
    }

    let session = SessionManager(workingDirectory: cwd)
    let forker = ConversationForker(workingDirectory: cwd)
    let history = CommandHistory()
    let fileTree = FileTreeRenderer(workingDirectory: cwd)
    let persistence = SessionPersistence(workingDirectory: cwd)
    let notifications = NotificationService(workingDirectory: cwd)
    let translator = TranslationService(adapter: resolvedAdapter)
    let markdown = MarkdownRenderer()
    let diffRenderer = DiffRenderer()
    let phrases = ThinkingPhrases(projectDirectory: cwd)
    let sessionStart = Date()

    if pipe {
      guard let raw = readLine(), !raw.isEmpty else { return }
      var pipeSession = PersistedSession(workingDirectory: cwd, domain: "general")
      try await runQuery(
        raw, orchestrator: orchestrator, session: session,
        persistence: persistence, notifications: notifications,
        markdown: markdown, diffRenderer: diffRenderer,
        sessionStart: sessionStart, history: history,
        persistedSession: &pipeSession
      )
      return
    }

    // --- Interactive REPL ---

    // Welcome message
    let domain = await orchestrator.domain
    // Stay in the main screen buffer so users can scroll back through output.
    // (enterFullScreen switches to the alternate buffer which has no scrollback.)

    let gitBranch = await session.gitContext()
    let fileCount = FileTools(workingDirectory: cwd).listFiles().count
    let reflectionCount = ReflectionStore(projectDirectory: cwd).count
    let welcome = WelcomeMessage(
      domain: domain, gitBranch: gitBranch,
      fileCount: fileCount, reflectionCount: reflectionCount,
      workingDirectory: cwd, version: JuncoVersion.current,
      modelInfo: resolvedAdapter.backendName
    )
    print(welcome.render(width: Terminal.terminalWidth()))

    // Pre-warm the Neural Engine while the user reads the welcome message.
    // Only applicable for AFM backend.
    if isUsingAFM, let afm = resolvedAdapter as? AFMAdapter {
      Task.detached(priority: .background) {
        await afm.prewarm(systemPrompt: Prompts.classifySystem)
      }
    }

    // Resume session prompt
    if let existing = persistence.load(), !existing.turns.isEmpty {
      Terminal.line(Style.dim("Previous session: \(existing.turns.count) turns. Resuming context."))
    }

    // Initialize persisted session
    var persistedSession = persistence.load() ?? PersistedSession(
      workingDirectory: cwd, domain: domain.kind.rawValue
    )

    // Background task runner for idle-time work
    let bgContext = BackgroundContext(
      workingDirectory: cwd, adapter: resolvedAdapter, domain: domain
    )
    let bgRunner = BackgroundTaskRunner(context: bgContext)

    // Start background services and install signal handlers
    installSignalHandlers()
    let initialOrchestrator = orchestrator
    Task {
      await notifications.requestAuthorization()
      await initialOrchestrator.startFileWatcher()
    }

    // Line editor with completers
    let driver = TerminalDriver()
    let caret = Style.cyan("❯") + " "
    let promptStr = caret
    let editor: LineEditor? = driver.map { _ in
      LineEditor(
        prompt: promptStr,
        completers: [CommandCompleter(), FileCompleter(workingDirectory: cwd)]
      )
    }

    while true {
      // Draw prompt border (full width, thicker line)
      let width = Terminal.terminalWidth()
      let topBorder = Style.dim(String(repeating: "━", count: width))
      Terminal.line(topBorder)

      let line: String?
      var userMode: AgentMode = .build
      if let editor, let driver {
        driver.enableRawMode()
        let result = editor.readLineWithMode(driver: driver, history: history)
        line = result.text
        userMode = result.mode
        driver.restoreMode()
      } else {
        print(promptStr, terminator: "")
        fflush(stdout)
        line = Swift.readLine()
      }

      // Bottom border after input (full width, thicker line)
      let bottomBorder = Style.dim(String(repeating: "━", count: width))
      Terminal.line(bottomBorder)
      guard let input = line else {
        break
      }
      let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }

      // Save to command history
      history.append(trimmed)

      if trimmed.lowercased() == "exit" || trimmed.lowercased() == "quit" {
        await printSessionSummary(orchestrator: orchestrator, sessionStart: sessionStart)
        break
      }

      if trimmed.hasPrefix("/") {
        await handleDirective(
          trimmed, orchestrator: &orchestrator, session: session,
          sessionStart: sessionStart, persistence: persistence,
          persistedSession: &persistedSession,
          forker: forker, fileTree: fileTree,
          translator: translator, cwd: cwd
        )
        continue
      }

      await session.saveCheckpoint()
      await bgRunner.markActive()

      try await runQuery(
        trimmed, orchestrator: orchestrator, session: session,
        persistence: persistence, notifications: notifications,
        markdown: markdown, diffRenderer: diffRenderer,
        sessionStart: sessionStart, history: history,
        persistedSession: &persistedSession, phrases: phrases,
        modeOverride: userMode, translator: translator
      )

      // Check for idle background tasks after each query
      await bgRunner.checkAndRun()
    }
  }

  // MARK: - Query Execution

  private func runQuery(
    _ rawInput: String,
    orchestrator: Orchestrator,
    session: SessionManager,
    persistence: SessionPersistence,
    notifications: NotificationService,
    markdown: MarkdownRenderer,
    diffRenderer: DiffRenderer,
    sessionStart: Date,
    history: CommandHistory,
    persistedSession: inout PersistedSession,
    phrases: ThinkingPhrases = ThinkingPhrases(),
    modeOverride: AgentMode = .build,
    translator: TranslationService? = nil
  ) async throws {
    let taskStart = Date()
    let wordCounter = WordCounter()

    // Single spinner — starts immediately, lives for the entire query lifecycle
    let spinner = Spinner(phrases: phrases)
    await spinner.setMode(modeOverride)
    await spinner.start(stage: "\(modeOverride.rawValue)-mode")

    // Parse input (fast, synchronous)
    let parser = InputParser(workingDirectory: cwd)
    let parsed = parser.parse(rawInput)

    // Translation: detect language, translate to English if needed
    let (translatedQuery, inputLang, translationMsg) = await translator?.processInput(parsed.query)
      ?? (parsed.query, nil, nil)
    if let lang = inputLang {
      await spinner.stop()
      let langName = Locale.current.localizedString(forLanguageCode: lang) ?? lang
      Toast.show("Detected \(langName) — translating to English for processing", level: .info)
    }
    if let msg = translationMsg {
      await spinner.stop()
      let parts = msg.split(separator: ":", maxSplits: 1)
      let kind = String(parts.first ?? "")
      let langName = parts.count > 1 ? String(parts[1]) : "this language"

      Terminal.line("")
      if kind == "afm-fallback" {
        Terminal.line(Style.yellow("  Using on-device AI for translation (good, not perfect)."))
        Terminal.line(Style.dim("  For higher quality, download \(langName) translation models."))
      } else {
        Terminal.line(Style.yellow("  \(langName) translation models are not installed."))
        Terminal.line(Style.dim("  junco will try its best, but dedicated models produce better results."))
      }

      if Terminal.isInteractive {
        Terminal.line("")
        print("  Open Language & Region settings to download? [\(Style.cyan("y"))/\(Style.cyan("n"))]: ", terminator: "")
        fflush(stdout)
        if let choice = Swift.readLine()?.lowercased().first, choice == "y" {
          let p = Process()
          p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
          p.arguments = [TranslationService.settingsURL]
          try? p.run(); p.waitUntilExit()
          Terminal.line(Style.dim("  Settings opened. Select your language, enable 'On Device', then try again."))
          Terminal.line("")
          return
        }
      }
      Terminal.line("")
      await spinner.start(stage: "classify")
    }

    let query = await session.processInput(translatedQuery)

    // Build pipeline callbacks — all user I/O happens here in the CLI layer,
    // never inside the orchestrator actor (which would corrupt terminal state).
    let log = ActionLog()
    let callbacks = PipelineCallbacks(
      onProgress: { [spinner, log] step, total, description in
        await spinner.stop()
        log.stepStart(step, total: total, instruction: description)
        await spinner.start(stage: "execute")
        await spinner.update(detail: "[\(step)/\(total)] \(description)")
      },
      onStepError: { [spinner] step, error in
        await spinner.stop()
        Terminal.line(Style.red("  Step \(step) failed: \(error)"))
        if Terminal.isInteractive {
          print("  [\(Style.cyan("r"))]etry / [\(Style.cyan("s"))]kip / [\(Style.cyan("a"))]bort? ", terminator: "")
          fflush(stdout)
          guard let choice = Swift.readLine()?.lowercased().first else {
            await spinner.start(stage: "execute")
            return .skip
          }
          switch choice {
          case "r":
            await spinner.start(stage: "execute")
            return .retry
          case "a": return .abort
          default:
            await spinner.start(stage: "execute")
            return .skip
          }
        }
        await spinner.start(stage: "execute")
        return .skip
      },
      onPermission: { [spinner] tool, target, detail in
        await spinner.stop()
        let prompt = PermissionService.promptText(tool: tool, target: target, detail: detail)
        Terminal.line(Style.yellow(prompt))
        if Terminal.isInteractive {
          print("  [\(Style.cyan("y"))]es / [\(Style.cyan("n"))]o / [\(Style.cyan("a"))]lways allow? ", terminator: "")
          fflush(stdout)
          guard let choice = Swift.readLine()?.lowercased().trimmingCharacters(in: .whitespaces) else {
            return .deny
          }
          let decision: PermissionDecision
          switch choice {
          case "y", "yes", "": decision = .allow
          case "a", "always":  decision = .alwaysAllow
          default:             decision = .deny
          }
          if decision != .deny {
            await spinner.start(stage: "execute")
          }
          return decision
        }
        await spinner.start(stage: "execute")
        return .allow  // Non-interactive: auto-allow
      },
      onStream: { [wordCounter, spinner] chunk in
        wordCounter.add(chunk)
        let count = wordCounter.count
        await spinner.update(detail: "\(count) words")
      },
      onMode: { [spinner, log] mode in
        await spinner.stop()
        log.classified(mode: mode, taskType: mode.rawValue, targets: [])
        await spinner.setMode(mode)
        await spinner.start(stage: "\(mode.rawValue)-mode")
      },
      onToolResult: { [spinner, log] tool, target, output in
        await spinner.stop()
        switch tool {
        case "bash":
          log.bash(target.isEmpty ? output.prefix(80).description : target)
          if !output.isEmpty { log.bashOutput(output) }
        case "read":
          log.read(target)
        case "create":
          log.create(target, chars: output.count)
        case "write":
          log.write(target, chars: output.count)
        case "edit":
          log.action("\(Style.bold("Edit")) \(Style.cyan(target))")
          if !output.isEmpty { log.output(output) }
        case "patch":
          log.patch(target)
        case "search":
          log.action("\(Style.bold("Search")) \(Style.dim(target))")
          if !output.isEmpty { log.output(output) }
        default:
          log.action("\(tool) \(target)")
        }
        await spinner.start(stage: "execute")
      }
    )

    do {
      let result = try await orchestrator.run(
        query: query,
        referencedFiles: parsed.referencedFiles,
        modeOverride: modeOverride != .build ? modeOverride : nil,
        callbacks: callbacks
      )
      await spinner.stop()

      // Translate output to session language if non-English session
      var translatedInsight: String?
      if let translator, await translator.isTranslating {
        translatedInsight = await translator.processOutput(result.reflection.insight)
      }

      await printResult(
        result, markdown: markdown, diffRenderer: diffRenderer,
        orchestrator: orchestrator, translatedInsight: translatedInsight
      )

      // Build result toast
      if let buildResult = await orchestrator.lastBuildResult {
        Toast.buildResult(buildResult)
      }

      // Persist turn
      persistence.addTurn(PersistedTurn(
        query: query,
        taskType: result.memory.intent?.taskType ?? "unknown",
        response: String(result.reflection.insight.prefix(200)),
        succeeded: result.reflection.succeeded,
        llmCalls: result.memory.llmCalls,
        tokens: result.memory.totalTokensUsed,
        filesModified: Array(result.memory.touchedFiles)
      ), to: &persistedSession)

      await session.recordTurn(TurnSummary(
        query: query,
        taskType: result.memory.intent?.taskType ?? "unknown",
        outcome: result.reflection.succeeded ? "ok" : "error",
        filesModified: Array(result.memory.touchedFiles)
      ))

      await notifications.notifyIfSlow(taskStart: taskStart, query: query)

    } catch {
      await spinner.stop()
      Toast.showError(error)

      await session.recordTurn(TurnSummary(
        query: query, taskType: "error",
        outcome: "\(error)", filesModified: []
      ))
    }
  }

  // MARK: - Slash Directives

  private func handleDirective(
    _ cmd: String,
    orchestrator: inout Orchestrator,
    session: SessionManager,
    sessionStart: Date,
    persistence: SessionPersistence,
    persistedSession: inout PersistedSession,
    forker: ConversationForker,
    fileTree: FileTreeRenderer,
    translator: TranslationService,
    cwd: String
  ) async {
    let parts = cmd.split(separator: " ", maxSplits: 1)
    let directive = String(parts[0]).lowercased()
    let arg = parts.count > 1 ? String(parts[1]) : nil

    switch directive {
    case "/help":
      printHelp()

    case "/clear":
      await session.clear()
      persistence.clear()
      persistedSession = PersistedSession(
        workingDirectory: cwd,
        domain: (await orchestrator.domain).kind.rawValue
      )
      Terminal.line(Style.green("Session cleared."))

    case "/undo":
      let result = await session.undo()
      Terminal.line(result)

    case "/metrics":
      let metrics = await orchestrator.metrics
      let domain = await orchestrator.domain
      let store = ReflectionStore(projectDirectory: cwd)
      let display = MetricsDisplay(
        metrics: metrics, domain: domain,
        startTime: sessionStart, reflectionCount: store.count
      )
      Terminal.divider()
      Terminal.line(display.summary())
      Terminal.divider()

    case "/reflections":
      let store = ReflectionStore(projectDirectory: cwd)
      Terminal.line("Stored reflections: \(store.count)")
      let recent = store.retrieve(query: arg ?? "", limit: 5)
      for r in recent {
        let icon = r.reflection.succeeded ? Style.ok : Style.err
        Terminal.line("  [\(icon)] \(r.reflection.taskSummary)")
        Terminal.line(Style.dim("      \(r.reflection.insight)"))
      }

    case "/notes":
      let pad = Scratchpad(projectDirectory: cwd)
      if let noteArg = arg {
        let noteParts = noteArg.split(separator: "=", maxSplits: 1)
        if noteParts.count == 2 {
          pad.write(key: String(noteParts[0]).trimmingCharacters(in: .whitespaces),
                    value: String(noteParts[1]).trimmingCharacters(in: .whitespaces))
          Terminal.line(Style.green("Note saved."))
        } else {
          Terminal.line(Style.yellow("Usage: /notes key=value"))
        }
      } else {
        let notes = pad.readAll()
        if notes.isEmpty {
          Terminal.line(Style.dim("No notes. Use: /notes key=value"))
        } else {
          for (k, v) in notes.sorted(by: { $0.key < $1.key }) {
            Terminal.line("  \(Style.cyan(k)): \(v)")
          }
        }
      }

    case "/pastes":
      let info = await session.pasteInfo()
      Terminal.line(info)

    case "/paste":
      if let idStr = arg, let id = Int(idStr), let content = await session.getPaste(id) {
        Terminal.line("Paste #\(id) (\(content.count) chars):")
        Terminal.line(Style.dim(String(content.prefix(500))))
      } else {
        Terminal.line(Style.yellow("Usage: /paste <id>"))
      }

    case "/git":
      if let info = await session.gitContext() {
        Terminal.line("Git: \(info)")
      } else {
        Terminal.line(Style.dim("Not a git repository."))
      }

    case "/context":
      if let ctx = await session.previousContext() {
        Terminal.line(ctx)
      } else {
        Terminal.line(Style.dim("No previous turns."))
      }

    case "/session":
      Terminal.line("Session: \(persistedSession.id)")
      Terminal.line("Turns: \(persistedSession.turns.count)")
      for turn in persistedSession.turns.suffix(5) {
        let icon = turn.succeeded ? Style.ok : Style.err
        Terminal.line("  [\(icon)] \(turn.query)")
      }

    case "/files":
      let highlighted = Set(persistedSession.turns.last?.filesModified ?? [])
      Terminal.line(fileTree.render(highlightFiles: highlighted))

    case "/fork":
      let turnIdx = persistedSession.turns.count
      let point = await forker.fork(query: arg ?? "manual fork", turnIndex: turnIdx)
      let depth = await forker.forkDepth
      Terminal.line(Style.cyan("Forked") + " at turn \(turnIdx) " + Style.dim("(id: \(point.id), depth: \(depth))"))
      Terminal.line(Style.dim("  Changes saved. Try a different approach, then /unfork to go back."))

    case "/unfork":
      if let point = await forker.unfork() {
        let depth = await forker.forkDepth
        Terminal.line(Style.green("Restored") + " to fork \(point.id) (turn \(point.turnIndex))")
        if depth > 0 {
          Terminal.line(Style.dim("  \(depth) fork(s) remaining in stack"))
        }
      } else {
        Terminal.line(Style.dim("No forks to restore."))
      }

    case "/forks":
      let history = await forker.forkHistory
      if history.isEmpty {
        Terminal.line(Style.dim("No active forks."))
      } else {
        for (i, point) in history.enumerated() {
          Terminal.line("  \(i + 1). \(Style.cyan(point.id)) turn \(point.turnIndex): \(point.query)")
        }
      }

    #if canImport(Speech)
    case "/speak":
      let duration = Double(arg ?? "5") ?? 5
      Terminal.line(Style.dim("Listening for \(Int(duration))s... speak now"))
      let speech = SpeechService()
      guard await speech.isAvailable else {
        Terminal.line(Style.yellow("Speech recognition not available on this device."))
        break
      }
      do {
        let transcript = try await speech.transcribe(duration: duration)
        if transcript.isEmpty {
          Terminal.line(Style.dim("No speech detected."))
        } else {
          Terminal.line("Heard: \(Style.cyan(transcript))")
          Terminal.line(Style.dim("Use this as your next query, or edit and submit."))
        }
      } catch {
        Terminal.line(Style.red("Speech error: \(error)"))
      }
    #endif

    case "/lang":
      if let code = arg, !code.isEmpty {
        await translator.setLanguage(code)
        let msg = await translator.availabilityMessage(for: code)
        Terminal.line(msg)
        if msg.contains("not downloaded") {
          print(Style.dim("  Open Settings to download? [y/n] "), terminator: "")
          fflush(stdout)
          if Swift.readLine()?.lowercased().first == "y" {
            let p = Process()
            p.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            p.arguments = [TranslationService.settingsURL]
            try? p.run(); p.waitUntilExit()
          }
        }
      } else {
        let current = await translator.currentLanguage
        if let lang = current {
          let langName = Locale.current.localizedString(forLanguageCode: lang) ?? lang
          Terminal.line("Session language: \(Style.cyan(langName)) (\(lang))")
          let msg = await translator.availabilityMessage(for: lang)
          Terminal.line(Style.dim("  \(msg)"))
        } else {
          Terminal.line("Session language: \(Style.dim("English (default)"))")
        }
        Terminal.line(Style.dim("Set with: /lang es, /lang fr, /lang de, etc."))
      }

    case "/model":
      await handleModelSwitch(arg: arg, orchestrator: &orchestrator, cwd: cwd)

    case "/usage":
      let width = min(Terminal.terminalWidth() - 4, 52)
      let barWidth = max(width - 4, 20)  // space for brackets + infinity
      let emptyBar = String(repeating: "\u{2500}", count: barWidth)
      Terminal.line("")
      Terminal.line("  \(Style.dim("[\(emptyBar)]")) \u{221E}")
      Terminal.line("")
      Terminal.line("  \(Style.dim("No cloud. No subscription. No tokens. No limits."))")
      Terminal.line("  \(Style.dim("Everything runs on your device."))")
      Terminal.line("")

    default:
      Terminal.line(Style.yellow("Unknown: \(directive)"))
      Terminal.line(Style.dim("Type /help for commands."))
    }
  }

  /// Handle /model command — show current backend or switch to another.
  private func handleModelSwitch(
    arg: String?,
    orchestrator: inout Orchestrator,
    cwd: String
  ) async {
    let currentName = orchestrator.backendName

    // No argument: show current model and available options
    guard let arg, !arg.isEmpty else {
      Terminal.line("  Current: \(Style.cyan(currentName))")
      Terminal.line("")

      // Show AFM availability
      let afmAvailable = FoundationModels.SystemLanguageModel.default.isAvailable
      Terminal.line("  \(afmAvailable ? "●" : "○") \(Style.bold("afm")) — Apple Foundation Models" +
        (currentName.contains("Apple") ? Style.dim(" (active)") : ""))

      // Show Ollama availability
      let ollamaRunning = await OllamaDetector.isRunning()
      if ollamaRunning {
        let running = await OllamaDetector.runningModels()
        let available = await OllamaDetector.availableModels()
        if !running.isEmpty {
          for model in running {
            let active = currentName.contains(model.name)
            let size = model.parameterSize ?? model.formattedSize
            Terminal.line("  ● \(Style.bold("ollama:\(model.name)")) — \(size), loaded" +
              (active ? Style.dim(" (active)") : ""))
          }
        }
        let notRunning = available.filter { avail in !running.contains(where: { $0.name == avail.name }) }
        for model in notRunning {
          let size = model.parameterSize ?? model.formattedSize
          Terminal.line("  ○ \(Style.bold("ollama:\(model.name)")) — \(size)")
        }
      } else {
        Terminal.line("  ○ \(Style.dim("ollama")) — not running")
      }

      Terminal.line("")
      let hasPref = ModelPreference.load() != nil
      Terminal.line(Style.dim("  Switch with: /model afm, /model ollama:<name>"))
      if hasPref {
        Terminal.line(Style.dim("  Reset:  /model auto"))
      }
      return
    }

    // Switch to specified model
    let spec = arg.lowercased()
    if spec == "afm" {
      guard FoundationModels.SystemLanguageModel.default.isAvailable else {
        Terminal.line(Style.yellow("Apple Intelligence is not available on this device."))
        return
      }
      let afm = AFMAdapter()
      await loadLoRAIfNeeded(afm: afm, cwd: cwd)
      orchestrator = Orchestrator(adapter: afm, workingDirectory: cwd)
      if verbose { await orchestrator.setVerbose(true) }
      ModelPreference.save("afm")
      Terminal.line(Style.green("Switched to Apple Foundation Models."))
      Terminal.line(Style.dim("  Model: \(orchestrator.backendName)"))
    } else if spec.hasPrefix("ollama") {
      let parts = spec.split(separator: ":", maxSplits: 1)
      let modelName: String
      if parts.count == 2 {
        modelName = String(parts[1])
      } else {
        // Auto-detect: prefer running model
        guard let detected = await OllamaDetector.autoDetect() else {
          Terminal.line(Style.yellow("Ollama is not running or has no models."))
          return
        }
        modelName = detected.name
      }
      let ctx = await OllamaDetector.contextSize(for: modelName) ?? 4096
      let adapter = OllamaAdapter(model: modelName, contextSize: ctx)
      orchestrator = Orchestrator(adapter: adapter, workingDirectory: cwd)
      if verbose { await orchestrator.setVerbose(true) }
      ModelPreference.save("ollama:\(modelName)")
      Terminal.line(Style.green("Switched to Ollama (\(modelName))."))
      Terminal.line(Style.dim("  Model: \(orchestrator.backendName)"))
    } else if spec == "auto" {
      ModelPreference.clear()
      Terminal.line(Style.green("Preference cleared. Will auto-detect on next launch."))
    } else {
      Terminal.line(Style.yellow("Unknown model: \(arg)"))
      Terminal.line(Style.dim("Use: /model afm, /model ollama, /model ollama:<name>"))
    }
  }

  // MARK: - Help

  private func printHelp() {
    Terminal.header("Junco Commands")
    let commands: [(String, String)] = [
      ("/clear", "Purge session and start fresh"),
      ("/undo", "Revert last agent changes (git)"),
      ("/fork [reason]", "Snapshot state, try different approach"),
      ("/unfork", "Restore to last fork point"),
      ("/forks", "Show fork stack"),
      ("/files", "Show project file tree"),
      ("/metrics", "Token usage, energy, call counts"),
      ("/reflections [q]", "Show stored reflections"),
      ("/notes [key=val]", "Project scratchpad"),
      ("/session", "Show session history"),
      ("/lang [code]", "Set/show session language"),
      ("/speak [secs]", "Voice input (on-device speech)"),
      ("/git", "Branch and status"),
      ("/context", "Multi-turn context"),
      ("/pastes", "Clipboard paste list"),
      ("/model [backend]", "Show/switch model (afm, ollama)"),
      ("/usage", "Token usage & limits"),
      ("/help", "This help")
    ]
    for (cmd, desc) in commands {
      Terminal.line("  \(Style.cyan(cmd.padding(toLength: 22, withPad: " ", startingAt: 0)))\(desc)")
    }
    Terminal.line("")
    Terminal.line(Style.dim("  @file to target  |  -v for debug  |  exit to quit"))
  }

  // MARK: - Display

  private func printResult(
    _ result: RunResult,
    markdown: MarkdownRenderer,
    diffRenderer: DiffRenderer,
    orchestrator: Orchestrator,
    translatedInsight: String? = nil
  ) async {
    let mem = result.memory
    let ref = result.reflection
    let insight = translatedInsight ?? ref.insight
    let log = ActionLog()

    // Diffs (compact, already logged live for individual edits)
    let diffs = await orchestrator.lastDiffs
    if !diffs.isEmpty {
      for diff in diffs {
        Terminal.line(diffRenderer.render(diff))
      }
    }

    // Build verification
    if let buildResult = await orchestrator.lastBuildResult {
      log.output(buildResult)
    }

    // Response
    Terminal.line("")
    if ref.succeeded {
      Terminal.line(Style.green("Done: ") + markdown.render(insight))
    } else {
      Terminal.line(Style.yellow("Partial: ") + markdown.render(insight))
    }
    if !ref.improvement.isEmpty {
      Terminal.line(Style.dim("  Learned: \(ref.improvement)"))
    }

    log.done(
      succeeded: ref.succeeded,
      calls: mem.llmCalls,
      tokens: mem.totalTokensUsed,
      files: mem.touchedFiles.count
    )
  }

  private func printSessionSummary(orchestrator: Orchestrator, sessionStart: Date) async {
    let metrics = await orchestrator.metrics
    let domain = await orchestrator.domain
    let store = ReflectionStore(projectDirectory: cwd)

    Terminal.divider()
    let display = MetricsDisplay(
      metrics: metrics, domain: domain,
      startTime: sessionStart, reflectionCount: store.count
    )
    Terminal.line(Style.bold("Session complete"))
    Terminal.line(display.summary())
  }
}
