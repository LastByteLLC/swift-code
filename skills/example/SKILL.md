---
name: example
description: An example skill demonstrating the skill file format
---

This is a sample skill file. Skills are stored in `skills/{name}/SKILL.md` and
provide specialized knowledge that the agent can load on demand via the
`load_skill` tool.

## Frontmatter

Each skill file starts with YAML frontmatter between `---` delimiters:

- `name` (optional): defaults to the parent directory name
- `description` (required): one-line summary shown in the system prompt

## Usage

The agent sees skill names and descriptions in its system prompt. When it needs
the full content, it calls `load_skill` with the skill name. The body below the
frontmatter is returned wrapped in `<skill>` tags.
