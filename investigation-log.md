# Issue #17 Investigation Log

**Goal:** Determine whether Claude Code's `TeamCreate` on an existing team wipes/rebuilds the team directory, and whether that rebuild caused the `FileNotFoundError: .../inboxes/team-lead.json.lock.d` observed in `fe-debug-pipeline` bridges.

**Branch:** `investigate/issue-17-teamcreate-rebuild`
**Claude Code version under test:** `2.1.109`
**Evidence session:** `12bc1b46-b2b0-4d31-abfd-681fab08deb6` (Claude Code `2.1.108`)

## Summary (TL;DR)

1. **Re-TeamCreate behavior changed between `2.1.108` and `2.1.109`.**
   - `2.1.108`: second `TeamCreate(same_name)` silently **succeeded**, rewrote `config.json`, and re-populated `members[]`. The `fe-debug-pipeline` jsonl shows both calls returning the same success payload.
   - `2.1.109`: second `TeamCreate(same_name)` is **rejected** with `Team "<name>" already exists at .../config.json. Choose a different team_name, or run TeamDelete on the existing team first.`
   - Detection is **by `config.json` presence**, not by dir presence (a dir without `config.json` is treated as "not a team" and TeamCreate proceeds).
2. **Even in the 2.1.108 "silent overwrite" path, `inboxes/` was NOT wiped.**
   - Evidence: `fe-debug-pipeline/inboxes/team-lead.json` retained its 42 KB backlog of messages timestamped 03:43-03:45 across the 04:08:34 second `TeamCreate`. Deep research also confirmed bridge `%103` (gemini-challenger) subsequently processed those messages.
3. **`FileNotFoundError` root cause remains inconclusive.** No experiment on `2.1.109` reproduces a transient `inboxes/` removal. The upstream version bump eliminates the resumable-re-TeamCreate vector, so the practical exposure is gone regardless. PR #15 + PR #18 already add the defense-in-depth the bridge needs when `inboxes/` is absent for any other reason (manual `rm`, future upstream changes, `TeamDelete` race).
4. **H1-H4 verdict:**
   - H1 (wipe+rebuild) — REJECTED. `inboxes/` dir-inode and `inboxes/*.json` inodes are preserved across a successful TeamCreate.
   - H2 (preserve + overwrite config) — **CONFIRMED**. `config.json` is rewritten fresh (new inode, fresh `createdAt`, members list reset to only the team-lead); `inboxes/` and all clmux side files (`.*-pane`, `.*-bridge.pid`, `.bridge-*.env`, `.custom-marker`, etc.) are preserved byte-for-byte (except as noted in H4).
   - H3 (no-op) — REJECTED. `config.json` is definitely (re)written. A side effect also mutates `inboxes/team-lead.json` (see below).
   - H4 (partial rebuild race) — **PARTIAL CONFIRMATION** with a surprise. TeamCreate does modify `inboxes/team-lead.json` in-place (truncate+write, same inode) **approximately 1 second after** writing `config.json`. On inspection the modification was to mark all pre-existing messages `"read": true`. This is not `inboxes/` removal, but it is a non-obvious state mutation. A bridge that reads `team-lead.json` during the ~1 s window between config rewrite and mark-read is reading stale data.

## Recommendation

Close Issue #17 as **resolved upstream** (Claude Code 2.1.109 blocks the re-creation path) with the following caveats documented:

- Keep the defense-in-depth in PR #15/#18 (they remain correct for `TeamDelete`, manual `rm`, or future regressions).
- Optionally add a user-facing CLAUDE.md note that re-calling `TeamCreate` on the same name will now error, so users must explicitly `TeamDelete` first if they want to reset state.
- No further action required on the `FileNotFoundError` specifically — version fix eliminates the reproduction vector.

---

## Method

All experiments ran on Claude Code `2.1.109` from session `bb681531-50c9-4fd4-9bb8-abe6ac2b9064`.

