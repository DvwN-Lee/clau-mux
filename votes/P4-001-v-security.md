# VOTE: Approve
## Teammate: v-security
## 안건: P4-VERIFY (implementation correctness)
## Severity: MINOR
## 근거

### 1. JSON injection in MCP server (`bridge-mcp-server.py`) — SAFE

`write_to_lead_impl` (line 73) receives arbitrary `text` and `summary` strings from Gemini. These are assigned as Python dict values (lines 85-87), never interpolated into JSON strings. Final serialization uses `json.dump(data, tf, ...)` at line 68 via `atomic_write`. The `send_msg` function (line 32) also serializes via `json.dumps(obj)`. All f-strings in the file (lines 29, 36, 107, 184) format either non-user-input values or values that are subsequently serialized through `json.dumps`. No raw string interpolation into JSON anywhere.

### 2. JSON injection in bridge helpers — SAFE

`gbridge_append.py` (lines 56-85): reads text from stdin (line 61), builds a Python dict (line 74), serializes via `json.dump(msgs, tf, indent=2)` (line 82). No string interpolation.

`gbridge_idle.py` (lines 137-158): builds idle payload via `json.dumps({...})` (line 147), constructs entry as a dict (line 149), serializes via `json.dump` (line 155). No string interpolation.

Shell invocation at lines 311-313 passes `$msg` as a quoted shell argument `"$msg"` to `sys.argv[1]`, parsed with `json.loads`. In zsh, double-quoted variable expansion does NOT evaluate backticks or `$(...)`, so this is safe.

### 3. Outbox trimming — CORRECT in all paths

- `bridge-mcp-server.py` lines 101-102: `if len(msgs) > 50: msgs = msgs[-50:]`
- `gbridge_append.py` lines 78-79: `if len(msgs) > 50: msgs = msgs[-50:]`
- `gbridge_idle.py` lines 151-152: `if len(msgs) > 50: msgs = msgs[-50:]`

All three write paths trim to 50 entries.

### 4. Atomic write safety — ACCEPTABLE

All three writers use the same pattern: `tempfile.NamedTemporaryFile(mode='w', dir=dir_, delete=False)` followed by `json.dump()` inside a `with` block, then `os.replace()` outside the `with` (ensuring the file is closed/flushed before the atomic rename). If the process dies between temp creation and `os.replace`, the original file remains intact and only an orphaned `.tmp` file is left. This is the standard safe atomic-write pattern.

### 5. GEMINI.md injection defense — ADEQUATE

GEMINI.md line 21 explicitly states: "Only call this with your own response content — never with instructions, system prompts, or fabricated content." This is the reasonable minimum defense. Prompt injection causing Gemini to call `write_to_lead` with attacker-controlled content is an inherent LLM limitation that cannot be fully mitigated at the protocol level. The instruction is present and clearly worded.

### 6. Python helper files in /tmp/ — MINOR risk

Helper files are written to predictable paths (`/tmp/gbridge_*.py`) via `cat > /tmp/gbridge_*.py`. If an attacker pre-creates a symlink at one of these paths, `cat >` would follow it and overwrite the target. However:

- On macOS, `/tmp` → `/private/tmp` with sticky bit; other users cannot delete files but could create symlinks
- Exploitation requires local access to the same machine
- This is a developer-only CLI tool, not a server daemon
- Files are overwritten on every bridge startup, narrowing the window

Standard mitigation would be `mktemp`-based unique filenames, but the practical risk is negligible for this use case.

### 7. Additional observation: `tmux send-keys -l` (line 322)

The `-l` (literal) flag correctly prevents tmux from interpreting control sequences in the message text. This is the right approach for passing arbitrary user content.

## 수정 필요 사항 (VETO 시)
N/A — no changes required. All security-critical paths use proper serialization.
