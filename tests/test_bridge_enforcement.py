"""Bridge enforcement fix tests.

Covers:
- C2: setup_gemini_mcp.py deletes legacy clau-mux-bridge (dash) key and
  leaves only clau_mux_bridge (underscore), preserving unrelated keys.
- C3+C4: setup_codex_mcp.py (a) omits the global [mcp_servers.clau_mux_bridge]
  block when called without --outbox/--agent, (b) writes a per-home config
  when --home is given, (c) uses approval_mode = "auto".
- Npm pin: both setup scripts pin clau-mux-bridge@^1.3.0 in npx args.
"""
import json
import os
import subprocess
import sys
from pathlib import Path

import pytest

SCRIPTS = Path(__file__).parent.parent / "scripts"


def _run(script: str, *args, env_override=None):
    env = os.environ.copy()
    if env_override:
        env.update(env_override)
    return subprocess.run(
        [sys.executable, str(SCRIPTS / script), *args],
        capture_output=True,
        text=True,
        env=env,
        check=False,
    )


# ── C2: Gemini legacy cleanup ────────────────────────────────────────────────

def test_gemini_setup_removes_legacy_dash_key(tmp_path):
    home = tmp_path / "home"
    gemini_dir = home / ".gemini"
    gemini_dir.mkdir(parents=True)
    settings_path = gemini_dir / "settings.json"

    seeded = {
        "mcpServers": {
            "clau-mux-bridge": {  # legacy dash
                "command": "npx",
                "args": ["-y", "clau-mux-bridge"],
                "trust": True,
            },
            "other-server": {"command": "/bin/true", "args": []},
        },
        "theme": "Default",
    }
    settings_path.write_text(json.dumps(seeded))

    result = _run("setup_gemini_mcp.py", "npx", env_override={"HOME": str(home)})
    assert result.returncode == 0, result.stderr

    data = json.loads(settings_path.read_text())
    servers = data["mcpServers"]
    assert "clau-mux-bridge" not in servers, "legacy dash key must be removed"
    assert "clau_mux_bridge" in servers, "new underscore key must exist"
    assert "other-server" in servers, "unrelated keys must be preserved"
    assert data.get("theme") == "Default", "top-level keys must be preserved"


def test_gemini_setup_pins_npm_version(tmp_path):
    home = tmp_path / "home"
    (home / ".gemini").mkdir(parents=True)

    result = _run("setup_gemini_mcp.py", "npx", env_override={"HOME": str(home)})
    assert result.returncode == 0, result.stderr

    data = json.loads((home / ".gemini" / "settings.json").read_text())
    args = data["mcpServers"]["clau_mux_bridge"]["args"]
    assert any("clau-mux-bridge@^1.3" in a for a in args), (
        f"args must pin clau-mux-bridge to ^1.3.x; got {args}"
    )


# ── C3+C4: Codex config generation ───────────────────────────────────────────

def test_codex_setup_default_omits_global_mcp_block(tmp_path):
    """Without --outbox/--agent, setup must NOT write a global mcp_servers
    block. The block only belongs in per-team config."""
    home = tmp_path / "home"
    codex_dir = home / ".codex"
    codex_dir.mkdir(parents=True)

    result = _run("setup_codex_mcp.py", env_override={"HOME": str(home)})
    assert result.returncode == 0, result.stderr

    toml_path = codex_dir / "config.toml"
    content = toml_path.read_text() if toml_path.exists() else ""
    assert "[mcp_servers.clau_mux_bridge]" not in content, (
        "global mcp_servers.clau_mux_bridge block must not be written in default mode; "
        "it causes concurrent-team identity takeover"
    )