Files:
- `/tmp/issue-17/poll_team_dir.py` — polls the team dir at 20 ms intervals, recording mutations by (inode, mtime_ns, size) triple.
- `/tmp/issue-17/poll_b3.jsonl` — capture from the successful TeamCreate-with-missing-config experiment.

### Experiment A — Second `TeamCreate` from the leader session

1. `TeamCreate(team_name="expt-17-a")` → success. Dir created with only `config.json` (NO `inboxes/` — the directory is *not* created by Claude Code; `clmux.zsh:_clmux_ensure_team` and bridges create it lazily).
2. Seeded `inboxes/` manually with recognizable markers.
3. Tampered `leadSessionId` inside `config.json` to a fake UUID.
4. Called `TeamCreate(team_name="expt-17-a")` again **from the same session that is currently leading**.

   **Result:** `Already leading team "expt-17-a". A leader can only manage one team at a time. Use TeamDelete to end the current team before creating a new one.`

   The "already leading" check is **in-memory**, not based on `config.json`.
5. Also tested: external `rm -rf` of the team dir (via absolute path) did **not** clear the in-memory leader state. `TeamCreate` still rejected.

### Experiment B — Simulating the `fe-debug-pipeline` "resumed session" scenario

The session-level "already leading" guard cannot be cleared from within a single session without `TeamDelete`. Instead I simulated the critical post-`/exit` state by:

1. `TeamCreate(team_name="expt-17-b")` → success.
2. `TeamDelete` → clears my session's leader state AND removes the dir.
3. Hand-reseed the dir tree (`config.json`, `inboxes/`, `inboxes/*.json`, side markers) to mimic the state of `fe-debug-pipeline` as it would have looked after `/exit` but before resumption.
4. `TeamCreate(team_name="expt-17-b")` with a pre-existing **valid-JSON** `config.json`:

   **Result:** `Team "expt-17-b" already exists at /Users/idongju/.claude/teams/expt-17-b/config.json. Choose a different team_name, or run TeamDelete on the existing team first.`

5. Removed only `config.json`, kept `inboxes/` and side markers, repolled, called `TeamCreate(team_name="expt-17-b")`:

   **Result:** SUCCESS. Tool-result payload is identical to a first-time creation:
   ```json
   {"team_name":"expt-17-b","team_file_path":".../config.json","lead_agent_id":"team-lead@expt-17-b"}
   ```

### Observation (Experiment B step 5) — the 20 ms poll

| t (ms from start) | Event |
|---|---|
| 0 | baseline: `inboxes/`, `inboxes/team-lead.json` (size 70), `inboxes/gemini-ghost.json` (size 41), `.custom-marker`, `.gemini-ghost-bridge.pid` present. NO `config.json`. |
| 476 | `config.json` **created** (new inode 75530685, 554 bytes). Root dir mtime updated. **No other file touched.** |
| 1491 | `inboxes/` dir mtime bumped. `inboxes/team-lead.json` **modified in-place** (same inode 75529487, size 70 → 106). All other files still intact. |

Diff of `inboxes/team-lead.json`:
```diff
-[{"marker":"PRE-SECOND-TeamCreate","text":"42KB-equivalent backlog"}]
+[{"marker": "PRE-SECOND-TeamCreate", "text": "42KB-equivalent backlog", "read": true}]
```

So `TeamCreate` on a pre-existing `inboxes/team-lead.json` **marks every existing message as read**. It does **not** remove, move, or re-create the file or its parent directory.

Preserved byte-for-byte:
- `inboxes/gemini-ghost.json` (inode + mtime unchanged)
- `.custom-marker` (inode + mtime unchanged)
- `.gemini-ghost-bridge.pid` (inode + mtime unchanged)
- `inboxes/` directory inode (no `rmdir`+`mkdir` cycle)

### Cross-check against `fe-debug-pipeline` historical evidence

