# Contributing to Junco

## Development Setup

```bash
git clone https://github.com/LastByteLLC/junco.git
cd junco
swift build
swift test
```

Requires macOS 26+ with Apple Intelligence enabled.

## Architecture

See [README.md](README.md) for the architecture overview. Key principle: changes should target one layer at a time. The layers are independent — modifying RAG shouldn't require changes to the TUI.

# Code Style

- 2-space indentation
- 120 character line limit
- Swift Testing (`@Suite`, `@Test`, `#expect`) over XCTest
- `Sendable` conformance on all public types
- Use `Config` enum for all tunable thresholds — no magic numbers

## Adding a Tool

1. Define a `@Generable` params struct in `GenerableTypes.swift`
2. Add a case to `ToolAction` enum
3. Handle in `Orchestrator.resolveToolAction()` and `executeTool()`
4. Add tests

## Adding a MicroSkill

Add to `builtinSkills` in `MicroSkills.swift`, or create a `MicroSkills.md` in your project:

```markdown
| Name | Domain | TaskTypes | Hint |
|------|--------|-----------|------|
| my-skill | swift | fix,refactor | Always check for retain cycles when editing delegate patterns. |
```

Skills are capped at ~200 tokens per hint.

## Adding a Domain

1. Add a case to `DomainKind` enum
2. Add a static config in `Domains` enum
3. Add detection logic in `DomainDetector.detect()`
4. Add tests in `DomainTests.swift`

## Pull Requests

- One concern per PR
- Include tests for new functionality
- Run `swift test` before submitting
- Keep commits atomic with clear messages
