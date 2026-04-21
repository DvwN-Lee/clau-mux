"""Ensure a project path is listed as trusted in ~/.copilot/config.json.

Copilot CLI shows a "Confirm folder trust" modal on first launch in an
unknown directory. The modal blocks the idle prompt, so wait_for_idle
never detects "/ commands" and the bridge times out without
delivering queued messages.

Copilot stores trusted folders as a JSON array of absolute paths under
the `trusted_folders` key in config.json:
  {"trusted_folders": ["/abs/path1", "/abs/path2", ...]}

Idempotent: re-trusting an already-listed path is a no-op.

Usage:
  python3 trust_copilot_project.py <path>
"""
import json
import os
import sys

FILE_PATH = os.path.expanduser("~/.copilot/config.json")


def main():
    if len(sys.argv) != 2:
        print("usage: trust_copilot_project.py <path>", file=sys.stderr)
        sys.exit(1)

    path = os.path.realpath(os.path.abspath(sys.argv[1]))

    try:
        with open(FILE_PATH) as f:
            data = json.load(f)
        if not isinstance(data, dict):
            data = {}
    except (FileNotFoundError, json.JSONDecodeError):
        data = {}

    folders = data.get("trusted_folders")
    if not isinstance(folders, list):
        folders = []

    if path in folders:
        return  # already trusted

    folders.append(path)
    data["trusted_folders"] = folders

    os.makedirs(os.path.dirname(FILE_PATH), exist_ok=True)
    with open(FILE_PATH, "w") as f:
        json.dump(data, f, indent=2)
        f.write("\n")


if __name__ == "__main__":
    main()