From `~/.claude/teams/fe-debug-pipeline/config.json` after-the-fact snapshot:

| Field | Value | Interpretation |
|---|---|---|
| `createdAt` | `1776226114827` | Matches second TeamCreate (2026-04-15T04:08:34.819Z = 1776226114819 ms) to within **8 ms**. Confirms `config.json` is freshly written on the second call. |
| `members[0].joinedAt` | `1776226114827` | Same timestamp as `createdAt` — team-lead joined at rebuild time, not original 03:35:41 creation. |
| `members[1..4].joinedAt` | `1776226121114` … `1776226129640` | **6-15 seconds AFTER** second TeamCreate. These are re-spawned teammates (via the `Agent` tool) appending to the freshly-rewritten `members[]`. |
| `members[1].prompt` | "…현재 상태: 팀이 막 재구성되었습니다…" | Independent confirmation by the team lead itself that the team was "just reconstructed." |

The `fe-debug-pipeline/inboxes/team-lead.json` is 42 644 bytes with mtime 2026-04-15T13:30 — long after the second TeamCreate at 04:08 — and contains the 03:43-03:45 backlog that bridge `%103` processed post-rebuild. So the backlog survived.

### The `/exit` hop: why 2.1.108 allowed re-TeamCreate

Between the two TeamCreate calls in session `12bc1b46`:

- `[03:45:53]` user interrupted
- `[03:48:58]` `away_summary` (session idle)
- `[04:02:38]` user typed `/exit` → session 12bc1b46 **terminated**
- `[04:02:38 – 04:07:41]` 5-minute gap
- `[04:07:41]` **session 12bc1b46 resumed** (same sessionId, so the user used `claude -r` or equivalent). First event after resume shows `teamName=<missing>` — the leader context was **not** reconstituted in-memory.
- `[04:08:34]` second `TeamCreate` → succeeded.

So in `2.1.108` the contract was effectively: "a resumed session that is no longer holding leader state may re-TeamCreate and silently overwrite the `config.json`." `2.1.109` promoted this implicit behavior to an explicit "already exists" error, forcing the user to `TeamDelete` first.

## What caused the `FileNotFoundError`?

**Best current theory (inconclusive):** Not reproducible from any experiment I ran on 2.1.109. The 2.1.108 TeamCreate-rebuild path, as evidenced by `fe-debug-pipeline`'s surviving 42 KB backlog, did **not** wipe `inboxes/`. So the transient absence at notify_shutdown time likely came from some other actor:

- A candidate during the 14 min `/exit` gap, where the user may have manually cleaned `~/.claude/teams/<fallen>/inboxes/` and forgotten.
- A candidate is the interaction between simultaneous Agent-tool spawns that each call the Node MCP bridge, racing against a concurrent pane-gone cleanup.
- A bug in 2.1.108 that is not covered by any of my experiments and has since been removed.

Given that PR #15 and PR #18 already add defense-in-depth that handles this path gracefully (degrade to `exit 0` with a stderr note rather than crash), the issue is operationally contained.

## Cleanup

- `expt-17-a`, `expt-17-b` deleted via `TeamDelete`. Confirmed via `ls ~/.claude/teams/` that no `expt-17-*` residue remains.
- Other teams in `~/.claude/teams/` (`clau-mux-final-verify`, `fe-debug-pipeline`, etc.) untouched.

## Notable side-finding

TeamCreate does **not** create `inboxes/` — that directory is created lazily by `clmux.zsh:_clmux_ensure_team` (line 12) and by the inbox-writer paths in `bridge-mcp-server.js`. This means a team with zero teammates has no `inboxes/` directory at all; the first spawn creates it. Any bridge or cleanup script that assumes `inboxes/` always exists alongside `config.json` is relying on an implementation-detail convention, not a Claude Code guarantee — which is exactly why the defensive `os.makedirs(parent, exist_ok=True)` added in PR #15 is structurally correct.
