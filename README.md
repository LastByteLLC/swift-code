# swift-claude-code

Building a simplified Claude Code-like CLI agent from scratch in Swift.

> **Current progress:** Stage 02 of 12 — tool dispatch with `read_file`, `write_file`, `edit_file`

## Why This Exists

If you've used Claude Code, you know exactly what I'm talking about. Especially the first time you use it — it's just _different_ than any other coding agent out there. There's definitely some magic behind Claude Code, and I went down a huge rabbit hole trying to figure out what makes it special.

My hypothesis: **Claude Code is so good because of how simple it is.**

Not the UI — the architecture. Down to the fact that it doesn't really have many tools. And the tools it does have are really simple: a search tool, a file editing tool. That's about it. But those tools are _really, really good_.

The other big thing is that Claude Code relies on the model way more than other tools. Most people build a lot of scaffolding around the model, but Claude Code really lets the model do all of the heavy lifting.

So I wanted to understand this deeply — not by reading about it, but by building it. This project rebuilds the core agent loop from scratch in Swift, one layer at a time, to see exactly how few moving parts you actually need.

## Architecture

Two-target Swift Package Manager project:

```
swift-claude-code/
├── Package.swift
├── Sources/
│   ├── Core/                ← library (all logic)
│   │   ├── API/
│   │   ├── Agent.swift      agent loop + tool dispatch
│   │   └── ShellExecutor.swift
│   └── cli/                 ← executable (@main entry point)
└── Tests/CoreTests/
```

**Core** is the library — API client, shell executor, agent loop, tools, everything testable. **cli** is just the entry point. The executable is called `claude`.

Raw HTTP to `POST https://api.anthropic.com/v1/messages` using [AsyncHTTPClient](https://github.com/swift-server/async-http-client). Works on both macOS and Linux.

## The Agent Loop

The whole thing boils down to one loop:

```swift
func run(query: String) async throws -> String {
    messages.append(.user(query))

    while true {
        let request = APIRequest(
            model: model, system: systemPrompt, messages: messages, tools: Self.toolDefinitions
        )
        let response = try await apiClient.createMessage(request)
        messages.append(Message(role: .assistant, content: response.content))

        guard response.stopReason == .toolUse else {
            return response.content.textContent
        }

        var results: [ContentBlock] = []
        for block in response.content {
            if case .toolUse(let id, let name, let input) = block {
                let output = await executeTool(name: name, input: input)
                results.append(.toolResult(toolUseId: id, content: output, isError: false))
            }
        }
        messages.append(Message(role: .user, content: results))
    }
}
```

That's it. The loop is the invariant. Tools are the variable. Every stage adds entries to the tool handler dictionary and injection points before the API call, but the loop body itself never changes.

## Roadmap

Each stage adds one mechanism on top of the previous one. Progress is tracked via git tags.

| Stage  | What It Adds                                                           | Tag                |
| ------ | ---------------------------------------------------------------------- | ------------------ |
| **00** | Bootstrap: SPM project                                                 | `00-bootstrap`     |
| **01** | Agent loop + bash tool                                                 | `01-agent-loop`    |
| **02** | Tool dispatch: `read_file`, `write_file`, `edit_file` with path safety | `02-tool-dispatch` |
| 03     | TodoWrite: Codable todo tracking with nag reminder injection           | —                  |
| 04     | Subagents: recursive `agentLoop()` with fresh messages                 | —                  |
| 05     | Skill loading: read `.md` files from disk, inject as tool results      | —                  |
| 06     | Context compaction: 3-layer strategy (micro, auto, manual)             | —                  |
| 07     | Task system: file-based CRUD with dependency DAG                       | —                  |
| 08     | Background tasks: `Task {}` + actor-based notification queue           | —                  |
| 09     | Agent teams: JSONL mailbox files + actor coordination                  | —                  |
| 10     | Team protocols: request-response with correlation IDs                  | —                  |
| 11     | Autonomous agents: idle-poll-claim cycle                               | —                  |
| 12     | Worktree isolation: `git worktree` via Process                         | —                  |

## Tech Stack

- **Swift 6.2** with strict concurrency
- **AsyncHTTPClient** (SwiftNIO-based) for cross-platform HTTP + streaming SSE
- **Foundation `Process`** for shell command execution
- macOS 10.15+ / Linux

## Getting Started

```bash
git clone https://github.com/ivan-magda/swift-claude-code.git
cd swift-claude-code

# Set up your API key and model
cp .env.example .env
# Edit .env with your ANTHROPIC_API_KEY and MODEL_ID

swift build
swift run claude
```

## References

- [Anthropic Messages API](https://docs.anthropic.com/en/api/messages) — the single endpoint the entire agent talks to
- [Anthropic Tool Use](https://docs.anthropic.com/en/docs/build-with-claude/tool-use/overview) — how tool definitions, `tool_use`, and `tool_result` work

## License

MIT
