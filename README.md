# Junco

<p align="center">
  <img src="junco.svg" width="128" height="128" alt="Junco Icon" />
</p>

<h1 align="center">Junco</h1>

<p align="center">
  <strong>Free, local AI coding agent for Swift on Apple platforms</strong><br />
  Junco runs <i>on-device</i> using Apple Intelligence or Ollama. No rate limits, no API keys, no subscriptions.
</p>

<p align="center">
  <a href="https://apple.com/macos"><img src="https://img.shields.io/badge/macOS-26%2B-lightgrey.svg" alt="macOS"></a>
  <a href="https://swift.org"><img src="https://img.shields.io/badge/Swift-6.0-F05138.svg" alt="Swift"></a>
  <a href="LICENSE"><img src="https://img.shields.io/badge/license-MIT-blue.svg" alt="License"></a>
  <a href="http://makeapullrequest.com"><img src="https://img.shields.io/badge/PRs-welcome-brightgreen.svg" alt="PRs Welcome"></a>
</p>

<p align="center">
  <a href="#install">Install</a> ·
  <a href="#usage">Usage</a> ·
  <a href="#architecture">Architecture</a> ·
  <a href="#requirements">Requirements</a>
</p>

**Junco** is an AI coding agent for Swift that runs entirely on-device using Apple Foundation Models (AFM) or [Ollama](https://github.com/ollama/ollama/). No API keys, no cloud, no telemetry.

## Install

Junco is a single Mach-O binary, written entirely in Swift and compiled for Apple Silicon (arm64). Download Junco with a single command:

```bash
curl -fsSL https://raw.githubusercontent.com/LastByteLLC/junco/master/install.sh | bash
```

This downloads the latest signed & notarized binary to `/usr/local/bin`.

To install to a custom location:

```bash
JUNCO_INSTALL_DIR=~/.local/bin curl -fsSL https://raw.githubusercontent.com/LastByteLLC/junco/master/install.sh | bash
```

Junco checks for updates automatically at launch, or you can run `junco update` to get the latest version.

### Build from source

```bash
git clone https://github.com/LastByteLLC/junco.git
cd junco
swift build -c release
cp .build/release/junco /usr/local/bin/
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
| `/lang` | Set the session language (i.e. `en`, `de`, `fr`) |
| `/speak` | Speak your prompt to Junco |
| `/context` | Multi-turn context from previous queries |
| `/pastes` | List clipboard pastes in this session |
| `/usage` | Unmeterd usage! |
| `exit` | End session with summary |

#### Command Notes

- Chatting with Junco in a language other than English uses Apple's [`TranslationSession` APIs](https://developer.apple.com/documentation/translation/translationsession), processed on your local device.
- Speech-to-text (STT) uses [`SpeechTranscriber`](https://developer.apple.com/documentation/speech/speechtranscriber) for on-device prompt transcription

### Pipe Mode

```bash
echo "explain the main function" | junco --pipe --directory ./my-project
```

### `@`-File Targeting

Prefix paths with `@` to explicitly target files. Junco resolves paths and injects content into the agent's context:

```text
junco> refactor @Sources/Networking/Client.swift to use async/await
```

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
swift build              # Debug build
swift build -c release   # Release build
swift test               # Run tests
```

## Requirements

- macOS 26.0+
- Apple Silicon (M1/M2/M3/M4/M5)
- Apple Intelligence enabled
- Xcode 26+ or Swift 6.2+ toolchain

## License

[MIT](./LICENSE)
