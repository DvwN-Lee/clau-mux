# clmux — main entry point. Sources modular lib files in dependency order.
# See lib/*.zsh for per-module implementation. CLMUX_DIR is set here so lib
# files can reference repo assets via "$CLMUX_DIR/...".
if [[ -n "$ZSH_VERSION" ]]; then
  CLMUX_DIR="${${(%):-%x}:A:h}"
else
  CLMUX_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-$0}")" && pwd)"
fi
export CLMUX_DIR

# Source order matters: teammate-wrappers runs `if _clmux_agent_enabled ...`
# at source time, so teammate-internals must be loaded first.
local _clmux_modules=(
  core
  launcher
  teammate-internals
  teammate-wrappers
  session-utils
  tools
)
for _mod in $_clmux_modules; do
  source "$CLMUX_DIR/lib/${_mod}.zsh"
done
unset _clmux_modules _mod

# Resolve default Gemini model env vars from the installed CLI bundle.
# Uses a per-CLI-version cache (~/.cache/clmux/gemini-models-X.Y.txt) so
# bundle parsing runs once per CLI update, not on every shell startup.
# Pre-set CLMUX_GEMINI_MODEL_PRO / CLMUX_GEMINI_MODEL_FLASH in .zshrc
# (before sourcing clmux.zsh) to pin a specific model and skip resolution.
if command -v gemini &>/dev/null; then
  : "${CLMUX_GEMINI_MODEL_PRO:=$(_clmux_gemini_latest pro 2>/dev/null)}"
  : "${CLMUX_GEMINI_MODEL_FLASH:=$(_clmux_gemini_latest flash 2>/dev/null)}"
  export CLMUX_GEMINI_MODEL_PRO CLMUX_GEMINI_MODEL_FLASH
fi
