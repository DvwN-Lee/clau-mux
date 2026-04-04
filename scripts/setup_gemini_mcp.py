#!/usr/bin/env python3
# scripts/setup_gemini_mcp.py
# Usage: python3 setup_gemini_mcp.py <bridge_path>
import json, sys, os

bridge_path = sys.argv[1]
settings_path = os.path.expanduser("~/.gemini/settings.json")

# Read or create settings
if os.path.exists(settings_path):
    with open(settings_path) as f:
        settings = json.load(f)
else:
    settings = {}

if "mcpServers" not in settings:
    settings["mcpServers"] = {}

settings["mcpServers"]["clau-mux-bridge"] = {
    "command": "node",
    "args": [bridge_path],
    "trust": True
}

with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
