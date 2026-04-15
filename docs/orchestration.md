← [README](../README.md)

# Pane Orchestration Protocol

A single-layer protocol for **hierarchical delegation** across Claude Code panes. Inspired by corporate stage-gate processes. One Master pane talks to the user; it delegates work to Sub panes (which may use their own clmux-teams internally) and validates their reports before forwarding to the user for sign-off.

> **[A2] Terminology — "Master" is the role held by the current user-facing pane.**
> The lock in `~/.claude/orchestration/master.lock.d/` is *singular globally* (only one Master may exist at a time on this machine). This Master may be the Desktop-level top pane, a Project-level main pane, or any pane — the protocol doesn't care about hierarchy depth. The **Corporate Hierarchy Pattern** (below) is a *recommendation* for how teams typically organize Masters in nested worktrees; the protocol itself enforces only global singularity. See [A3] for the recommended pattern and transfer flow.

## Roles

| Role | Responsibility | Enforcement |
|---|---|---|
| **User** | final approval | (external) |
| **Master** | strategy, meeting synthesis, quality gate, user-facing summary | **single pane only, globally** (`master.lock.d`) |
| **Sub** | execution, may spawn sub-subs, may consult own clmux-teams | registered under a Master |
| **Meeting participants** | consultation only | existing clmux-teams protocol |

## [A3] Corporate Hierarchy Pattern (recommended org model)

The protocol enforces *one Master at a time* but doesn't prescribe *where* the Master lives. In practice we recommend the following three-tier layout, which maps cleanly onto `git worktree` isolation and clmux-teams delegation:

```
Desktop / Top-level          ← Master (pane %105)      — user-facing, highest strategic view
  └─ Project "clau-mux"/     ← Sub (pane %128)         — labeled "clau-mux-main"
       └─ Worktree "feat-x"/ ← Sub-Sub / "Squad" (%200) — labeled "clau-mux-feat-x"
       └─ Worktree "feat-y"/ ← Sub-Sub / "Squad" (%240)
  └─ Project "other-repo"/   ← Sub (pane %160)
```

> **[v3 per 2026-04-15 cross-review] `--project-root` deferred to Phase 2.**
> An earlier draft carried `register-sub --project-root $WORKTREE` and stored it in `panes.json`. This field was YAGNI for Phase 1 (no query path consumed it) and has been moved to Phase 2 Roadmap ("Cross-project query filters") — until that filter exists, use the `--label` field to identify which worktree a Sub serves.

**Master transfer (handover) walk-down.** If the user moves focus to a project-level pane and wants it to become the new Master, run:

```bash
clmux-orchestrate handover --from %105 --to %128 --label clau-mux-main
```

This is an atomic swap: `%105` loses Master role, `%128` gains it, and the lock record is updated. In-flight threads delegated from `%105` remain open — the new Master can `thread --id <tid>` to review them and either `accept`/`reject` or `close` with note "handover cleanup". The former Master is **not automatically demoted to Sub** — the protocol leaves that as a user decision (the pane may be exiting entirely, or it may want to act as a Sub under the new Master with a fresh `register-sub`).

**Why this pattern.**
- A consistent labeling convention (`label=$WORKTREE_BASENAME`) lets operators distinguish at a glance which Sub serves which worktree; later Phase 2 filters can use the label prefix.
- Recursion is unbounded by design (Sub-Subs are just Subs with a `parent_thread_id`), so deeper hierarchies (org → department → squad → task-force) are representable without protocol changes.
- The global Master lock prevents two panes from *both* thinking they're the top of the hierarchy. Conflicts surface immediately instead of corrupting shared `threads/index.json`.

**When NOT to use this pattern.**
- Single-worktree short-lived sessions: just use one Master pane, skip Sub registration entirely.
- Cross-machine work: `~/.claude/orchestration/` is machine-local. Use separate Masters on separate machines; no attempt at distributed consensus.
- Long-running parallel workflows on unrelated projects — the global Master lock will serialize you; consider two OS users or two machines. (Phase 2 Roadmap "Master per tmux session" will address this.)

## Directory layout

```
~/.claude/orchestration/
├── master.lock.d/           # who is Master right now
├── meeting.lock.d/          # only one meeting may be active
├── panes.json               # registry {pane: role, master, label}
├── threads/<id>.jsonl       # append-only audit, one envelope per line
├── threads/index.json       # {thread_id: {state, delegator, assignee, parent, ts}}
├── meetings/<id>/           # WORM archive (chmod 444 on archive)
├── inbox/<pane>.jsonl       # pending alerts per pane
├── inbox_archive/<pane>.jsonl
└── state/<pane>.json        # resume snapshot
```

