# clmux-pipeline

Tmux + iTerm session lifecycle for clau-mux. Creates sessions with automatic
iTerm window pairing, and shuts them down gracefully without closing unrelated
windows.

## Why — the safety rule

During a prior session, a cleanup script used AppleScript to scan iTerm
sessions by reading their `contents of session` (scrollback text), then closed
any window whose text matched the pattern `orch-*`. Because scrollback text is
shared across the entire pane history, this grep matched Claude Code panes that
happened to contain the pattern in their output — even though those panes
belonged to completely unrelated sessions. The result was that unrelated iTerm
windows were silently closed, losing work.

The pipeline was designed with one hard rule to prevent this class of failure:
**iTerm windows are identified and closed by their numeric window-id only.**
When a session is created with an iTerm window, the integer window-id is stored
as a tmux user-option (`@iterm_window_id`) on the session. Shutdown reads that
id and issues `close (first window whose id is WID)` — a lookup by identity,
not by content or name pattern.

The second invariant is graceful-first shutdown. Rather than immediately calling
`tmux kill-session`, the pipeline sends appropriate termination signals to each
pane's foreground process (Claude Code gets `/exit`, shells get `exit`, anything
else gets `C-d`), waits for the session to exit naturally, and only falls back
to force-kill after the configured timeout. This preserves in-progress state and
gives long-running processes a chance to flush and exit cleanly. Shutdown of one
session never touches another session.

## Usage

### Create a session

```
clmux-pipeline create <name> [--headless] [--cwd <path>] [--tag <tag>]
```

Creates a new tmux session named `<name>`. Without `--headless`, also opens a
new iTerm window attached to the session and stores its window-id.

Flags:

- `--headless` — skip iTerm window creation (useful for CI or background sessions)
- `--cwd <path>` — set the session's working directory (default: current directory)
- `--tag <tag>` — attach a label stored as `@pipeline_tag`; used by `shutdown-tagged`

Example:

```
clmux-pipeline create orch-test --tag orch --cwd ~/projects/foo
clmux-pipeline create ci-runner --headless
```

Session names containing `:` or `.` are rejected. See "Name validation" below.

### List / inspect

```
clmux-pipeline list
clmux-pipeline list --tag <filter>
clmux-pipeline info <name>
```

`list` prints a table with columns: NAME, PANE, WINDOW_ID, TAG, UPTIME.
`--tag <filter>` restricts output to sessions whose `@pipeline_tag` matches
the filter string exactly.

`info` prints a detailed dump of a single session: all tmux user-options,
pane layout, and the current foreground process in each pane.

### Shutdown

```
clmux-pipeline shutdown <name> [--timeout <sec>] [--force] [--dry-run]
clmux-pipeline shutdown-tagged <tag> [--timeout <sec>]
clmux-pipeline kill <name>
```

`shutdown` performs a graceful-first teardown of one session:

1. Sends `/exit` to panes running `claude` or `node`.
2. Sends `exit` to panes running `zsh`, `bash`, `fish`, or `sh`.
3. Sends `C-d` to all other panes.
4. Waits up to `--timeout` seconds (default: 10) for the session to disappear.
5. If still alive after timeout: sends `C-c`, waits 2 s, then calls
   `tmux kill-session` and exits with code 2.
6. If an iTerm window was stored, closes it via `id of window`.

`--force` skips steps 1-4 and goes directly to `tmux kill-session`. Exit code is 0.

`--dry-run` prints what would happen without making any changes. Example output:

```
[dry-run] would send /exit to pane orch-test:0.0 (claude)
[dry-run] would send exit to pane orch-test:0.1 (zsh)
[dry-run] would close iTerm window id 42
```

`shutdown-tagged <tag>` iterates over all sessions with matching `@pipeline_tag`
and calls graceful shutdown on each. Use `--timeout` to control per-session wait.

`kill <name>` is an alias for `shutdown <name> --force`.

Exit codes:

| Code | Meaning |
|------|---------|
| 0    | Session shut down gracefully (or force-kill succeeded) |
| 2    | Graceful timeout expired; fell back to `tmux kill-session` |
| 3    | Session exited but iTerm window close failed |

## How it works (architecture)

- **Tmux user-options** store all pipeline metadata on the session itself —
  no external state files. Options: `@iterm_window_id` (integer or empty),
  `@pipeline_tag` (string or empty), `@pipeline_created_at` (Unix timestamp).
- **Graceful signals by process name**: `claude`/`node` receive the `/exit`
  command typed into the pane; `zsh`/`bash`/`fish`/`sh` receive `exit`;
  all other foreground processes receive `C-d` (EOF).
- **Timeout fallback**: after waiting up to `--timeout` seconds the script
  checks `tmux has-session`. If the session persists, it sends `C-c` to all
  panes, waits 2 s, then calls `tmux kill-session` and returns exit code 2.
- **iTerm close** uses the AppleScript form
  `close (first window whose id is WID)` where WID is the integer stored in
  `@iterm_window_id`. This is an exact identity lookup — no text or name
  matching is involved at any point.
- **Per-session independence**: `shutdown` and `kill` operate only on the named
  session. `shutdown-tagged` iterates by tag but still shuts each session down
  individually. No cross-session side-effects.

## Name validation

Session names containing `:` or `.` are rejected at create time. The reason is
that tmux's `-t` flag interprets those characters as target syntax:
`session:window.pane`. A session named `foo:0` would cause subsequent `tmux`
invocations using `-t foo:0` to silently target window 0 of session `foo`
instead of the session itself, leading to subtle misdirected commands. Rejecting
these characters at creation prevents the ambiguity entirely.

## Safety invariants — summary

1. iTerm close uses `id of window` (integer) only — never text or name pattern matching.
2. `tmux kill-session` runs only from `--force` or post-timeout fallback.
3. Session and window id are stored in tmux user-options, not external files.
4. Shutdown of session A never touches session B.
5. Session names with `:` or `.` are rejected at create time.

## See also

- `scripts/clmux_pipeline.sh` — implementation (~453 lines)
- `tests/test_clmux_pipeline.sh` — 13 integration tests including safety regression (T12)
- `CHANGELOG.md` — 1.3.2 entry with full feature summary
