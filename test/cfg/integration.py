"""Five shared config verbs through the real generated CLI/MCP and daemon."""
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import tempfile
import time

exe = str(Path(sys.argv[1]).resolve())
with tempfile.TemporaryDirectory(prefix="venom-cfg-") as directory:
    root = Path(directory)
    socket = str(root / "echo.sock")
    env = dict(os.environ, XDG_CONFIG_HOME=str(root / "config"), XDG_STATE_HOME=str(root / "state"),
               XDG_CONFIG_DIRS=f"{root / 'etc-empty'}:{root / 'etc'}")
    env.pop("VENOM_ECHO_TOKEN", None)
    owner = dict(env, VENOM_ECHO_TOKEN="@owner")
    config_file = root / "config/venom-echo/config.zon"
    defaults_file = root / "etc/venom-echo/defaults.zon"

    def call(*args, code=0, authority=False):
        result = subprocess.run([exe, *args, "--socket", socket, "--json"], stdin=subprocess.DEVNULL,
                                capture_output=True, text=True, env=owner if authority else env, timeout=5)
        assert result.returncode == code, (args, result.returncode, result.stdout, result.stderr)
        assert not result.stderr, result.stderr
        return json.loads(result.stdout)

    def daemon():
        proc = subprocess.Popen([exe, "serve", "--socket", socket, "--json"], stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env)
        deadline = time.monotonic() + 5
        while not Path(socket).exists():
            assert proc.poll() is None, proc.communicate()
            assert time.monotonic() < deadline, "daemon startup timed out"
            time.sleep(0.01)
        return proc

    def stop(proc, warnings=False):
        proc.send_signal(signal.SIGTERM)
        out, err = proc.communicate(timeout=5)
        assert proc.returncode == 0 and json.loads(out) == {}, (proc.returncode, out, err)
        assert not err or (warnings and "config watcher:" in err), err

    proc = daemon()
    try:
        assert call("config", "get", "--key=appearance.prefix") == {"content": '""', "source": "builtin", "sources": [{"key": "appearance.prefix", "source": "builtin"}]}
        assert not config_file.exists()
        assert call("config", "check") == {"valid": True}
        schema = json.loads(call("config", "schema")["content"])
        assert schema["properties"]["suffix"]["x-venom-restart-required"] is True
        assert schema["properties"]["api_token"]["writeOnly"] is True
        assert schema["properties"]["count"]["default"] == 4
        assert call("config", "set", "--key=count", "--value=7", code=4)["error"]["code"] == "denied.admin"
        assert call("config", "reload", code=4)["error"]["code"] == "denied.admin"
        assert call("config", "set", "--key=appearance.prefix", '--value="hot:"', authority=True) == {"changed": True, "restart_required": False}
        before = config_file.read_bytes()
        assert config_file.stat().st_mode & 0o777 == 0o600
        assert call("echo", "--text=x") == {"text": "x"}
        time.sleep(0.7)  # own set is not an external watcher reload
        assert call("echo", "--text=x") == {"text": "x"}
        assert call("config", "get", "--key=appearance.prefix")["content"] == '"hot:"'
        assert call("config", "reload", authority=True) == {"changed": True, "restart_required": False}
        assert call("echo", "--text=x") == {"text": "hot:x"}
        assert call("config", "set", "--key=appearance.prefix", '--value="hot:"', authority=True)["changed"] is False
        assert config_file.read_bytes() == before
        failure = call("config", "set", "--key=count", "--value=0", code=2, authority=True)["error"]
        assert failure["code"] == "invalid_params.config_value" and failure["data"]["key"] == "count"
        assert config_file.read_bytes() == before
        assert call("config", "set", "--key=missing", "--value=0", code=2, authority=True)["error"]["data"]["param"] == "key"
        call("config", "set", "--key=count", '--value=@import("bad.zig")', code=2, authority=True)
        call("config", "set", "--key=api_token", '--value="must-not-persist"', code=1, authority=True)
        assert b"must-not-persist" not in config_file.read_bytes()
        assert "<redacted>" in call("config", "get")["content"]
        assert call("config", "set", "--key=suffix", '--value="!"', authority=True)["restart_required"] is True
        assert call("config", "reload", authority=True) == {"changed": False, "restart_required": True}
        assert call("echo", "--text=x") == {"text": "hot:x"}
        # An independent external edit is watched; invalid edits keep active state.
        config_file.write_text('.{ .appearance = .{ .prefix = "external:" }, .suffix = "!" }')
        deadline = time.monotonic() + 4
        while call("echo", "--text=x")["text"] != "external:x":
            assert time.monotonic() < deadline
            time.sleep(0.05)
        config_file.write_text('.{ .count = 0 }')
        call("config", "check", code=2)
        time.sleep(0.7)
        assert call("echo", "--text=x") == {"text": "external:x"}
        # set can repair a parsed configuration that fails semantic validation.
        call("config", "set", "--key=count", "--value=5", authority=True)
        call("config", "check")
        # MCP uses the same catalog, parameters, grants and success payload.
        requests = [
            {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "cfg-test", "version": "0"}}},
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
            {"jsonrpc": "2.0", "id": 2, "method": "tools/call", "params": {"name": "config_dget", "arguments": {"key": "count"}}},
        ]
        result = subprocess.run([exe, "mcp", "--socket", socket], input="".join(json.dumps(r) + "\n" for r in requests), capture_output=True, text=True, env=env, timeout=5)
        assert result.returncode == 0 and not result.stderr, result
        reply = list(map(json.loads, result.stdout.splitlines()))[-1]
        assert reply["result"]["structuredContent"]["result"] == {"content": "5", "source": "user", "sources": [{"key": "count", "source": "user"}]}, reply
    finally:
        stop(proc, warnings=True)
    # A distribution's defaults.zon (first match in
    # $XDG_CONFIG_DIRS) sits below the user file, which overrides it.
    config_file.unlink()
    defaults_file.parent.mkdir(parents=True)
    defaults_file.write_text('.{ .appearance = .{ .prefix = "os:" }, .suffix = "~" }')
    proc = daemon()
    try:
        assert call("echo", "--text=x") == {"text": "os:x~"}
        got = call("config", "get", "--key=appearance.prefix")
        assert got == {"content": '"os:"', "source": "defaults", "sources": [{"key": "appearance.prefix", "source": "defaults"}]}, got
        assert call("config", "set", "--key=appearance.prefix", '--value="me:"', authority=True)["changed"] is True
        assert config_file.read_text() == '.{ .appearance = .{ .prefix = "me:", }, }', config_file.read_text()
        assert defaults_file.read_text() == '.{ .appearance = .{ .prefix = "os:" }, .suffix = "~" }'
        call("config", "reload", authority=True)
        assert call("echo", "--text=x") == {"text": "me:x~"}
        sources = {e["key"]: e["source"] for e in call("config", "get")["sources"]}
        assert sources["appearance.prefix"] == "user" and sources["suffix"] == "defaults" and sources["count"] == "builtin", sources
        # An invalid defaults file fails check like an invalid user file.
        defaults_file.write_text('.{ .count = "many" }')
        failure = call("config", "check", code=2)["error"]
        assert failure["code"] == "invalid_params.config_zon" and failure["data"] == {"param": "", "key": "count", "source": "defaults"}, failure
        defaults_file.write_text('.{ .appearance = .{ .prefix = "os:" }, .suffix = "~" }')
        assert call("config", "check") == {"valid": True}
    finally:
        stop(proc, warnings=True)
    defaults_file.unlink()

    # Restart applies persisted restart-only values and defaults normally.
    config_file.write_text('.{ .suffix = "!", .appearance = .{ .prefix = "restart:" } }')
    proc = daemon()
    try:
        assert call("echo", "--text=x") == {"text": "restart:x!"}
    finally:
        stop(proc)
