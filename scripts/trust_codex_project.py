"""Ensure a project path is listed as trusted in ~/.codex/config.toml.

Codex shows an interactive "Do you trust this directory?" prompt on the
first launch inside an unknown cwd. When codex is spawned via the clmux
bridge, that prompt's `› 1. Yes, continue` option line matches the
bridge's idle pattern `^[[:space:]]*›` and causes a false idle detection.
The bridge then chunks its queued message into the trust prompt, which
codex interprets as invalid input and terminates the pane — producing
the "chunk paste-buffer failed / pane is gone" failure observed in
fe-debug-pipeline.

Pre-populating the projects table with `trust_level = "trusted"` makes
codex skip the trust prompt, so the bridge reaches the real prompt and
its idle detection operates on the normal input line only.

Idempotent: re-trusting an already-trusted path is a no-op.

Usage:
  python3 trust_codex_project.py <path>
"""
import os
import sys

TOML_PATH = os.path.expanduser("~/.codex/config.toml")


def main():
    if len(sys.argv) != 2:
        print("usage: trust_codex_project.py <path>", file=sys.stderr)
        sys.exit(1)

    path = os.path.realpath(os.path.abspath(sys.argv[1]))
    section = f'[projects."{path}"]'

    try:
        with open(TOML_PATH) as f:
            content = f.read()
    except FileNotFoundError:
        content = ""

    if section in content:
        return  # already trusted

    entry = f'{section}\ntrust_level = "trusted"\n'
    os.makedirs(os.path.dirname(TOML_PATH), exist_ok=True)
    if content and not content.endswith("\n"):
        content += "\n"
    content = content + "\n" + entry
    with open(TOML_PATH, "w") as f:
        f.write(content)


if __name__ == "__main__":
    main()