def test_codex_setup_per_home_writes_isolated_config(tmp_path):
    """With --home <dir> --outbox <p> --agent <n>, setup writes
    <dir>/config.toml containing the mcp_servers block for that team."""
    home_root = tmp_path / "global-home"
    (home_root / ".codex").mkdir(parents=True)
    team_home = tmp_path / "team-home"
    outbox = tmp_path / "outbox.json"
    outbox.write_text("[]")

    result = _run(
        "setup_codex_mcp.py",
        "--home", str(team_home),
        "--outbox", str(outbox),
        "--agent", "security-codex",
        env_override={"HOME": str(home_root)},
    )
    assert result.returncode == 0, result.stderr

    team_toml = team_home / "config.toml"
    assert team_toml.exists(), f"per-home config.toml missing at {team_toml}"
    content = team_toml.read_text()
    assert "[mcp_servers.clau_mux_bridge]" in content
    assert str(outbox) in content
    assert "security-codex" in content
    assert 'approval_mode = "approve"' in content, (
        "per-tool approval_mode must be 'approve' — schema says this means "
        "'automatically approve tool execution without user intervention'. Verified "
        "live in bridge-xcheck team 2026-04-23: simple write_to_lead payloads are "
        "auto-approved under 'approve'. (Diag: the value 'auto' in Codex 0.123.0 "
        "prompts every time; the earlier diag-codex hang under 'approve' was a "
        "content-triggered review on a large/encrypted payload, not a config issue.)"
    )

    global_toml = home_root / ".codex" / "config.toml"
    if global_toml.exists():
        assert "[mcp_servers.clau_mux_bridge]" not in global_toml.read_text(), (
            "per-home invocation must NOT mutate global config.toml"
        )


def test_codex_setup_pins_npm_version(tmp_path):
    home_root = tmp_path / "global-home"
    (home_root / ".codex").mkdir(parents=True)
    team_home = tmp_path / "team-home"
    outbox = tmp_path / "outbox.json"
    outbox.write_text("[]")

    result = _run(
        "setup_codex_mcp.py",
        "--home", str(team_home),
        "--outbox", str(outbox),
        "--agent", "x",
        env_override={"HOME": str(home_root)},
    )
    assert result.returncode == 0, result.stderr

    content = (team_home / "config.toml").read_text()
    assert "clau-mux-bridge@^1.3" in content, (
        "npx invocation must pin clau-mux-bridge@^1.3.x"
    )


def test_codex_setup_per_home_preserves_global_projects(tmp_path):
    """Per-home config must inherit [projects.*] trust entries from the
    user's global ~/.codex/config.toml. Without this, codex under
    CODEX_HOME=<team> treats every directory as untrusted on spawn."""
    home_root = tmp_path / "global-home"
    codex_global = home_root / ".codex"
    codex_global.mkdir(parents=True)
    (codex_global / "config.toml").write_text(
        'model = "gpt-5.4"\n'
        '[projects."/some/trusted/path"]\n'
        'trust_level = "trusted"\n\n'
        '[mcp_servers.clau_mux_bridge]\n'
        'command = "stale"\n'
    )
    team_home = tmp_path / "team-home"
    outbox = tmp_path / "outbox.json"
    outbox.write_text("[]")

    result = _run(
        "setup_codex_mcp.py",
        "--home", str(team_home),
        "--outbox", str(outbox),
        "--agent", "x",
        env_override={"HOME": str(home_root)},
    )
    assert result.returncode == 0, result.stderr

    team_content = (team_home / "config.toml").read_text()
    assert 'model = "gpt-5.4"' in team_content, "global defaults must seed per-team"
    assert '[projects."/some/trusted/path"]' in team_content, (
        "project trust entries must carry over so codex does not reprompt"
    )
    # Stale mcp_servers from global must be scrubbed before our block is added
    assert team_content.count("[mcp_servers.clau_mux_bridge]") == 1


def test_codex_setup_remove_cleans_per_home(tmp_path):
    """--remove must clean the per-home config when --home is given."""
    team_home = tmp_path / "team-home"
    team_home.mkdir()
    (team_home / "config.toml").write_text(
        "[mcp_servers.clau_mux_bridge]\ncommand = \"old\"\n"
    )
    home_root = tmp_path / "global-home"
    (home_root / ".codex").mkdir(parents=True)

    result = _run(
        "setup_codex_mcp.py",
        "--remove",
        "--home", str(team_home),
        env_override={"HOME": str(home_root)},
    )
    assert result.returncode == 0, result.stderr

    content = (team_home / "config.toml").read_text() if (team_home / "config.toml").exists() else ""
    assert "[mcp_servers.clau_mux_bridge]" not in content
