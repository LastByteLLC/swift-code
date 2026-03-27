// Junco.swift — CLI entry point with TUI
//
// REPL with slash directives, clipboard handling, multi-turn context,
// undo, ANSI output, session metrics, and domain detection.

import ArgumentParser
import Foundation
import JuncoKit

@main
struct Junco: AsyncParsableCommand {
  static let configuration = CommandConfiguration(
    commandName: "junco",
    abstract: "An AI coding agent powered by on-device language models.",
    version: "0.3.0"
  )

  @Option(name: .shortAndLong, help: "Working directory (default: current)")
  var directory: String?

  @Flag(name: .long, help: "Run a single query from stdin, then exit")
  var pipe = false

  @Flag(name: .shortAndLong, help: "Show debug output for every pipeline stage (to stderr)")
  var verbose = false

  func run() async throws {
    let cwd = directory ?? FileManager.default.currentDirectoryPath
    let adapter = AFMAdapter()
    let orchestrator = Orchestrator(adapter: adapter, workingDirectory: cwd)
    if verbose { await orchestrator.setVerbose(true) }
    let session = SessionManager(workingDirectory: cwd)
    let sessionStart = Date()
    let domain = await orchestrator.domain

    if pipe {
      guard let query = readLine(), !query.isEmpty else { return }
      let processed = await session.processInput(query)
      try await runQuery(processed, orchestrator: orchestrator, session: session)
      return
    }

    // Interactive REPL
    let gitInfo = await session.gitContext()
    Terminal.header("junco v0.3.0 — on-device AI coding agent")
    Terminal.line(Style.dim("Domain: \(domain.displayName) | Dir: \(cwd)"))
    if let git = gitInfo {
      Terminal.line(Style.dim("Git: \(git)"))
    }
    Terminal.line(Style.dim("Type /help for commands, exit to quit"))
    Terminal.divider()

    // Set up interactive line editor (falls back to plain readLine if not a TTY)
    let driver = TerminalDriver()
    let promptStr = Style.cyan("junco") + Style.dim("> ")
    let editor: LineEditor? = driver.map { _ in
      LineEditor(
        prompt: promptStr,
        completers: [
          CommandCompleter(),
          FileCompleter(workingDirectory: cwd),
        ]
      )
    }

    while true {
      let line: String?
      if let editor, let driver {
        // Raw mode ON for interactive input (completions, arrow keys)
        driver.enableRawMode()
        line = editor.readLine(driver: driver)
        // Raw mode OFF for agent execution (needs normal stdout)
        driver.restoreMode()
      } else {
        print(promptStr, terminator: "")
        fflush(stdout)
        line = Swift.readLine()
      }
      guard let input = line else { break }
      let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
      guard !trimmed.isEmpty else { continue }

      if trimmed.lowercased() == "exit" || trimmed.lowercased() == "quit" {
        await printSessionSummary(orchestrator: orchestrator, session: session, sessionStart: sessionStart)
        break
      }

      if trimmed.hasPrefix("/") {
        await handleDirective(
          trimmed, orchestrator: orchestrator,
          session: session, sessionStart: sessionStart
        )
        continue
      }

      // Process input (clipboard detection, paste substitution)
      let processed = await session.processInput(trimmed)

      // Save checkpoint for undo (if git repo)
      await session.saveCheckpoint()

      try await runQuery(processed, orchestrator: orchestrator, session: session)
    }
  }

  // MARK: - Query Execution

