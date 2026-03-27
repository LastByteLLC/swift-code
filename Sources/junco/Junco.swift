// Junco.swift — CLI entry point with fully wired TUI
//
// All features connected: welcome message, session persistence,
// thinking phrases, markdown rendering, diff display, command history,
// notifications, web search, scratchpad, permissions.

import ArgumentParser
import Foundation
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
    version: "0.4.0"
  )

  @Option(name: .shortAndLong, help: "Working directory (default: current)")
  var directory: String?

  @Flag(name: .long, help: "Run a single query from stdin, then exit")
  var pipe = false

  @Flag(name: .shortAndLong, help: "Show debug output for every pipeline stage (to stderr)")
  var verbose = false

  // Shared services (lazy initialized)
  private var cwd: String { directory ?? FileManager.default.currentDirectoryPath }

  func run() async throws {
    let cwd = self.cwd
    let adapter = AFMAdapter()
    let orchestrator = Orchestrator(adapter: adapter, workingDirectory: cwd)
    if verbose { await orchestrator.setVerbose(true) }

    let session = SessionManager(workingDirectory: cwd)
    let forker = ConversationForker(workingDirectory: cwd)
    let history = CommandHistory()
    let fileTree = FileTreeRenderer(workingDirectory: cwd)
    let persistence = SessionPersistence(workingDirectory: cwd)
    let notifications = NotificationService(workingDirectory: cwd)
    let translator = TranslationService(adapter: adapter)
    let markdown = MarkdownRenderer()
    let diffRenderer = DiffRenderer()
    let phrases = ThinkingPhrases(projectDirectory: cwd)
    let sessionStart = Date()

    if pipe {
      guard let raw = readLine(), !raw.isEmpty else { return }
      let parser = InputParser(workingDirectory: cwd)
      let parsed = parser.parse(raw)
      let urlCtx = await parser.fetchURLs(parsed.urls)
      let processed = await session.processInput(parsed.query)
      var pipeSession = PersistedSession(workingDirectory: cwd, domain: "general")
      try await runQuery(
        processed, orchestrator: orchestrator, session: session,
        persistence: persistence, notifications: notifications,
        markdown: markdown, diffRenderer: diffRenderer,
        sessionStart: sessionStart, history: history,
        referencedFiles: parsed.referencedFiles, urlContext: urlCtx,
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
      workingDirectory: cwd, version: "0.4.0"
    )
    print(welcome.render(width: Terminal.terminalWidth()))

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
      workingDirectory: cwd, adapter: adapter, domain: domain
    )
    let bgRunner = BackgroundTaskRunner(context: bgContext)

    // Start background services and install signal handlers
    installSignalHandlers()
    Task {
      await notifications.requestAuthorization()
      await orchestrator.startFileWatcher()
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
      if let editor, let driver {
        driver.enableRawMode()
        line = editor.readLine(driver: driver, history: history)
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
          trimmed, orchestrator: orchestrator, session: session,
          sessionStart: sessionStart, persistence: persistence,
          persistedSession: &persistedSession,
          forker: forker, fileTree: fileTree,
          translator: translator
        )
        continue
      }

      // Parse input
      let parser = InputParser(workingDirectory: cwd)
      let parsed = parser.parse(trimmed)
      let urlContext = await parser.fetchURLs(parsed.urls)

      // Translation: detect language, translate to English if needed
      let (translatedQuery, inputLang, translationMsg) = await translator.processInput(parsed.query)
      if let lang = inputLang {
        let langName = Locale.current.localizedString(forLanguageCode: lang) ?? lang
        Toast.show("Detected \(langName) — translating to English for processing", level: .info)
      }
      if let msg = translationMsg {
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
            continue
          }
        }
        Terminal.line("")
      }

      let query = await session.processInput(translatedQuery)

      await session.saveCheckpoint()
      await bgRunner.markActive()

      try await runQuery(
        query, orchestrator: orchestrator, session: session,
        persistence: persistence, notifications: notifications,
        markdown: markdown, diffRenderer: diffRenderer,
        sessionStart: sessionStart, history: history,
        referencedFiles: parsed.referencedFiles, urlContext: urlContext,
        persistedSession: &persistedSession, phrases: phrases,
        translator: translator
      )

      // Check for idle background tasks after each query
      await bgRunner.checkAndRun()
    }
  }

  // MARK: - Query Execution

  private func runQuery(
    _ query: String,
    orchestrator: Orchestrator,
    session: SessionManager,
    persistence: SessionPersistence,
    notifications: NotificationService,
    markdown: MarkdownRenderer,
    diffRenderer: DiffRenderer,
    sessionStart: Date,
    history: CommandHistory,
    referencedFiles: [String] = [],
    urlContext: String? = nil,
    persistedSession: inout PersistedSession,
    phrases: ThinkingPhrases = ThinkingPhrases(),
    translator: TranslationService? = nil
  ) async throws {
    let taskStart = Date()
    let progress = ProgressBar(phrases: phrases)
    let wordCounter = WordCounter()

    // Build pipeline callbacks — all user I/O happens here in the CLI layer,
    // never inside the orchestrator actor (which would corrupt terminal state).
    let callbacks = PipelineCallbacks(
      onProgress: { step, total, description in
        let status = progress.render(step: step, total: total, tool: "", target: description)
        Terminal.status(status)
      },
      onStepError: { step, error in
        Terminal.clearLine()
        Terminal.line(Style.red("  Step \(step) failed: \(error)"))
        if Terminal.isInteractive {
          print("  [\(Style.cyan("r"))]etry / [\(Style.cyan("s"))]kip / [\(Style.cyan("a"))]bort? ", terminator: "")
          fflush(stdout)
          guard let choice = Swift.readLine()?.lowercased().first else { return .skip }
          switch choice {
          case "r": return .retry
          case "a": return .abort
          default:  return .skip
          }
        }
        return .skip
      },
      onPermission: { tool, target, detail in
        Terminal.clearLine()
        let prompt = PermissionService.promptText(tool: tool, target: target, detail: detail)
        Terminal.line(Style.yellow(prompt))
        if Terminal.isInteractive {
          print("  [\(Style.cyan("y"))]es / [\(Style.cyan("n"))]o / [\(Style.cyan("a"))]lways allow? ", terminator: "")
          fflush(stdout)
          guard let choice = Swift.readLine()?.lowercased().trimmingCharacters(in: .whitespaces) else {
            return .deny
          }
          switch choice {
          case "y", "yes", "": return .allow
          case "a", "always":  return .alwaysAllow
          default:             return .deny
          }
        }
        return .allow  // Non-interactive: auto-allow
      },
      onStream: { [wordCounter] chunk in
        wordCounter.add(chunk)
        let count = wordCounter.count
        Terminal.status("\(ThinkingPhrases.spinner(tick: count)) Generating... \(count) words")
      }
    )

    Terminal.status(progress.renderStage("classify"))

    do {
      let result = try await orchestrator.run(
        query: query,
        referencedFiles: referencedFiles,
        urlContext: urlContext,
        callbacks: callbacks
      )
      Terminal.clearLine()

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
      Terminal.clearLine()
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
    orchestrator: Orchestrator,
    session: SessionManager,
    sessionStart: Date,
    persistence: SessionPersistence,
    persistedSession: inout PersistedSession,
    forker: ConversationForker,
    fileTree: FileTreeRenderer,
    translator: TranslationService
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

    case "/domain":
      let domain = await orchestrator.domain
      Terminal.line("Domain: \(Style.bold(domain.displayName))")
      Terminal.line("Extensions: \(domain.fileExtensions.joined(separator: ", "))")
      if let build = domain.buildCommand { Terminal.line("Build: \(Style.dim(build))") }
      if let test = domain.testCommand { Terminal.line("Test: \(Style.dim(test))") }

    case "/search":
      guard let query = arg, !query.isEmpty else {
        Terminal.line(Style.yellow("Usage: /search <query>"))
        return
      }
      Terminal.status("Searching...")
      let ws = WebSearch()
      if let result = await ws.search(query: query) {
        Terminal.clearLine()
        Terminal.line(ws.formatForPrompt(result))
      } else {
        Terminal.clearLine()
        Terminal.line(Style.dim("No results found."))
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
      let available = await speech.isAvailable
      guard available else {
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

    default:
      Terminal.line(Style.yellow("Unknown: \(directive)"))
      Terminal.line(Style.dim("Type /help for commands."))
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
      ("/domain", "Detected project domain"),
      ("/search <query>", "Web search (DuckDuckGo)"),
      ("/notes [key=val]", "Project scratchpad"),
      ("/session", "Show session history"),
      ("/lang [code]", "Set/show session language"),
      ("/speak [secs]", "Voice input (on-device speech)"),
      ("/git", "Branch and status"),
      ("/context", "Multi-turn context"),
      ("/pastes", "Clipboard paste list"),
      ("/help", "This help"),
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

    // Plan
    if let plan = mem.plan {
      Terminal.header("Plan (\(plan.steps.count) steps)")
      for (_, step) in plan.steps.enumerated() {
        Terminal.line("  [\(Style.green("+"))] \(step.instruction)")
      }
    }

    // Observations
    if !mem.observations.isEmpty {
      Terminal.header("Results")
      for obs in mem.observations {
        let icon = obs.outcome == "ok" ? Style.ok : Style.err
        Terminal.line("  [\(icon)] \(Style.dim(obs.tool)): \(obs.keyFact)")
      }
    }

    // Diffs
    let diffs = await orchestrator.lastDiffs
    if !diffs.isEmpty {
      Terminal.header("Changes")
      for diff in diffs {
        Terminal.line(diffRenderer.render(diff))
      }
    }

    // Build verification
    if let buildResult = await orchestrator.lastBuildResult {
      Terminal.header("Build")
      Terminal.line(buildResult)
    }

    // Response (rendered as markdown, possibly translated)
    if ref.succeeded {
      Terminal.line(Style.green("Done: ") + markdown.render(insight))
    } else {
      Terminal.line(Style.yellow("Partial: ") + markdown.render(insight))
    }
    if !ref.improvement.isEmpty {
      Terminal.line(Style.dim("  Learned: \(ref.improvement)"))
    }

    Terminal.line(Style.dim(
      "[\(mem.llmCalls) calls | ~\(mem.totalTokensUsed) tokens | \(mem.touchedFiles.count) files]"
    ))
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
