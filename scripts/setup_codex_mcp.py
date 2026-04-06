#!/usr/bin/env python3
"""
scripts/setup_codex_mcp.py
Register clau-mux-bridge in ~/.codex/config.toml using npx + env.

Codex CLI calls env_clear() on MCP subprocesses, then re-applies:
  DEFAULT_ENV_VARS (HOME, PATH, ...) + env_vars + env (from config.toml)
The `env` field overrides defaults, so we inject PATH with node bin dir
to guarantee npx can find node even if Codex's own PATH is incomplete
(e.g. launched from non-interactive shell without nvm init).

Usage:
  python3 setup_codex_mcp.py                                          # register
  python3 setup_codex_mcp.py --outbox <path> --agent <name>           # per-team args
  python3 setup_codex_mcp.py --remove                                 # remove entry
"""

import os
import shutil
import sys

TOML_PATH = os.path.expanduser("~/.codex/config.toml")
SERVER_NAME = "clau_mux_bridge"
TOOL_SECTION = f"[mcp_servers.{SERVER_NAME}.tools.write_to_lead]"


def resolve_path_with_node() -> str:
    """Build a PATH string that includes the directory containing node."""
    node = shutil.which("node")
    if node:
        node_bin_dir = os.path.dirname(os.path.realpath(node))
    else:
        # nvm fallback
        nvm_dir = os.environ.get("NVM_DIR", os.path.expanduser("~/.nvm"))
        default_alias = os.path.join(nvm_dir, "alias", "default")
        node_bin_dir = None
        if os.path.exists(default_alias):
            version = (
                os.readlink(default_alias)
                if os.path.islink(default_alias)
                else open(default_alias).read().strip()
            )
            candidate = os.path.join(nvm_dir, "versions", "node", version, "bin")
            if os.path.isdir(candidate):
                node_bin_dir = candidate
        if not node_bin_dir:
            raise FileNotFoundError("node binary not found — cannot build PATH for env")

    # Compose PATH: node bin dir + standard system dirs (deduped, order preserved)
    base_dirs = [
        node_bin_dir,
        "/opt/homebrew/bin",
        "/usr/local/bin",
        "/usr/bin",
        "/bin",
    ]
    seen = set()
    dirs = []
    for d in base_dirs:
        if d not in seen:
            seen.add(d)
            dirs.append(d)
    return ":".join(dirs)


def read_toml() -> str:
    if os.path.isfile(TOML_PATH):
        with open(TOML_PATH) as f:
            return f.read()
    return ""


def write_toml(content: str):
    os.makedirs(os.path.dirname(TOML_PATH), exist_ok=True)
    with open(TOML_PATH, "w") as f:
        f.write(content)


def remove_server_block(content: str) -> str:
    """Remove [mcp_servers.clau_mux_bridge] (and legacy clau-mux-bridge) sub-sections."""
    names_to_remove = {SERVER_NAME, "clau-mux-bridge"}
    lines = content.split("\n")
    out = []
    skip = False
    for line in lines:
        stripped = line.strip()
        if any(stripped.startswith(f"[mcp_servers.{n}") for n in names_to_remove):
            skip = True
            continue
        if skip and stripped.startswith("["):
            skip = False
        if skip:
            continue
        out.append(line)
    while out and out[-1].strip() == "":
        out.pop()
    return "\n".join(out)


def build_server_block(path_env: str, outbox: str = "", agent: str = "") -> str:
    """Build TOML block for the MCP server using npx + env."""
    args = ["-y", "clau-mux-bridge"]
    if outbox:
        args.extend(["--outbox", outbox])
    if agent:
        args.extend(["--agent", agent])

    args_toml = ", ".join(f'"{a}"' for a in args)
    home = os.path.expanduser("~")

    block = f"""\
[mcp_servers.{SERVER_NAME}]
command = "npx"
args = [{args_toml}]
startup_timeout_sec = 30

[mcp_servers.{SERVER_NAME}.env]
PATH = "{path_env}"
HOME = "{home}"

{TOOL_SECTION}
approval_mode = "approve\""""
    return block


def main():
    args = sys.argv[1:]

    if "--remove" in args:
        content = read_toml()
        content = remove_server_block(content)
        write_toml(content)
        print(f"[OK] Removed {SERVER_NAME} from {TOML_PATH}")
        return

    outbox = ""
    agent = ""
    i = 0
    while i < len(args):
        if args[i] == "--outbox" and i + 1 < len(args):
            outbox = args[i + 1]
            i += 2
        elif args[i] == "--agent" and i + 1 < len(args):
            agent = args[i + 1]
            i += 2
        else:
            i += 1

    path_env = resolve_path_with_node()

    content = read_toml()
    content = remove_server_block(content)

    block = build_server_block(path_env, outbox, agent)

    if content and not content.endswith("\n"):
        content += "\n"
    content = content + "\n" + block + "\n"

    write_toml(content)
    print(f"[OK] Registered {SERVER_NAME} in {TOML_PATH} (npx + env)")
    print(f"     PATH: {path_env}")
    if outbox:
        print(f"     outbox: {outbox}")
    if agent:
        print(f"     agent:  {agent}")


if __name__ == "__main__":
    main()