## Envelope kinds

| kind | direction | required body | optional body |
|---|---|---|---|
| `thread_meta` | — | parent_thread_id, delegator, root | — |
| `delegate` | Master → Sub | scope, success_criteria | non_goals, deliverable, urgency, resources[], consultations[] |
| `ack` | Sub → Master | — | note |
| `progress` | Sub → Master | status | note |
| `report` | Sub → Master | summary, evidence[] | decisions_made[], open_questions[], risks[], consultations[] |
| `accept` | Master → Sub | — | note |
| `reject` | Master → Sub | feedback | required_changes[] |
| `blocked` | Sub → Master | question | options[], urgency |
| `reply` | Master → Sub | answer | note |

Phase 2 additions (not yet implemented): `progress_heartbeat`, `reply.unblock_to` (currently always returns to IN_PROGRESS).

## State machine

```
CREATED
  │
  └─ack─► IN_PROGRESS ─progress─► IN_PROGRESS
              │   │
              │   ├─report─► REPORTED ─accept─► ACCEPTED ─close─► CLOSED
              │   │                 └─reject─► IN_PROGRESS
              │   │
              │   └─blocked─► BLOCKED ─reply─► IN_PROGRESS
              │
              └── (ACCEPTED and CLOSED are terminal)
```

Illegal transitions raise `TransitionError`. The envelope is appended to the audit log *before* the transition attempt (H1 ordering), so forensics can inspect rejected transitions.

## Workflow

1. **User talks to Master.** Master claims the lock:
   ```bash
   clmux-orchestrate set-master --pane "$TMUX_PANE" --label main
   ```
2. **Optional meeting.** Master calls in teammates for consultation:
   ```bash
   # Create a clmux team manually (or via skill)
   # Then mark it as an orchestration meeting:
   mid=$(clmux-orchestrate meeting start --pane "$TMUX_PANE" \
         --topic "paste strategy" --team meeting-paste-01 --json \
       | jq -r .meeting_id)
   # ... run clmux-teams protocol ...
   clmux-orchestrate meeting end --meeting-id "$mid" \
         --synthesis "Decision: pluggable paste strategy, start minimal"
   ```
   Meeting archive lives under `~/.claude/orchestration/meetings/<mid>/` and is read-only (WORM).
3. **Delegate.** Master picks a Sub pane:
   ```bash
   clmux-orchestrate register-sub --pane %128 --master %105 --label impl
   tid=$(clmux-orchestrate delegate --from %105 --to %128 \
         --scope "implement pluggable paste" \
         --criteria "gemini/codex/copilot all work + 1 strategy added" \
         --json | jq -r .thread_id)
   ```
   A single-line alert is pasted into `%128`'s pane via `tmux paste-buffer -p`.
4. **Sub acknowledges and executes.** Sub uses its own clmux-teams for implementation if needed.
   ```bash
   clmux-orchestrate ack --thread $tid --from %128 --to %105
   # ... do the work ...
   clmux-orchestrate report --thread $tid --from %128 --to %105 \
         --summary "pluggable interface added" \
         --evidence "PR #99" --evidence "tests pass"
   ```
5. **Master reviews.** Accept or reject:
   ```bash
   # Accept:
   clmux-orchestrate accept --thread $tid --from %105 --to %128
   # Or reject with feedback (returns to IN_PROGRESS):
   clmux-orchestrate reject --thread $tid --from %105 --to %128 \
         --feedback "codex strategy missing"
   ```
6. **User sign-off.** Master summarizes for user, who approves verbally. Master closes:
   ```bash
   clmux-orchestrate close --thread $tid --note "user approved"
   ```

### Optional: Sub asks for clarification (`blocked` / `reply`)

If Sub needs a decision from Master before it can continue, it posts a `blocked` envelope. Thread state moves `IN_PROGRESS → BLOCKED` and Master gets an inbox alert. When Master answers with `reply`, state returns `BLOCKED → IN_PROGRESS`.

```bash
# Sub hit a fork in the road:
clmux-orchestrate blocked --thread $tid --from %128 --to %105 \
      --question "PostgreSQL vs MySQL?" \
      --options pg --options mysql \
      --urgency normal

# Master decides:
clmux-orchestrate reply --thread $tid --from %105 --to %128 \
      --answer "PostgreSQL" \
      --note "regulatory reasons"
```

Only legal from `IN_PROGRESS`; attempting to `blocked` from CREATED or `reply` from a non-BLOCKED state raises `TransitionError`. Audit: the blocked / reply envelopes appear in `threads/<tid>.jsonl` alongside delegate / ack / progress / report.

## Runtime silencing

