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
if command -v gemini >/dev/null 2>&1; then
  python3 "$CLMUX_DIR/scripts/setup_gemini_mcp.py" npx
  echo "[OK]   Registered clau-mux-bridge (npx) in ~/.gemini/settings.json"
else
  echo "[SKIP] gemini CLI not found — skipping Gemini MCP registration"
fi

# ---------------------------------------------------------------------------
# 4. Codex MCP 등록 (~/.codex/config.toml) — npx 기반
# ---------------------------------------------------------------------------
if command -v codex >/dev/null 2>&1; then
  CODEX_CONFIG="$HOME/.codex/config.toml"

  if [[ -f "$CODEX_CONFIG" ]] && grep -q "clau-mux-bridge" "$CODEX_CONFIG" 2>/dev/null; then
    echo "[SKIP] clau-mux-bridge already registered in codex config"
  else
    codex mcp add clau-mux-bridge -- npx -y clau-mux-bridge
    echo "[OK]   Registered clau-mux-bridge (npx) in codex"
  fi
else
  echo "[SKIP] codex CLI not found — skipping Codex MCP registration"
fi

# ---------------------------------------------------------------------------
# 5. 지시 파일 생성 (GEMINI.md, AGENTS.md)
# ---------------------------------------------------------------------------
bash "$CLMUX_DIR/scripts/sync-protocol.sh"
echo "[OK]   Protocol files synced (GEMINI.md, AGENTS.md)"

echo ""
echo "=== Setup complete ==="
echo "Run 'source ~/.zshrc' to activate clmux in your current shell."
