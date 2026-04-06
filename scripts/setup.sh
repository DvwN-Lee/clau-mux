#!/usr/bin/env bash
set -euo pipefail

CLMUX_DIR="$(cd "$(dirname "$0")/.." && pwd)"

echo "=== clau-mux setup ==="
echo "Directory: $CLMUX_DIR"
echo ""

# ---------------------------------------------------------------------------
# 1. zsh 함수 로드 (~/.zshrc)
# ---------------------------------------------------------------------------
ZSHRC="$HOME/.zshrc"
SOURCE_LINE="source \"$CLMUX_DIR/clmux.zsh\""

if grep -qF "clmux.zsh" "$ZSHRC" 2>/dev/null; then
  echo "[SKIP] ~/.zshrc already sources clmux.zsh"
else
  printf '\n# clau-mux\n%s\n' "$SOURCE_LINE" >> "$ZSHRC"
  echo "[OK]   Added clmux.zsh source to ~/.zshrc"
fi

# ---------------------------------------------------------------------------
# 2. tmux 테마 (~/.tmux.conf) — 선택
# ---------------------------------------------------------------------------
TMUX_CONF="$CLMUX_DIR/tmux.conf"
USER_TMUX="$HOME/.tmux.conf"

read -r -p "Apply clau-mux tmux theme? [Y/n] " tmux_answer
tmux_answer="${tmux_answer:-Y}"

if [[ "$tmux_answer" =~ ^[Yy]$ ]]; then
  if [[ ! -f "$USER_TMUX" ]]; then
    cp "$TMUX_CONF" "$USER_TMUX"
    echo "[OK]   Copied tmux.conf to ~/.tmux.conf"
  else
    read -r -p "~/.tmux.conf already exists. Append clau-mux settings? [y/N] " append_answer
    append_answer="${append_answer:-N}"
    if [[ "$append_answer" =~ ^[Yy]$ ]]; then
      printf '\n# clau-mux tmux theme\n' >> "$USER_TMUX"
      cat "$TMUX_CONF" >> "$USER_TMUX"
      echo "[OK]   Appended tmux.conf to ~/.tmux.conf"
    else
      echo "[SKIP] ~/.tmux.conf left unchanged"
    fi
  fi
  if command -v tmux >/dev/null 2>&1 && tmux info >/dev/null 2>&1; then
    tmux source "$USER_TMUX" 2>/dev/null && echo "[OK]   Reloaded tmux config" || echo "[WARN] Could not reload tmux config (no active session?)"
  fi
else
  echo "[SKIP] tmux theme skipped"
fi

# ---------------------------------------------------------------------------
# 3. Gemini MCP 등록 (~/.gemini/settings.json) — npx 기반
# ---------------------------------------------------------------------------
read -r -p "Use Gemini as teammate? [Y/n] " gemini_answer
gemini_answer="${gemini_answer:-Y}"

if [[ "$gemini_answer" =~ ^[Yy]$ ]]; then
  GEMINI_ENABLED=1
  if command -v gemini >/dev/null 2>&1; then
    python3 "$CLMUX_DIR/scripts/setup_gemini_mcp.py" npx
    echo "[OK]   Registered clau-mux-bridge (npx) in ~/.gemini/settings.json"
  else
    echo "[WARN] gemini CLI not found — install it to use Gemini teammate"
  fi
else
  GEMINI_ENABLED=0
  echo "[SKIP] Gemini teammate disabled"
fi

# ---------------------------------------------------------------------------
# 4. Codex MCP 등록 (~/.codex/config.toml) — npx 기반
# ---------------------------------------------------------------------------
read -r -p "Use Codex as teammate? [Y/n] " codex_answer
codex_answer="${codex_answer:-Y}"

if [[ "$codex_answer" =~ ^[Yy]$ ]]; then
  CODEX_ENABLED=1
  if command -v codex >/dev/null 2>&1; then
    CODEX_CONFIG="$HOME/.codex/config.toml"
    if [[ -f "$CODEX_CONFIG" ]] && grep -q "clau-mux-bridge" "$CODEX_CONFIG" 2>/dev/null; then
      echo "[SKIP] clau-mux-bridge already registered in codex config"
    else
      codex mcp add clau-mux-bridge -- npx -y clau-mux-bridge
      echo "[OK]   Registered clau-mux-bridge (npx) in codex"
    fi
  else
    echo "[WARN] codex CLI not found — install it to use Codex teammate"
  fi
