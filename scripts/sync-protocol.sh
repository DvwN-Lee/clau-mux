#!/usr/bin/env bash
# sync-protocol.sh
# Generates GEMINI.md and AGENTS.md from teammate-protocol.md by substituting
# the {{AGENT_NAME}} placeholder with the appropriate agent name.
# Codex-specific rules are appended from teammate-protocol-codex.md if present.
#
# Usage: bash scripts/sync-protocol.sh

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"
TEMPLATE="$REPO_DIR/teammate-protocol.md"
CODEX_EXTRA="$REPO_DIR/teammate-protocol-codex.md"

if [[ ! -f "$TEMPLATE" ]]; then
  echo "error: $TEMPLATE not found" >&2
  exit 1
fi

if [[ ! -f "$CODEX_EXTRA" ]]; then
  echo "warning: $CODEX_EXTRA not found — AGENTS.md will lack Codex-specific rules" >&2
fi

generate() {
  local agent_name="$1"
  local output_file="$2"
  local extra_file="${3:-}"
  local header="<!-- Generated from teammate-protocol.md. Do not edit directly. -->"
  printf '%s\n' "$header" > "$output_file"
  sed "s/{{AGENT_NAME}}/$agent_name/g" "$TEMPLATE" >> "$output_file"
  if [[ -n "$extra_file" && -f "$extra_file" ]]; then
    printf '\n' >> "$output_file"
    cat "$extra_file" >> "$output_file"
  fi
  echo "generated: $output_file"
}

generate "gemini-worker" "$REPO_DIR/GEMINI.md"
generate "codex-worker"  "$REPO_DIR/AGENTS.md" "$CODEX_EXTRA"
