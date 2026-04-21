---
name: continuous-learning-v2
description: "Hook-driven background system that captures Claude Code tool-use events and analyzes them to detect behavioral patterns, then persists those patterns as instincts. Activates automatically via PreToolUse/PostToolUse hooks — not invoked by user commands."
user-invocable: false
metadata:
  author: clmux
  version: "2.0"
---

# continuous-learning-v2

A hook-driven observability and pattern-learning system for Claude Code. It records every tool-use event from interactive sessions, then analyzes the accumulated observations to extract recurring patterns (user corrections, error resolutions, repeated workflows, tool preferences) and writes them as structured instincts that can influence future sessions.

## Activation

This system is **not user-invocable**. It activates through Claude Code hooks:

- `observe.sh` fires on `PreToolUse` / `PostToolUse` hook events (registered via `hooks/hooks.json` or manually via `~/.claude/settings.json`).
- The hook only records events from **interactive CLI sessions** (`CLAUDE_CODE_ENTRYPOINT=cli`). Subagent sessions, minimal hook profiles (`ECC_HOOK_PROFILE=minimal`), and sessions setting `ECC_SKIP_OBSERVE=1` are all skipped automatically.
- The Observer agent (`agents/observer.md`) is run separately — either after 20 observations accumulate, on a 5-minute interval, or on-demand via `SIGUSR1`.
- `instinct-cli.py` is a manual CLI tool for managing the resulting instincts (status, import, export, evolve, promote, projects).

## Components

| File | Role |
|---|---|
| `agents/observer.md` | Haiku-powered background agent that reads observation events and writes project-scoped or global instincts |
| `hooks/observe.sh` | PostToolUse/PreToolUse hook that captures raw tool events to `~/.claude/homunculus/projects/<hash>/observations.jsonl` |
| `scripts/instinct-cli.py` | CLI for inspecting, importing, exporting, promoting, and evolving instincts across project and global scopes |

## Integration with clmux

The system is self-contained and does not depend on clmux-phase or clmux-teams. It writes observation data to `~/.claude/homunculus/` (project-scoped by git-hash). The `skills-audit/scan.sh` script auto-loads `problems.jsonl` from the same homunculus project directory when available.

## Notes

- Instincts are scoped to individual projects by default (`scope: project`); universal patterns can be promoted to global scope via `instinct-cli.py promote` once confidence ≥ 0.8 across ≥ 2 projects.
- The observer uses Haiku for cost efficiency.
- No integration with external skills or clmux orchestration is documented in the current files.