  private func runQuery(
    _ query: String,
    orchestrator: Orchestrator,
    session: SessionManager
  ) async throws {
    Terminal.status("thinking...")

    do {
      let result = try await orchestrator.run(query: query)
      Terminal.clearLine()
      printResult(result)

      // Record turn for multi-turn context
      await session.recordTurn(TurnSummary(
        query: query,
        taskType: result.memory.intent?.taskType ?? "unknown",
        outcome: result.reflection.succeeded ? "ok" : "error",
        filesModified: Array(result.memory.touchedFiles)
      ))
    } catch {
      Terminal.clearLine()
      Terminal.line(Style.red("[error] \(error)"))

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
    sessionStart: Date
  ) async {
    let parts = cmd.split(separator: " ", maxSplits: 1)
    let directive = String(parts[0]).lowercased()
    let arg = parts.count > 1 ? String(parts[1]) : nil

    switch directive {
    case "/help":
      printHelp()

    case "/clear":
      await session.clear()
      Terminal.line(Style.green("Session cleared.") + " Context, pastes, and turn history purged.")

    case "/undo":
      let result = await session.undo()
      Terminal.line(result)

    case "/metrics":
      let metrics = await orchestrator.metrics
      let domain = await orchestrator.domain
      let cwd = directory ?? FileManager.default.currentDirectoryPath
      let store = ReflectionStore(projectDirectory: cwd)
      let display = MetricsDisplay(
        metrics: metrics, domain: domain,
        startTime: sessionStart, reflectionCount: store.count
      )
      Terminal.divider()
      Terminal.line(display.summary())
      Terminal.divider()

    case "/reflections":
      let cwd = directory ?? FileManager.default.currentDirectoryPath
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

    case "/pastes":
      let info = await session.pasteInfo()
      Terminal.line(info)

    case "/paste":
      if let idStr = arg, let id = Int(idStr), let content = await session.getPaste(id) {
        Terminal.line("Paste #\(id) (\(content.count) chars):")
        Terminal.line(Style.dim(String(content.prefix(500))))
        if content.count > 500 { Terminal.line(Style.dim("... [\(content.count - 500) more chars]")) }
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
        Terminal.line(Style.dim("No previous turns in this session."))
      }

    default:
      Terminal.line(Style.yellow("Unknown: \(directive)"))
      Terminal.line(Style.dim("Type /help for available commands."))
    }
  }

  // MARK: - Help

  private func printHelp() {
    Terminal.header("Junco Commands")
    let commands = [
      ("/clear", "Purge session context, pastes, and turn history"),
      ("/undo", "Revert last agent changes (requires git)"),
      ("/metrics", "Show session metrics (tokens, energy, time)"),
      ("/reflections [query]", "Show stored reflections, optionally filtered"),
      ("/domain", "Show detected project domain and config"),
      ("/pastes", "List all clipboard pastes in this session"),
      ("/paste <id>", "Show full content of a paste"),
      ("/git", "Show git branch and status"),
      ("/context", "Show multi-turn context from previous queries"),
      ("/help", "Show this help"),
    ]
    for (cmd, desc) in commands {
      Terminal.line("  \(Style.cyan(cmd.padding(toLength: 24, withPad: " ", startingAt: 0)))\(desc)")
    }
    Terminal.line("")
    Terminal.line(Style.dim("Prefix files with @ for explicit targeting: fix @src/auth.swift"))
  }

  // MARK: - Display

  private func printResult(_ result: RunResult) {
    let mem = result.memory
    let ref = result.reflection

    if let plan = mem.plan {
      Terminal.header("Plan (\(plan.steps.count) steps)")
      for (i, step) in plan.steps.enumerated() {
        let done = i < plan.steps.count
        let marker = done ? Style.green("+") : Style.dim(" ")
        Terminal.line("  [\(marker)] \(step.instruction)")
      }
    }

    if !mem.observations.isEmpty {
      Terminal.header("Results")
      for obs in mem.observations {
        let icon = obs.outcome == "ok" ? Style.ok : Style.err
        Terminal.line("  [\(icon)] \(Style.dim(obs.tool)): \(obs.keyFact)")
      }
    }

    if ref.succeeded {
      Terminal.line(Style.green("Done: ") + ref.insight)
    } else {
      Terminal.line(Style.yellow("Partial: ") + ref.insight)
    }
    if !ref.improvement.isEmpty {
      Terminal.line(Style.dim("  Learned: \(ref.improvement)"))
    }

    Terminal.line(Style.dim(
      "[\(mem.llmCalls) calls | ~\(mem.totalTokensUsed) tokens | \(mem.touchedFiles.count) files]"
    ))
  }

  private func printSessionSummary(
    orchestrator: Orchestrator, session: SessionManager, sessionStart: Date
  ) async {
    let metrics = await orchestrator.metrics
    let domain = await orchestrator.domain
    let cwd = directory ?? FileManager.default.currentDirectoryPath
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
