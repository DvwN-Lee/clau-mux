"""Ensure a project path is listed as trusted in ~/.gemini/trustedFolders.json.

Gemini CLI shows an interactive "Do you trust the files in this folder?"
prompt on first launch in an unknown directory. When spawned via the
clmux bridge, that blocks the CLI from reaching its idle prompt, so
wait_for_idle never detects "Type your message" and the bridge either
times out or silently drops queued messages.

Gemini stores trusted folders as a flat object whose keys are absolute
paths and values are the string "TRUST_FOLDER":
  {"/abs/path": "TRUST_FOLDER", ...}

Idempotent: re-trusting an already-trusted path is a no-op.

Usage:
  python3 trust_gemini_project.py <path>
"""
import json
import os
import sys

FILE_PATH = os.path.expanduser("~/.gemini/trustedFolders.json")


def main():
    if len(sys.argv) != 2:
        print("usage: trust_gemini_project.py <path>", file=sys.stderr)
        sys.exit(1)

    path = os.path.realpath(os.path.abspath(sys.argv[1]))

    try:
        with open(FILE_PATH) as f:
            data = json.load(f)
        if not isinstance(data, dict):
            data = {}
    except (FileNotFoundError, json.JSONDecodeError):
        data = {}

    if data.get(path) == "TRUST_FOLDER":
        return  # already trusted

    data[path] = "TRUST_FOLDER"
    os.makedirs(os.path.dirname(FILE_PATH), exist_ok=True)
    with open(FILE_PATH, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
