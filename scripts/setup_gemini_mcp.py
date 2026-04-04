#!/usr/bin/env python3
# scripts/setup_gemini_mcp.py
# Usage: python3 setup_gemini_mcp.py <command>
# <command>: "npx" for npx-based, or absolute path to bridge-mcp-server.js
import json, sys, os

cmd = sys.argv[1] if len(sys.argv) > 1 else "npx"
settings_path = os.path.expanduser("~/.gemini/settings.json")

if os.path.exists(settings_path):
    with open(settings_path) as f:
        settings = json.load(f)
else:
    settings = {}

if "mcpServers" not in settings:
    settings["mcpServers"] = {}

if cmd == "npx":
    settings["mcpServers"]["clau-mux-bridge"] = {
        "command": "npx",
        "args": ["-y", "clau-mux-bridge"],
        "trust": True,
    }
else:
    settings["mcpServers"]["clau-mux-bridge"] = {
        "command": "node",
        "args": [cmd],
        "trust": True,
    }

os.makedirs(os.path.dirname(settings_path), exist_ok=True)
with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
