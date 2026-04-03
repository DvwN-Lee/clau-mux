#!/usr/bin/env python3
"""
bridge-mcp-server.py
Minimal stdio MCP server for clau-mux.
Exposes write_to_lead(text, summary?) tool so Gemini can write directly
to the Claude Code teammate outbox without tmux pane-watching.

Reads from env:
  CLMUX_OUTBOX  — path to outbox.json
  CLMUX_AGENT   — agent name (default: gemini-worker)

Usage (registered via `gemini mcp add`):
  gemini mcp add clau-mux-bridge python3 /path/to/bridge-mcp-server.py
"""

import json
import os
import sys
import datetime
import tempfile
from typing import Optional

AGENT_NAME = os.environ.get("CLMUX_AGENT", "gemini-worker")
OUTBOX = os.environ.get("CLMUX_OUTBOX", "")

# ── Protocol helpers ──────────────────────────────────────────────────────────

def now_ts() -> str:
    t = datetime.datetime.now(datetime.timezone.utc)
    return t.strftime("%Y-%m-%dT%H:%M:%S.") + f"{t.microsecond // 1000:03d}Z"


def send_msg(obj: dict) -> None:
    # Gemini CLI v0.36+ uses newline-delimited JSON (NDJSON), not Content-Length framing.
    data = json.dumps(obj, separators=(",", ":"))
    sys.stdout.buffer.write((data + "\n").encode("utf-8"))
    sys.stdout.buffer.flush()


def recv_msg() -> Optional[dict]:
    # Read one newline-delimited JSON message.
    raw = sys.stdin.buffer.readline()
    if not raw:
        return None
    line = raw.decode("utf-8").strip()
    if not line:
        return None
    return json.loads(line)


# ── Outbox write ──────────────────────────────────────────────────────────────

def atomic_write(path: str, data: list) -> None:
    dir_ = os.path.dirname(os.path.abspath(path))
    with tempfile.NamedTemporaryFile(
        mode="w", dir=dir_, delete=False, suffix=".tmp", encoding="utf-8"
    ) as tf:
        json.dump(data, tf, indent=2, ensure_ascii=False)
        tmp_name = tf.name
    os.replace(tmp_name, path)


def write_to_lead_impl(text: str, summary: str = "") -> str:
    if not OUTBOX:
        return "error: CLMUX_OUTBOX not set"
    try:
        try:
            with open(OUTBOX, encoding="utf-8") as f:
                msgs = json.load(f)
        except Exception:
            msgs = []

        # Response entry
        ts1 = now_ts()
        entry: dict = {"from": AGENT_NAME, "text": text, "timestamp": ts1, "read": False}
        if summary:
            entry["summary"] = summary
        msgs.append(entry)

        # Idle notification (JSON-in-text format required by Claude Code)
        ts2 = now_ts()
        idle_payload = json.dumps({
            "type": "idle_notification",
            "from": AGENT_NAME,
            "idleReason": "available",
            "timestamp": ts2,
        })
        msgs.append({"from": AGENT_NAME, "text": idle_payload, "timestamp": ts2, "read": False})

        # Trim to 50 entries
        if len(msgs) > 50:
            msgs = msgs[-50:]

        atomic_write(OUTBOX, msgs)
        return "ok: response delivered to lead"
    except Exception as exc:
        return f"error: {exc}"


# ── MCP request handlers ──────────────────────────────────────────────────────

TOOL_SCHEMA = {
    "name": "write_to_lead",
    "description": (
        "Send your completed response to the Claude Code lead session via the "
        "teammate protocol. Call this once at the end of every response."
    ),
    "inputSchema": {
        "type": "object",
        "properties": {
            "text": {
                "type": "string",
                "description": "Your full response text.",
            },
            "summary": {
                "type": "string",
                "description": "Optional short summary (first sentence, < 60 chars).",
            },
        },
        "required": ["text"],
    },
}


def handle(msg: dict) -> None:
    method = msg.get("method", "")
    id_ = msg.get("id")

    if method == "initialize":
        params = msg.get("params", {})
        proto_version = params.get("protocolVersion", "2024-11-05")
        send_msg({
            "jsonrpc": "2.0",
            "id": id_,
            "result": {
                "protocolVersion": proto_version,
                "capabilities": {"tools": {}},
                "serverInfo": {"name": "clau-mux-bridge", "version": "0.1.0"},
            },
        })

    elif method in ("notifications/initialized", "initialized"):
        pass  # notifications need no response

    elif method == "tools/list":
        send_msg({
            "jsonrpc": "2.0",
            "id": id_,
            "result": {"tools": [TOOL_SCHEMA]},
        })

    elif method == "tools/call":
        params = msg.get("params", {})
        if params.get("name") == "write_to_lead":
            args = params.get("arguments", {})
            result = write_to_lead_impl(
                args.get("text", ""),
                args.get("summary", ""),
            )
            send_msg({
                "jsonrpc": "2.0",
                "id": id_,
                "result": {"content": [{"type": "text", "text": result}]},
            })
        else:
            send_msg({
                "jsonrpc": "2.0",
                "id": id_,
                "error": {"code": -32601, "message": "Unknown tool"},
            })

    elif id_ is not None:
        send_msg({
            "jsonrpc": "2.0",
            "id": id_,
            "error": {"code": -32601, "message": f"Unknown method: {method}"},
        })


# ── Entry point ───────────────────────────────────────────────────────────────

def main() -> None:
    while True:
        msg = recv_msg()
        if msg is None:
            break
        handle(msg)


if __name__ == "__main__":
    main()
