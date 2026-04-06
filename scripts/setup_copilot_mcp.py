#!/usr/bin/env python3
# scripts/setup_copilot_mcp.py
# Usage: python3 setup_copilot_mcp.py <command_or_url>
#   http://...   → HTTP/SSE mode (Copilot CLI requires this)
#   npx          → npx -y clau-mux-bridge (stdio, for other clients)
#   /path/to/js  → node <path> (stdio, for other clients)
import json, sys, os

cmd = sys.argv[1] if len(sys.argv) > 1 else "npx"
settings_path = os.path.expanduser("~/.copilot/mcp-config.json")

if os.path.exists(settings_path):
    with open(settings_path) as f:
        settings = json.load(f)
else:
    settings = {}

if "mcpServers" not in settings:
    settings["mcpServers"] = {}

TOOLS = ["write_to_lead"]

if cmd.startswith("http"):
    settings["mcpServers"]["clau_mux_bridge"] = {
        "type": "sse",
        "url": cmd,
        "tools": TOOLS,
    }
elif cmd == "npx":
    settings["mcpServers"]["clau_mux_bridge"] = {
        "command": "npx",
        "args": ["-y", "clau-mux-bridge"],
        "tools": TOOLS,
    }
else:
    settings["mcpServers"]["clau_mux_bridge"] = {
        "command": "node",
        "args": [cmd],
        "tools": TOOLS,
    }

os.makedirs(os.path.dirname(settings_path), exist_ok=True)
with open(settings_path, "w") as f:
    json.dump(settings, f, indent=2)
