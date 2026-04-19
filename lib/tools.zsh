# ── clmux-pipeline ────────────────────────────────────────────────────────────
# Thin wrapper that forwards to scripts/clmux_pipeline.sh with CLMUX_DIR root
# discovered at first call. See docs/pipeline.md.
clmux-pipeline() {
  if [[ -z "$CLMUX_DIR" || ! -f "$CLMUX_DIR/scripts/clmux_pipeline.sh" ]]; then
    for _d in "$HOME/clau-mux" "$HOME/Desktop/Git/clau-mux"; do
      [[ -f "$_d/scripts/clmux_pipeline.sh" ]] && { CLMUX_DIR="$_d"; break; }
    done
  fi
  [[ -f "$CLMUX_DIR/scripts/clmux_pipeline.sh" ]] || {
    echo "error: cannot find clau-mux directory" >&2; return 1;
  }
  bash "$CLMUX_DIR/scripts/clmux_pipeline.sh" "$@"
}
