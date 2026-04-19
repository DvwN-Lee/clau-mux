# Family v2 — Manual Smoke Test

**Purpose**: Verify the Family pattern (1-Lead + 1-Teammate + 2-Workers) end-to-end in a real Claude Code session. Run once after PR-B merges and after any future SDK upgrade.

**Why manual?** The Family pattern uses Claude Code SDK primitives (`TeamCreate`, `Agent`, `SendMessage`) directly with no intermediate code. Validation requires a live Claude Code session and cannot be automated in CI.

**Conforms to**: `docs/superpowers/specs/2026-04-19-family-teammate-ux-requirements.md` (v2)
+ `docs/superpowers/specs/2026-04-19-family-mvp-design.md` (revision 2)

---

## 0. Prerequisites

- macOS + tmux + zsh (existing clmux deps)
- Claude Code CLI installed and authenticated
- A primary Claude Code session running (= Lead session). Lead must NOT itself be a teammate of another Lead — Family pattern requires Lead = primary session (Risk B in design doc).

---

## 1. Test scenario summary

```
Lead (you, primary)
  │
  │ 1. TeamCreate(team_name="family-smoke")
  │ 2. Agent() spawn → "smoke-mid" Teammate (sonnet)
  │
  ▼
Teammate "smoke-mid"
  │
  │ 3. Receives spawn prompt with scope:
  │    "Compute 2+3 and 4+5 by spawning 2 Workers in parallel,
  │     then report the sum to team-lead."
  │ 4. Spawns Worker A (compute 2+3) + Worker B (compute 4+5) via Agent()
  │ 5. Receives sync results from both Workers
  │ 6. Consolidates: "2+3=5, 4+5=9, total=14"
  │ 7. SendMessage(to: "team-lead", message: "<consolidated>")
  │
  ▼
Lead (you)
  │
  │ 8. Receives consolidated report as native teammate-message
  │    WITHOUT typing anything
  │ 9. Verify report content matches expectation
```

---

## 2. Step-by-step procedure

### Step 1: Create the team

In your Lead Claude session, invoke:

```
TeamCreate({
  team_name: "family-smoke",
  description: "Family v2 MVP smoke test"
})
```

**Expected**: Team created at `~/.claude/teams/family-smoke/config.json`. Lead is registered as `team-lead@family-smoke`.

### Step 2: Spawn the Teammate ("smoke-mid")

Invoke the following Agent() call — copy verbatim, replace nothing except the team name if you used a different one:

```
Agent({
  description: "family smoke-mid",
  subagent_type: "general-purpose",
  model: "sonnet",
  team_name: "family-smoke",
  name: "smoke-mid",
  run_in_background: true,
  prompt: "You are smoke-mid, a Family Teammate (Tier 2) in team `family-smoke`. Your role:\n\n1. SCOPE: Compute (2+3) and (4+5) by spawning 2 Workers (Tier 3 subagents) in parallel.\n   - Worker A: compute 2+3, return the integer.\n   - Worker B: compute 4+5, return the integer.\n2. To spawn each Worker, call the Agent tool WITHOUT team_name and WITHOUT name parameters (those are reserved for teammates and you cannot spawn teammates from your context). Use a short prompt like: 'Compute 2+3 and respond with only the integer.'\n3. After both Worker results arrive (sync, in your same turn), CONSOLIDATE: write a single line in the form 'A=<num>, B=<num>, total=<sum>'.\n4. SEND that single line to team-lead via SendMessage(to: 'team-lead', message: '<line>'). This is your only outbound message.\n5. Then go idle. Do NOT poll. Do NOT initiate further work.\n\nConstraints:\n- Do NOT call SendMessage to anyone other than 'team-lead'.\n- Do NOT spawn more than 2 Workers.\n- Do NOT use TaskCreate / TaskUpdate.\n- Acknowledge this prompt by starting your work immediately."
})
```

**Expected**:
- Agent tool returns success with `agent_id: smoke-mid@family-smoke`
- A new tmux pane is allocated for smoke-mid (visible in `tmux list-panes -a`)
- `~/.claude/teams/family-smoke/config.json` now contains a member entry for `smoke-mid` with `tmuxPaneId` set

### Step 3: Wait for Teammate's report (no input from you)

Within 30-60 seconds (depending on Worker latency), you should receive a native `teammate-message` from `smoke-mid` automatically. Format:

```
<teammate-message teammate_id="smoke-mid" ...>
A=5, B=9, total=14
</teammate-message>
```

**Expected**:
- Message arrives WITHOUT you typing anything (R1, R2, R3 of the requirements doc)
- Content matches `A=5, B=9, total=14` (or equivalent — Workers may add minor formatting)
- An idle_notification follows shortly after

### Step 4: Verify Workers were spawned and isolated (Tier 3 isolation)

Inspect the team config:

```bash
cat ~/.claude/teams/family-smoke/config.json | python3 -c "import json,sys; d=json.load(sys.stdin); print('members:', [m['name'] for m in d['members']])"
```

**Expected**: Members list contains exactly `team-lead` and `smoke-mid`. NO Worker entries (Workers are subagents, not teammates — they are not registered in `config.json` members).

This verifies AC4 (Worker isolation): the 2 Workers Teammate spawned never registered as teammates and never had a path to message Lead directly.