else
  CODEX_ENABLED=0
  echo "[SKIP] Codex teammate disabled"
fi

# ---------------------------------------------------------------------------
# 5. Copilot MCP 등록 (~/.copilot/mcp-config.json) — npx 기반
# ---------------------------------------------------------------------------
read -r -p "Use Copilot as teammate? [Y/n] " copilot_answer
copilot_answer="${copilot_answer:-Y}"

if [[ "$copilot_answer" =~ ^[Yy]$ ]]; then
  COPILOT_ENABLED=1
  if command -v copilot >/dev/null 2>&1; then
    python3 "$CLMUX_DIR/scripts/setup_copilot_mcp.py" npx
    echo "[OK]   Registered clau-mux-bridge (npx) in ~/.copilot/mcp-config.json"
  else
    echo "[WARN] copilot CLI not found — install @github/copilot to use Copilot teammate"
  fi
else
  COPILOT_ENABLED=0
  echo "[SKIP] Copilot teammate disabled"
fi

cat > "$CLMUX_DIR/.agents-enabled" <<CONF
GEMINI_ENABLED=${GEMINI_ENABLED:-1}
CODEX_ENABLED=${CODEX_ENABLED:-1}
COPILOT_ENABLED=${COPILOT_ENABLED:-1}
CONF
echo "[OK]   Agent config saved to .agents-enabled"

# ---------------------------------------------------------------------------
# 6. 스킬 파일 활성화/비활성화
# ---------------------------------------------------------------------------
toggle_skill() {
  local skill_dir="$1" enabled="$2"
  local skill_file="$skill_dir/SKILL.md"
  local disabled_file="$skill_dir/SKILL.md.disabled"
  if [[ "$enabled" -eq 1 ]]; then
    [[ -f "$disabled_file" && ! -f "$skill_file" ]] && mv "$disabled_file" "$skill_file"
  else
    [[ -f "$skill_file" ]] && mv "$skill_file" "$disabled_file"
  fi
}

toggle_skill "$CLMUX_DIR/skills/clmux-gemini"   "${GEMINI_ENABLED:-1}"
toggle_skill "$CLMUX_DIR/skills/clmux-codex"    "${CODEX_ENABLED:-1}"
toggle_skill "$CLMUX_DIR/skills/clmux-copilot"  "${COPILOT_ENABLED:-1}"

# Sync to plugin cache (if installed)
CACHE_BASE="$HOME/.claude/plugins/cache/local-skill-tuning/skill-tuning"
if [[ -d "$CACHE_BASE" ]]; then
  CACHE_VER=$(ls -1 "$CACHE_BASE" 2>/dev/null | head -1)
  if [[ -n "$CACHE_VER" ]]; then
    for agent in gemini codex copilot; do
      src="$CLMUX_DIR/skills/clmux-${agent}"
      dst="$CACHE_BASE/$CACHE_VER/skills/clmux-${agent}"
      if [[ -d "$dst" ]]; then
        if [[ -f "$src/SKILL.md" ]]; then
          cp "$src/SKILL.md" "$dst/SKILL.md" 2>/dev/null
          rm -f "$dst/SKILL.md.disabled" "$dst/skill.md.disabled" 2>/dev/null
        else
          rm -f "$dst/SKILL.md" "$dst/skill.md" 2>/dev/null
        fi
      fi
    done
    echo "[OK]   Skill cache synced"
  fi
fi

# ---------------------------------------------------------------------------
# 7. 지시 파일 생성 (GEMINI.md, AGENTS.md, COPILOT.md)
# ---------------------------------------------------------------------------
SYNC_ARGS=""
[[ "${GEMINI_ENABLED:-1}" -eq 1 ]] && SYNC_ARGS="$SYNC_ARGS --gemini"
[[ "${CODEX_ENABLED:-1}" -eq 1 ]] && SYNC_ARGS="$SYNC_ARGS --codex"
[[ "${COPILOT_ENABLED:-1}" -eq 1 ]] && SYNC_ARGS="$SYNC_ARGS --copilot"
if [[ -n "$SYNC_ARGS" ]]; then
  bash "$CLMUX_DIR/scripts/sync-protocol.sh" $SYNC_ARGS
  echo "[OK]   Protocol files synced"
else
  echo "[SKIP] No agents enabled — protocol files not generated"
fi

echo ""
echo "=== Setup complete ==="
echo "Run 'source ~/.zshrc' to activate clmux in your current shell."
