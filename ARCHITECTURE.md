# Architecture

**About Junco**. Junco uses a micro-conversation pipeline to work within AFM's small context window — each stage (classify, plan, execute, reflect) is a separate LLM call with focused context and structured `@Generable` output. A trained CRF text classifier handles intent detection in ~10ms, deterministic strategy selection and conditional reflection skip LLM calls when possible, and a reflexion loop stores insights for future tasks. Junco also uses a [custom LoRA adapter](https://developer.apple.com/documentation/foundationmodels/loading-and-using-a-custom-adapter-with-foundation-models) trained on recent Swift 6.3+ permissively-licensed code, public documentation, and synthetic data.

Junco processes queries through a pipeline of independent LLM calls, each with its own context window:

```text
query → CLASSIFY → STRATEGY → PLAN → EXECUTE → REFLECT
         10ms      instant    ~2s     ~2s × N    instant
        (ML/CRF)  (determ.)  (AFM)    (AFM)    (determ.)
```

The key principle is **deterministic scaffolding around stochastic generation** — Swift code handles orchestration, error routing, tool dispatch, and validation; the on-device model only generates plans and tool parameters.

## What Makes This Work at 4K Tokens

- **Micro-conversations** — each pipeline stage sees only what it needs; no multi-turn conversation history
- **Typed tool dispatch** — the `ToolName` enum eliminates a redundant LLM call per step (the plan already specifies which tool to use)
- **Deterministic bypasses** — strategy selection and reflection are deterministic for common cases, saving 2 LLM calls per task
- **Priority-weighted prompt packing** — when context is tight, `PromptSection` priorities ensure file content wins over reflections and hints
- **`@Generable` structured output** — compile-time type safety via Apple's Foundation Models framework, zero parsing overhead
- **`validateAndFix` loop** — generated code is linted, validated (via `swiftc -parse`), and retried with targeted error regions when needed
- **Typed errors** — `PipelineError` and `StepOutcome` enums enable error-specific recovery (auto-retry on deserialization failure, truncate on context overflow)
- **Two-phase code generation** — large Swift files are generated as skeleton + per-method bodies, each in a separate context window

## Research Mode

When queries contain URLs or need external context for disambiguation, Junco automatically enters Research Mode:

- **URL auto-fetch** — URLs in the query are fetched, HTML-stripped, boilerplate-filtered, and compacted to ~400 tokens
- **Web search** — ambiguous queries trigger a DuckDuckGo Instant Answer search (no API key, no auth)
- **Aggressive compaction** — strips navigation, cookie banners, sign-in prompts; collapses whitespace; budget-splits across multiple sources

Research Mode is agent-internal — it runs automatically when needed, not as a user command.

## Layers

| Layer | Purpose |
| --- | --- |
| **Agent** | Pipeline orchestration, session management, reflexion, research, skills |
| **Models** | `@Generable` structured types, token budget, `ToolName`/`StepOutcome`/`PipelineError` enums |
| **LLM** | Adapter pattern (AFM with optional LoRA adapter) |
| **Tools** | Sandboxed shell, validated file ops, template rendering, diff preview, FSEvents |
| **RAG** | Regex-based Swift symbol indexer, BM25 context packing |
| **TUI** | ANSI output with piped fallback, syntax highlighting, markdown rendering |

## Key Design Decisions

- **Micro-conversations over long context** — AFM has ~4K tokens. Each pipeline stage sees only what it needs.
- **Deterministic scaffolding** — the model makes one decision per call; Swift code handles orchestration, tool dispatch, validation, and error recovery.
- **ML for classification** — CRF model trained on 9.5K examples replaces one LLM call per task.
- **Reflexion loop** — post-task reflections stored in `.junco/reflections.jsonl`, retrieved by keyword match for future similar tasks. Clean successes skip the LLM reflect call entirely.
- **MicroSkills** — token-capped prompt modifiers (e.g., "swift-test" forces Swift Testing patterns, "explain-only" disables write tools).
- **Template rendering** — structured file formats (entitlements, Package.swift, Info.plist, .xcprivacy, .gitignore, .xcconfig) use `@Generable` intent types + deterministic renderers, guaranteeing valid syntax.