Set `CLMUX_ORCH_NO_NOTIFY=1` to suppress all `notify_pane` paste output. Useful for:

- **Headless / demo recording** — no paste-buffer side effects while screencasting.
- **Operator silencing** — transiently mute pane notifications without tearing down the orchestration state.
- **Automated scripts** — when a driver script issues many `delegate` / `report` / `reply` calls in a loop, pasting a `# orch:` comment into every pane becomes noise.

This flag only affects the **paste notification**. Inbox JSONL records and thread state transitions proceed normally; nothing is lost. `clmux-orchestrate inbox --pane <pane>` still returns the pending alerts, so operators can pull them on demand.

Implementation note: `notify_pane()` short-circuits before invoking `tmux paste-buffer` when this env var is set. The test harness (`TestCLI._run`) sets it unconditionally so unit tests never touch the operator's live panes.

## Resume

If a pane dies, anyone can recover its in-flight state:

```bash
clmux-orchestrate resume --pane %128
```

This reads `panes.json`, filters `threads/index.json` for threads where `%128` is delegator or assignee AND state is not CLOSED/ACCEPTED, and persists a snapshot at `state/%128.json`.

## Sub recursion

A Sub may delegate to its own Sub by using `--parent <parent_thread_id>`:

```bash
clmux-orchestrate delegate --from %128 --to %200 \
      --scope "deeper investigation" \
      --criteria "root cause identified" \
      --parent t-abc --json
```

The new thread's `thread_meta` records `parent_thread_id: t-abc` — use `thread --id <root>` and traverse the index to reconstruct the tree.

## RACI mapping

| Activity | Responsible | Accountable | Consulted | Informed |
|---|---|---|---|---|
| Execution | Sub | Master | Meeting participants | User |
| Decision | Master | Master | Meeting participants | User |
| Approval | User | User | Master | — |
| Audit | (automated) | Master | — | User |

## [M4] WORM semantics — reality check

The meeting archive is **advisory read-only**, not tamper-proof.

- `chmod 0o444` prevents *accidental* overwrite by the orchestration process and most interactive shell commands. It is the appropriate hygiene level for a dev-machine audit log.
- **It does NOT prevent:** a determined user from running `chmod u+w` + overwrite, `rm -rf`, or editing files with tools that ignore permission bits (e.g., root, `sudo`, cross-filesystem move). On macOS, `chflags uchg` could harden this further but is not part of Phase 1.
- **It does NOT prevent** the archive from disappearing if `~/.claude/` is wiped, the disk dies, or a user manually deletes the directory.
- Treat the archive the way you'd treat `.git/logs/HEAD` — a local audit trail useful for reconstruction, not a compliance artifact.

If stronger guarantees are needed in Phase 2, options include: (1) signed content hashes in `threads/index.json`, (2) git-commit the archive to a tracked docs branch, (3) forward to an external append-only store (e.g., an S3 bucket with object lock). Phase 1 ships just advisory chmod.

## Known limitations

- **No automatic meeting audit CLI.** The archive is persistent and readable, but there's no `clmux-orchestrate meetings list/show` yet. Inspect with `ls ~/.claude/orchestration/meetings/` and `cat <id>/synthesis.md`.
- **No cascade cancel.** A rejected parent thread does NOT auto-cancel child threads; Sub should handle that manually if needed.
- **Master stale detection is manual.** If a Master pane dies without releasing, another pane can't automatically take over. Recovery path: `clmux-orchestrate release-master --pane <dead> --force` (a crash-recovery flag added in Phase 1 v2 for exactly this case).
- **Meeting lock stuck after crash.** Same failure mode for meetings. Recovery: `clmux-orchestrate meeting release --meeting-id <id> --force`.
- **Tmux paste-buffer is best-effort.** If tmux is unavailable, `notify_pane` silently returns False; the alert is still recorded in `inbox/<pane>.jsonl` and can be pulled with `clmux-orchestrate inbox --pane <pane>`.
- **Mid-delegate crash — alert paste not retried.** If Master crashes between JSONL durability and tmux paste, the inbox record exists but the Sub pane never flashed. `resume_pane` surfaces the pending alert, but a human must inspect it. Phase 2: auto-replay unpasted alerts on resume.
- **No schema versioning.** Envelopes don't carry a `schema_version`. Adding new required body fields will break validation of old records on replay. Phase 2: add `version` field and compat shim.
- **Cross-project / cross-machine** — `~/.claude/orchestration/` is global to one machine and one HOME. No distributed coordination.
- **Single Master globally.** This is by design (prevents split-brain). If you need two concurrent Masters for two independent workflows, run them under two OS users (two HOMEs) or on two machines.
