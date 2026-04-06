#!/usr/bin/env bash
set -euo pipefail

CLMUX_DIR="$(cd "$(dirname "$0")/.." && pwd)"

usage() {
  cat <<EOF
Usage: bash scripts/remove.sh <target>

Targets:
  gemini   Remove Gemini teammate (MCP, protocol doc, skill, config)
  codex    Remove Codex teammate (MCP, protocol doc, skill, config)
  copilot  Remove Copilot teammate (MCP, protocol doc, skill, config)
  all      Full uninstall (all agents + zshrc + config)
EOF
  exit 1
}

[[ $# -lt 1 ]] && usage
TARGET="$1"

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

disable_skill() {
  local skill_dir="$1"
  local skill_file="$skill_dir/SKILL.md"
  [[ -f "$skill_file" ]] && mv "$skill_file" "$skill_file.disabled"
}

sync_cache_remove() {
  local agent="$1"
  local cache_base="$HOME/.claude/plugins/cache/local-skill-tuning/skill-tuning"
  [[ ! -d "$cache_base" ]] && return 0
  local cache_ver
  cache_ver=$(ls -1 "$cache_base" 2>/dev/null | head -1)
  [[ -z "$cache_ver" ]] && return 0
  local dst="$cache_base/$cache_ver/skills/clmux-${agent}"
  rm -f "$dst/SKILL.md" "$dst/skill.md" 2>/dev/null
}

update_agents_enabled() {
  local key="$1" config="$CLMUX_DIR/.agents-enabled"
  if [[ -f "$config" ]]; then
    sed -i '' "s/^${key}=.*/${key}=0/" "$config" 2>/dev/null || \
      sed -i "s/^${key}=.*/${key}=0/" "$config" 2>/dev/null
  fi
}

# ---------------------------------------------------------------------------
# Remove Gemini
# ---------------------------------------------------------------------------
remove_gemini() {
  echo "--- Removing Gemini teammate ---"

  # MCP: remove clau-mux-bridge from ~/.gemini/settings.json
  local gemini_settings="$HOME/.gemini/settings.json"
  if [[ -f "$gemini_settings" ]]; then
    python3 -c "
import json, sys
p = '$gemini_settings'
with open(p) as f: s = json.load(f)
if 'mcpServers' in s: s['mcpServers'].pop('clau-mux-bridge', None)
with open(p, 'w') as f: json.dump(s, f, indent=2)
" && echo "[OK]   Removed clau-mux-bridge from ~/.gemini/settings.json" \
    || echo "[WARN] Could not update ~/.gemini/settings.json"
  else
    echo "[SKIP] ~/.gemini/settings.json not found"
  fi

  # Protocol doc
  rm -f "$CLMUX_DIR/GEMINI.md" && echo "[OK]   Removed GEMINI.md"

  # Skill
  disable_skill "$CLMUX_DIR/skills/clmux-gemini"
  sync_cache_remove gemini
  echo "[OK]   Disabled clmux-gemini skill"

  # Config
  update_agents_enabled "GEMINI_ENABLED"
  echo "[OK]   Set GEMINI_ENABLED=0"
}

# ---------------------------------------------------------------------------
# Remove Codex
# ---------------------------------------------------------------------------
remove_codex() {
  echo "--- Removing Codex teammate ---"

  # MCP: remove clau-mux-bridge from ~/.codex/config.toml
  local codex_config="$HOME/.codex/config.toml"
  if [[ -f "$codex_config" ]] && grep -q "clau-mux-bridge" "$codex_config" 2>/dev/null; then
    if command -v codex >/dev/null 2>&1; then
      codex mcp remove clau-mux-bridge 2>/dev/null \
        && echo "[OK]   Removed clau-mux-bridge from codex config" \
        || echo "[WARN] codex mcp remove failed — manually edit ~/.codex/config.toml"
    else
      echo "[WARN] codex CLI not found — manually remove clau-mux-bridge from ~/.codex/config.toml"
    fi
  else
    echo "[SKIP] clau-mux-bridge not found in codex config"
  fi

  # Protocol doc
  rm -f "$CLMUX_DIR/AGENTS.md" && echo "[OK]   Removed AGENTS.md"

  # Skill
  disable_skill "$CLMUX_DIR/skills/clmux-codex"
  sync_cache_remove codex
  echo "[OK]   Disabled clmux-codex skill"

  # Config
  update_agents_enabled "CODEX_ENABLED"
  echo "[OK]   Set CODEX_ENABLED=0"
}

# ---------------------------------------------------------------------------
# Remove Copilot
# ---------------------------------------------------------------------------
remove_copilot() {
  echo "--- Removing Copilot teammate ---"

  # MCP: remove clau-mux-bridge from ~/.copilot/mcp-config.json
  local copilot_mcp="$HOME/.copilot/mcp-config.json"
  if [[ -f "$copilot_mcp" ]]; then
    python3 -c "
import json
p = '$copilot_mcp'
with open(p) as f: s = json.load(f)
if 'mcpServers' in s: s['mcpServers'].pop('clau-mux-bridge', None)
with open(p, 'w') as f: json.dump(s, f, indent=2)
" && echo "[OK]   Removed clau-mux-bridge from ~/.copilot/mcp-config.json" \
    || echo "[WARN] Could not update ~/.copilot/mcp-config.json"
  else
    echo "[SKIP] ~/.copilot/mcp-config.json not found"
  fi

  # Protocol doc
  rm -f "$CLMUX_DIR/COPILOT.md" && echo "[OK]   Removed COPILOT.md"

  # Skill
  disable_skill "$CLMUX_DIR/skills/clmux-copilot"
  sync_cache_remove copilot
  echo "[OK]   Disabled clmux-copilot skill"

  # Config
  update_agents_enabled "COPILOT_ENABLED"
  echo "[OK]   Set COPILOT_ENABLED=0"
}

# ---------------------------------------------------------------------------
# Remove all (full uninstall)
# ---------------------------------------------------------------------------
remove_all() {
  echo "=== clau-mux full uninstall ==="
  echo ""

  remove_gemini
  echo ""
  remove_codex
  echo ""
  remove_copilot
  echo ""

  echo "--- Removing clau-mux core ---"

  # ~/.zshrc: remove source line
  local zshrc="$HOME/.zshrc"
  if [[ -f "$zshrc" ]] && grep -qF "clmux.zsh" "$zshrc"; then
    sed -i '' '/# clau-mux/d;/clmux\.zsh/d' "$zshrc" 2>/dev/null || \
      sed -i '/# clau-mux/d;/clmux\.zsh/d' "$zshrc" 2>/dev/null
    echo "[OK]   Removed clmux.zsh source from ~/.zshrc"
  else
    echo "[SKIP] clmux.zsh not found in ~/.zshrc"
  fi

  # .agents-enabled
  rm -f "$CLMUX_DIR/.agents-enabled" && echo "[OK]   Removed .agents-enabled"

  echo ""
  echo "=== Uninstall complete ==="
  echo "Note: tmux.conf and clau-mux source directory are left untouched."
  echo "Run 'source ~/.zshrc' to apply changes in current shell."
}

# ---------------------------------------------------------------------------
# Dispatch
# ---------------------------------------------------------------------------
case "$TARGET" in
  gemini)  remove_gemini ;;
  codex)   remove_codex ;;
  copilot) remove_copilot ;;
  all)     remove_all ;;
  *)       echo "error: unknown target '$TARGET'" >&2; usage ;;
esac
