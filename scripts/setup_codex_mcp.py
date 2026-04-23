#!/usr/bin/env python3
"""
scripts/setup_codex_mcp.py
Generate Codex MCP config for clau-mux-bridge.

Two modes:
  (1) Per-team (spawn-time):
        python3 setup_codex_mcp.py --home <team-codex-home> \
            --outbox <path> --agent <name>
      Writes <home>/config.toml with a mcp_servers block bound to that team's
      outbox/agent. Intended to be consumed by Codex via CODEX_HOME=<home>.

  (2) Global scrub (migration / no args):
        python3 setup_codex_mcp.py
      Removes any legacy [mcp_servers.clau_mux_bridge] block from
      ~/.codex/config.toml. Does NOT write a new global block — per-team
      isolation is the new model. Running this is safe and idempotent.

  (3) Explicit remove (same as scrub but can target --home):
        python3 setup_codex_mcp.py --remove [--home <dir>]

Codex CLI calls env_clear() on MCP subprocesses, then re-applies
DEFAULT_ENV_VARS + env_vars + env (from config.toml). The `env` field
overrides defaults, so we inject PATH with node bin dir to guarantee
npx can find node even if Codex's own PATH is incomplete.
"""

import os
import shutil
import sys

SERVER_NAME = "clau_mux_bridge"
TOOL_SECTION = f"[mcp_servers.{SERVER_NAME}.tools.write_to_lead]"
NPM_PIN = "clau-mux-bridge@^1.3.0"


def resolve_path_with_node() -> str:
    """Build a PATH string that includes the directory containing node."""
    node = shutil.which("node")
    if node:
        node_bin_dir = os.path.dirname(os.path.realpath(node))
    else:
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

    base_dirs = [node_bin_dir, "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin"]
    seen = set()
    dirs = []
    for d in base_dirs:
        if d not in seen:
            seen.add(d)
            dirs.append(d)
    return ":".join(dirs)


def read_toml(path: str) -> str:
    if os.path.isfile(path):
        with open(path) as f:
            return f.read()
    return ""


def write_toml(path: str, content: str):
    os.makedirs(os.path.dirname(path) or ".", exist_ok=True)
    with open(path, "w") as f:
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


def build_server_block(path_env: str, outbox: str, agent: str) -> str:
    """Build TOML block for per-team MCP server. Both outbox and agent required."""
    args = ["-y", NPM_PIN, "--outbox", outbox, "--agent", agent]
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
approval_mode = "auto\""""
    return block


def parse_args(argv):
    args = {"remove": False, "home": "", "outbox": "", "agent": ""}
    i = 0
    while i < len(argv):
        a = argv[i]
        if a == "--remove":
            args["remove"] = True
            i += 1
        elif a == "--home" and i + 1 < len(argv):
            args["home"] = argv[i + 1]
            i += 2
        elif a == "--outbox" and i + 1 < len(argv):
            args["outbox"] = argv[i + 1]
            i += 2
        elif a == "--agent" and i + 1 < len(argv):
            args["agent"] = argv[i + 1]
            i += 2
        else:
            i += 1
    return args


def resolve_toml_path(home_override: str) -> str:
    if home_override:
        return os.path.join(home_override, "config.toml")
    return os.path.expanduser("~/.codex/config.toml")


def main():
    opts = parse_args(sys.argv[1:])
    toml_path = resolve_toml_path(opts["home"])

    if opts["remove"]:
        content = remove_server_block(read_toml(toml_path))
        write_toml(toml_path, content)
        print(f"[OK] Removed {SERVER_NAME} from {toml_path}")
        return

    # Per-team write mode
    if opts["outbox"] and opts["agent"]:
        if not opts["home"]:
            print(
                "[ERR] --outbox/--agent require --home <dir> (per-team isolation). "
                "Global mcp_servers block is no longer supported.",
                file=sys.stderr,
            )
            sys.exit(2)
        path_env = resolve_path_with_node()
        # Seed per-team config from the user's global ~/.codex/config.toml
        # (preserves [projects.*] trust entries, model defaults, etc.),
        # then scrub any inherited mcp_servers block before appending ours.
        # Without this seed, codex under CODEX_HOME=<team> treats the repo
        # as untrusted on every spawn and prompts to trust the directory.
        global_toml = os.path.expanduser("~/.codex/config.toml")
        seed = read_toml(global_toml) if os.path.abspath(global_toml) != os.path.abspath(toml_path) else ""
        content = remove_server_block(seed)
        block = build_server_block(path_env, opts["outbox"], opts["agent"])
        if content and not content.endswith("\n"):
            content += "\n"
        content = content + "\n" + block + "\n" if content.strip() else block + "\n"
        write_toml(toml_path, content)
        print(f"[OK] Wrote per-team {SERVER_NAME} to {toml_path}")
        print(f"     outbox: {opts['outbox']}")
        print(f"     agent:  {opts['agent']}")
        return

    # Default: scrub legacy global block only. No new block written.
    content = read_toml(toml_path)
    new_content = remove_server_block(content)
    if new_content != content:
        write_toml(toml_path, new_content)
        print(f"[OK] Scrubbed legacy {SERVER_NAME} block from {toml_path}")
    else:
        print(f"[OK] No {SERVER_NAME} block present in {toml_path}; nothing to do.")


if __name__ == "__main__":
    main()
