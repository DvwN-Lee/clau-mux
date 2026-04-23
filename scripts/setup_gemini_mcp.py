#!/usr/bin/env python3
# scripts/setup_gemini_mcp.py
# Usage: python3 setup_gemini_mcp.py <command>
# <command>: "npx" (default) or absolute path to bridge-mcp-server.js
import json
import os
import sys

SERVER_NAME = "clau_mux_bridge"
LEGACY_NAMES = {"clau_mux_bridge", "clau-mux-bridge"}
NPM_PIN = "clau-mux-bridge@^1.3.0"


def main():
    cmd = sys.argv[1] if len(sys.argv) > 1 else "npx"
    settings_path = os.path.expanduser("~/.gemini/settings.json")

    if os.path.exists(settings_path):
        with open(settings_path) as f:
            settings = json.load(f)
    else:
        settings = {}

    servers = settings.setdefault("mcpServers", {})
    for name in LEGACY_NAMES:
        servers.pop(name, None)

    if cmd == "npx":
        servers[SERVER_NAME] = {
            "command": "npx",
            "args": ["-y", NPM_PIN],
            "trust": True,
        }
    else:
        servers[SERVER_NAME] = {
            "command": "node",
            "args": [cmd],
            "trust": True,
        }

    os.makedirs(os.path.dirname(settings_path), exist_ok=True)
    with open(settings_path, "w") as f:
        json.dump(settings, f, indent=2)


if __name__ == "__main__":
    main()
