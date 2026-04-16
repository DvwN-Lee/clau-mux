#!/usr/bin/env bash
# Re-installs prompt/ contents into bridge teammate user-config files.
# Run after `git pull` brings prompt/ changes — setup.sh is interactive
# and would re-prompt for unrelated steps (tmux config, MCP registration).
#
# Idempotent: uses <!-- clmux-protocol-start/end --> markers to update
# only the protocol section, preserving any other user content outside
# the markers.
set -euo pipefail

CLMUX_DIR="$(cd "$(dirname "$0")/.." && pwd)"

append_protocol() {
  local src="$1" dst="$2"
  [[ -f "$src" ]] || { echo "[SKIP] missing source: $src"; return 0; }
  mkdir -p "$(dirname "$dst")"
  local start_marker="<!-- clmux-protocol-start -->"
  local end_marker="<!-- clmux-protocol-end -->"
  local tmp; tmp="$(mktemp)"
  { echo "$start_marker"; cat "$src"; echo "$end_marker"; } > "$tmp"
  if [[ ! -f "$dst" ]]; then
    mv "$tmp" "$dst"
    echo "[OK]   Created $dst"
  elif grep -qF "$start_marker" "$dst"; then
    awk -v new_file="$tmp" '
      BEGIN { in_block=0 }
      /<!-- clmux-protocol-start -->/ { in_block=1 }
      !in_block { print }
      in_block && /<!-- clmux-protocol-end -->/ {
        in_block=0
        while ((getline line < new_file) > 0) print line
      }
    ' "$dst" > "${dst}.new" && mv "${dst}.new" "$dst"
    rm -f "$tmp"
    echo "[OK]   Updated $dst"
  else
    printf '\n' >> "$dst"
    cat "$tmp" >> "$dst"
    rm -f "$tmp"
    echo "[OK]   Appended to $dst"
  fi
}

append_protocol "$CLMUX_DIR/prompt/GEMINI.md"  "$HOME/.gemini/GEMINI.md"
append_protocol "$CLMUX_DIR/prompt/AGENTS.md"  "$HOME/.codex/instructions.md"
append_protocol "$CLMUX_DIR/prompt/COPILOT.md" "$HOME/.copilot/instructions.md"

echo "Done. Restart any running bridge teammates to pick up new prompts."