### Step 5: Verify reverse path used native teammate-message (not paste)

Look at the Lead conversation: the report should appear as a `<teammate-message>` block with `teammate_id="smoke-mid"`, NOT as pasted user-input text in your terminal.

This verifies AC1 + AC2 (native teammate-message UX).

### Step 6: Shut down the Teammate

```
SendMessage({
  to: "smoke-mid",
  message: { type: "shutdown_request" }
})
```

**Expected**: smoke-mid acknowledges and the pane is killed. `~/.claude/teams/family-smoke/config.json` may show smoke-mid `isActive: false`.

### Step 7: (optional) Tear down the team

```bash
rm -rf ~/.claude/teams/family-smoke
```

(Or use TeamDelete if you want — but per project rules, do not call TeamDelete unless explicitly cleaning up; team files in HOME are safe to leave.)

---

## 3. Acceptance criteria checklist

Mark each ✅ when verified during the run:

- [ ] **AC1**: Lead received `smoke-mid`'s report as native teammate-message (Step 3, Step 5)
- [ ] **AC2**: smoke-mid received spawn prompt scope without polling (implied — it began work immediately)
- [ ] **AC3**: Teammate spawned and consumed 2 Workers via `Agent()` (implied by report `total=14`)
- [ ] **AC4**: Workers did NOT appear in team config members and Lead did NOT receive any direct message from a Worker (Step 4)
- [ ] **AC5**: No polling loop in Lead or smoke-mid (no continuous activity in the pane between turns)
- [ ] **AC6**: shutdown_request gracefully terminated smoke-mid (Step 6)
- [ ] **AC7**: 1-Lead + 1-Teammate + 2-Workers E2E completed (entire scenario)

If any AC fails, STOP. Capture the failure mode (which step, what was observed vs expected) and file an issue before merging the doc PR.

---

## 4. Reusable templates

### 4.1 Generic Family Teammate spawn template

```
Agent({
  description: "<short description>",
  subagent_type: "general-purpose",
  model: "sonnet",          # or "haiku" for cheap, "opus" for hard
  team_name: "<your team>",
  name: "<unique teammate name>",
  run_in_background: true,
  prompt: "<role + scope + constraints — see template below>"
})
```

### 4.2 Generic Family Teammate spawn-prompt template

Copy this and fill `{{ }}` placeholders:

```
You are {{teammate_name}}, a Family Teammate (Tier 2) in team `{{team_name}}`.

ROLE: {{one-line role description}}

SCOPE: {{your delegated scope, multi-line OK}}

WORKERS: {{describe expected Worker fanout — N workers, each task — or "no workers, do directly"}}

CONSOLIDATION: {{how to combine Worker results}}

REPORT: When complete, SendMessage(to: 'team-lead', message: '<your consolidated result>'). This is your only outbound message.

CONSTRAINTS:
- Do NOT call SendMessage to anyone other than 'team-lead'.
- Do NOT spawn other teammates (Agent() with team_name from your context will fail — use Agent() WITHOUT team_name to spawn Workers as subagents).
- Do NOT use TaskCreate / TaskUpdate (you are a Family Teammate, not a teamlead).
- Do NOT poll inboxes.
- Begin work immediately.
```

### 4.3 Generic Worker prompt template (when Teammate spawns Workers)

```
{{focused, single-task instruction}}

Respond with only {{expected output format}}.
```

(Workers are ephemeral subagents — keep prompts minimal.)

---

## 5. Troubleshooting

| Symptom | Likely cause | Fix |
|---|---|---|
| Agent() error "team_name not found" | Forgot Step 1 | Run TeamCreate first |
| Agent() error "name already exists" | Re-running with same teammate name | Use a fresh name or `SendMessage` `shutdown_request` to old one |
| No teammate-message arrives within 60s | Teammate stuck or didn't understand prompt | `tmux list-panes -a` → find smoke-mid's pane → `tmux capture-pane -t <pane> -p -S -50` to see what it's doing |
| Workers visible in team config | Teammate ignored constraint and called Agent() with team_name | Bug in spawn prompt — clarify constraints (4.2 template handles this) |
| Lead doesn't react to teammate-message automatically | Lead is mid-turn or system issue | Wait for Lead to finish current turn — message will be queued and surfaced |
| smoke-mid spawns but never reports | Workers failed silently | Check smoke-mid's pane output for errors |

---

## 6. Cleanup after testing

```bash
# Optional — remove the team file (it's in HOME, harmless if left)
rm -rf ~/.claude/teams/family-smoke

# Kill any stale panes (if shutdown_request didn't clean up)
tmux list-panes -a -F '#{pane_id} #{pane_current_command}' | grep -i claude
# (manually kill identified panes via `tmux kill-pane -t <id>`)
```

---

## 7. When to re-run this test

Always re-run after:
- Claude Code SDK version upgrade (Agent / SendMessage / TeamCreate behavior changes)
- Changes to `clmux-bridge.zsh` or `bridge-mcp-server.js` (could affect teammate-message routing)
- Any future addition of automation to the Family pattern (e.g., wrapper functions, dedicated skill files)

If the test passes after a change, the Family pattern still works. If it fails, revert or fix the change before merging.
