# ── _clmux_ensure_team ────────────────────────────────────────────────────────
# Ensures team directory and config.json exist. Idempotent.
_clmux_ensure_team() {
  local team_dir="$1" team_name="$2"
  mkdir -p "$team_dir/inboxes"
  if [[ ! -f "$team_dir/config.json" ]]; then
    printf '{\n  "name": "%s",\n  "members": []\n}\n' "$team_name" > "$team_dir/config.json"
  fi
}

# update tmux window name to current git branch after each command
_clmux_precmd() {
  [[ -n "$TMUX" ]] || return
  local branch
  branch=$(git symbolic-ref --short HEAD 2>/dev/null) || return
  tmux rename-window "$branch"
}
autoload -Uz add-zsh-hook
add-zsh-hook precmd _clmux_precmd
