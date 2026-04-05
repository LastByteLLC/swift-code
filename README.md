# Junco

<p align="center">
  <img src="junco.svg" width="128" height="128" alt="Junco Icon" />
</p>

<h1 align="center">Junco</h1>

<p align="center">
  <strong>Free, local AI coding agent for Swift on Apple platforms</strong><br />
  Junco runs <i>on-device</i> using Apple Intelligence. No rate limits, no API keys, no subscriptions.
</p>

<p align="center">
  <a href="https://apple.com/macos"><img src="https://img.shields.io/badge/macOS-26%2B-lightgrey.svg" alt="macOS"></a>
  <a href="https://swift.org"><img src="https://img.shields.io/badge/Swift-6.0-F05138.svg" alt="Swift"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License"></a>
  <a href="http://makeapullrequest.com"><img src="https://img.shields.io/badge/PRs-welcome-brightgreen.svg" alt="PRs Welcome"></a>
</p>

<p align="center">
  <a href="#building">Building</a> ·
  <a href="#quick-start">Quick Start</a> ·
  <a href="#requirements">Requirements</a>
</p>

**Junco** is an AI coding agent for Swift that runs entirely on-device using Apple Foundation Models (AFM). No API keys, no cloud, no telemetry.

**Why Junco?** Junco uses a micro-conversation pipeline to work within AFM's small context window — each stage (classify, plan, execute, reflect) is a separate LLM call with focused context and structured `@Generable` output. A trained CRF text classifier handles intent detection in ~10ms, deterministic strategy selection and conditional reflection skip LLM calls when possible, and a reflexion loop stores insights for future tasks. Junco also uses a [custom LoRA adapter](https://developer.apple.com/documentation/foundationmodels/loading-and-using-a-custom-adapter-with-foundation-models) trained on recent Swift 6.3+ permissively-licensed code, public documentation, and synthetic data.

## Quick Start

```bash
git clone https://github.com/LastByteLLC/junco.git
cd junco
swift build
swift run junco
```

Requires **macOS 26+** and **Apple Silicon** (M1+). No API keys or configuration needed — Apple Intelligence must be enabled in System Settings.

## Usage

```
junco> fix the login bug in @Sources/Auth.swift
junco> explain how the payment flow works
junco> add tests for the User model
junco> /metrics
junco> /undo
```

### Commands

| Command | Description |
| --- | --- |
| `/help` | Show all commands |
| `/clear` | Purge session context and turn history |
| `/undo` | Revert last agent changes (requires git) |
| `/metrics` | Token usage, energy estimate, call counts |
| `/reflections [query]` | Show stored reflections, optionally filtered |
| `/git` | Branch and change status |
| `/context` | Multi-turn context from previous queries |
| `/pastes` | List clipboard pastes in this session |
| `exit` | End session with summary |

### Pipe Mode

```bash
echo "explain the main function" | junco --pipe --directory ./my-project
```

### `@`-File Targeting

Prefix paths with `@` to explicitly target files. Junco resolves paths and injects content into the agent's context:

```
junco> refactor @Sources/Networking/Client.swift to use async/await
```

## Architecture

Junco processes queries through a pipeline of independent LLM calls, each with its own context window:

```
query → CLASSIFY → STRATEGY → PLAN → EXECUTE → REFLECT
         10ms      instant    ~2s     ~2s × N    instant
        (ML/CRF)  (determ.)  (AFM)    (AFM)    (determ.)
```

The key principle is **deterministic scaffolding around stochastic generation** — Swift code handles orchestration, error routing, tool dispatch, and validation; the on-device model only generates plans and tool parameters.

### What Makes This Work at 4K Tokens

- **Micro-conversations** — each pipeline stage sees only what it needs; no multi-turn conversation history
- **Typed tool dispatch** — the `ToolName` enum eliminates a redundant LLM call per step (the plan already specifies which tool to use)
- **Deterministic bypasses** — strategy selection and reflection are deterministic for common cases, saving 2 LLM calls per task
- **Priority-weighted prompt packing** — when context is tight, `PromptSection` priorities ensure file content wins over reflections and hints
- **`@Generable` structured output** — compile-time type safety via Apple's Foundation Models framework, zero parsing overhead
- **`validateAndFix` loop** — generated code is linted, validated (via `swiftc -parse`), and retried with targeted error regions when needed
- **Typed errors** — `PipelineError` and `StepOutcome` enums enable error-specific recovery (auto-retry on deserialization failure, truncate on context overflow)
- **Two-phase code generation** — large Swift files are generated as skeleton + per-method bodies, each in a separate context window

### Research Mode

When queries contain URLs or need external context for disambiguation, Junco automatically enters Research Mode:

- **URL auto-fetch** — URLs in the query are fetched, HTML-stripped, boilerplate-filtered, and compacted to ~400 tokens
- **Web search** — ambiguous queries trigger a DuckDuckGo Instant Answer search (no API key, no auth)
- **Aggressive compaction** — strips navigation, cookie banners, sign-in prompts; collapses whitespace; budget-splits across multiple sources

Research Mode is agent-internal — it runs automatically when needed, not as a user command.

### Layers

| Layer | Purpose |
| --- | --- |
| **Agent** | Pipeline orchestration, session management, reflexion, research, skills |
| **Models** | `@Generable` structured types, token budget, `ToolName`/`StepOutcome`/`PipelineError` enums |
| **LLM** | Adapter pattern (AFM with optional LoRA adapter) |
| **Tools** | Sandboxed shell, validated file ops, template rendering, diff preview, FSEvents |
| **RAG** | Regex-based Swift symbol indexer, BM25 context packing |
| **TUI** | ANSI output with piped fallback, syntax highlighting, markdown rendering |

### Key Design Decisions

- **Micro-conversations over long context** — AFM has ~4K tokens. Each pipeline stage sees only what it needs.
- **Deterministic scaffolding** — the model makes one decision per call; Swift code handles orchestration, tool dispatch, validation, and error recovery.
- **ML for classification** — CRF model trained on 9.5K examples replaces one LLM call per task.
- **Reflexion loop** — post-task reflections stored in `.junco/reflections.jsonl`, retrieved by keyword match for future similar tasks. Clean successes skip the LLM reflect call entirely.
- **MicroSkills** — token-capped prompt modifiers (e.g., "swift-test" forces Swift Testing patterns, "explain-only" disables write tools).
- **Template rendering** — structured file formats (entitlements, Package.swift, Info.plist, .xcprivacy, .gitignore, .xcconfig) use `@Generable` intent types + deterministic renderers, guaranteeing valid syntax.

## Project Files

Junco creates a `.junco/` directory in your project for:

- `reflections.jsonl` — learned insights from past tasks
- `config.json` — project configuration
- `scratchpad.json` — persistent project notes
- `skills.json` — custom micro-skills

Global state lives in `~/.junco/`:

- `junco.db` — SQLite with FTS5 for cross-project reflection search
- `models/` — compiled ML models

## Building

```bash
# Debug
swift build

# Release
swift build -c release

# Run tests
swift test

# Install
cp .build/release/junco /usr/local/bin/
```

## Requirements

- macOS 26.0+
- Apple Silicon (M1/M2/M3/M4/M5)
- Apple Intelligence enabled
- Xcode 26+ or Swift 6.2+ toolchain

## License

MIT
