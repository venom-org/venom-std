#!/usr/bin/env python3
"""Agent-contract conformance suite.

Runs a product binary built on venom-std through the agent-contract conformance
checklist, as an agent would: no TTY, stdin closed, JSON on stdout only.

    python3 agent_contract.py <binary> <profile.json>

From a product's build.zig, prefer venom-std's helper:

    const venom_std = b.dependency("venom_std", .{});
    const check = @import("venom_std").addConformance(b, .{
        .suite = venom_std.path("conformance/agent_contract.py"),
        .exe = my_daemon,
        .profile = b.path("conformance.json"),
    });
    b.step("test-conformance", "Agent-contract conformance").dependOn(&check.step);

The profile is a JSON object naming the product's own verbs the suite
needs; everything else is shared venom-std surface. Keys (see
venom-echo.json for a complete example):

    tool        tool name (`^[a-z][a-z0-9-]{0,31}$`); the token variable is derived from it
    read        {"args": [...], "result": {...}}       a read-only verb call
    usage_error {"args": [...], "code": "invalid_params.*"}
    mutation    {"args": [...], "mcp": {"name", "arguments"},
                 "observe": {"args": [...], "before": {...}, "after": {...}}}
                a verb that needs more than `read`; `observe` must show
                whether its handler ran
    stream      {"args": [...], "items": [...], "slow_args": [...],
                 "error_args": [...], "error_code": "..."}
                a finite streaming verb, a slow one to cancel, and a call
                that ends with a terminal error after at least one item.
                Alternatively {"kind": "events"} for products whose only
                ordinary stream is events: finite snapshot/checkpoint,
                SIGINT cancellation, and terminal denial after token revocation
                are exercised using shared verbs, with dynamic envelopes.
    config      {"key", "value", "observe": {"args", "before", "after"},
                 "secret_key" (optional)}
                a hot-reloadable key whose effect `observe` shows
    defaults    ZON text (optional) written to $XDG_CONFIG_DIRS/<tool>/defaults.zon
                before the daemon starts, for a product whose shipped default
                is outside what the contract covers (venomx: grants.isolation)

Every product process runs with HOME, TMPDIR and every XDG base dir
(config, state, data, cache, and a 0700 XDG_RUNTIME_DIR) inside a temp root,
so the suite never reaches the caller's real daemons, sockets or state.

Each checklist item prints `ok` or `not ok`; the exit status is 0 only if
every item passed. Items a library cannot judge (action parity,
OSC ingestion) are reported as `skip` with the reason.
"""
import datetime
import json
import os
from pathlib import Path
import re
import select
import shutil
import signal
import socket as sockets
import subprocess
import sys
import tempfile
import time
import traceback

TIMEOUT = 15


# Every XDG base directory (and HOME, TMPDIR) the product could resolve.
# Each points inside the run's temp root so conformance never reaches the
# caller's real config, state, data, cache, or runtime dir (owner files,
# sibling daemons' sockets, installed data).
ISOLATED_VARS = ("HOME", "TMPDIR", "XDG_CONFIG_HOME", "XDG_CONFIG_DIRS", "XDG_STATE_HOME",
                 "XDG_DATA_HOME", "XDG_DATA_DIRS", "XDG_CACHE_HOME", "XDG_RUNTIME_DIR")


def isolated_env(root, home):
    """The isolated part of every product environment, rooted at `root`.
    The runtime dir is created 0700 (XDG base dir spec) with a one-letter
    name so socket paths under it stay short enough for sun_path."""
    root = Path(root)
    runtime = root / "r"
    runtime.mkdir(mode=0o700, exist_ok=True)
    runtime.chmod(0o700)
    tmp = root / "tmp"
    tmp.mkdir(mode=0o700, exist_ok=True)
    env = {
        "HOME": str(home),
        "TMPDIR": str(tmp),
        "XDG_CONFIG_HOME": str(root / "config"),
        "XDG_CONFIG_DIRS": str(root / "xdg"),
        "XDG_STATE_HOME": str(root / "state"),
        "XDG_DATA_HOME": str(root / "data"),
        "XDG_DATA_DIRS": str(root / "xdg-data"),
        "XDG_CACHE_HOME": str(root / "cache"),
        "XDG_RUNTIME_DIR": str(runtime),
    }
    assert set(env) == set(ISOLATED_VARS)
    return env


def short_tempdir():
    """Parent for the run's temp root. Unix socket paths must fit sun_path,
    so prefer /tmp over a long caller TMPDIR (macOS)."""
    return "/tmp" if os.path.isdir("/tmp") and os.access("/tmp", os.W_OK | os.X_OK) else None


class Product:
    def __init__(self, exe, profile, root):
        self.exe = str(Path(exe).resolve())
        self.p = profile
        self.tool = profile["tool"]
        self.token_var = re.sub(r"[^A-Z0-9]", "_", self.tool.upper()) + "_TOKEN"
        self.root = Path(root)
        self.socket = str(self.root / "d.sock")
        self.home = self.root / "home"
        self.home.mkdir()
        base = {k: v for k, v in os.environ.items() if not k.endswith("_TOKEN") and not k.startswith("VENOM_")}
        base.update(isolated_env(self.root, self.home))
        self.env = base
        self.owner = dict(base, **{self.token_var: "@owner"})
        self.config_file = self.root / "config" / self.tool / "config.zon"
        # Optional distribution defaults (the cfg `defaults` layer), so a product
        # whose shipped default differs can be tested in the mode the contract
        # covers, e.g. venomx with `grants.isolation = true`.
        if profile.get("defaults"):
            seeded = self.root / "xdg" / self.tool / "defaults.zon"
            seeded.parent.mkdir(parents=True, exist_ok=True)
            seeded.write_text(profile["defaults"] + "\n")
        self.daemon = None

    # --- processes -------------------------------------------------------

    def run(self, *args, code=0, env=None, socket=True, json_flag=True, input=None):
        """Run one CLI invocation headless; check its exit code and stderr."""
        argv = [self.exe, *args] + (["--socket", self.socket] if socket else []) + (["--json"] if json_flag else [])
        r = subprocess.run(argv, input=input, stdin=None if input is not None else subprocess.DEVNULL,
                           capture_output=True, text=True, timeout=TIMEOUT, env=env or self.env, start_new_session=True)
        assert r.returncode == code, f"{args}: exit {r.returncode}, want {code}\nstdout: {r.stdout}\nstderr: {r.stderr}"
        assert r.stderr == "", f"{args}: diagnostics on stderr: {r.stderr!r}"
        return r

    def json(self, *args, code=0, env=None, socket=True, result_exit=False):
        """One JSON line. `result_exit`: a nonzero exit from the verb's result
        exit policy (e.g. doctor's status), so stdout is a result, not an error."""
        out = self.run(*args, code=code, env=env, socket=socket).stdout
        assert out.endswith("\n") and out.count("\n") == 1, f"{args}: stdout is not exactly one JSON line: {out!r}"
        value = json.loads(out)
        if code == 0 or result_exit:
            assert not (isinstance(value, dict) and set(value) == {"error"}), f"{args}: success exit with error wrapper"
        else:
            assert set(value) == {"error"} and {"code", "message"} <= set(value["error"]), value
        return value

    def error(self, *args, code, env=None, socket=True):
        return self.json(*args, code=code, env=env, socket=socket)["error"]

    def start(self):
        self.daemon = subprocess.Popen([self.exe, "serve", "--socket", self.socket, "--json"], stdin=subprocess.DEVNULL,
                                       stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=self.env, start_new_session=True)
        deadline = time.monotonic() + TIMEOUT
        while True:
            assert self.daemon.poll() is None, f"daemon exited: {self.daemon.communicate()}"
            assert time.monotonic() < deadline, "daemon did not start listening"
            if Path(self.socket).exists():
                try:
                    self.run("ping")
                    return
                except AssertionError:
                    pass
            time.sleep(0.02)

    def stop(self):
        d, self.daemon = self.daemon, None
        if d is None:
            return
        if d.poll() is None:
            d.send_signal(signal.SIGTERM)
        try:
            out, err = d.communicate(timeout=TIMEOUT)
        except subprocess.TimeoutExpired:
            d.kill()
            d.communicate()
            raise AssertionError("daemon did not stop on SIGTERM")
        assert d.returncode == 0 and out == "{}\n", f"serve --json did not end cleanly: {d.returncode} {out!r} {err!r}"
        assert not Path(self.socket).exists(), "clean shutdown left the socket behind"

    def mcp(self, requests, env=None):
        init = [{"jsonrpc": "2.0", "id": 0, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "conformance", "version": "0"}}},
                {"jsonrpc": "2.0", "method": "notifications/initialized"}]
        msgs = init + [dict(r, jsonrpc="2.0", id=i + 1) for i, r in enumerate(requests)]
        r = subprocess.run([self.exe, "mcp", "--socket", self.socket], input="".join(json.dumps(m) + "\n" for m in msgs),
                           capture_output=True, text=True, timeout=TIMEOUT, env=env or self.env, start_new_session=True)
        assert r.returncode == 0 and r.stderr == "", (r.returncode, r.stderr)
        replies = {m["id"]: m for m in map(json.loads, r.stdout.splitlines())}
        assert sorted(replies) == list(range(len(requests) + 1)), r.stdout
        return [replies[i + 1] for i in range(len(requests))]

    def tool_call(self, name, arguments, env=None):
        return self.mcp([{"method": "tools/call", "params": {"name": name, "arguments": arguments}}], env=env)[0]["result"]

    def help_verbs(self):
        """(wire name, grant) for every verb, from generated `--help --json`."""
        text = self.json("--help", socket=False)["help"]
        return re.findall(r"wire: (\S+); grant: (\S+)", text)


def mcp_name(wire):
    """MCP tool name from a wire verb name: `.` becomes `_d` and `_` becomes `__`."""
    return wire.replace("_", "__").replace(".", "_d")


def ndjson(text):
    lines = text.splitlines()
    assert text == "" or text.endswith("\n"), "stream output not newline-terminated"
    out = []
    for line in lines:
        assert line and line == line.strip() and "\n" not in line, f"not compact NDJSON: {line!r}"
        out.append(json.loads(line))
    return out


def stream_kind(profile):
    """The legacy product-stream form remains the default; never silently skip."""
    stream = profile["stream"]
    kind = stream.get("kind", "product")
    if kind == "events":
        assert set(stream) == {"kind"}, "events stream profile accepts only kind"
    else:
        assert kind == "product", f"unknown stream kind: {kind!r}"
        assert {"args", "items", "slow_args", "error_args", "error_code"} <= set(stream), "incomplete product stream profile"
    return kind


def event_items(items, tool, *, snapshot=False):
    """Validate event structure and order without fixing UUID/time values."""
    assert items, "empty event stream"
    source = None
    previous = -1
    for e in items:
        assert isinstance(e, dict) and {"seq", "ts", "source", "type", "data"} <= set(e), e
        assert type(e["seq"]) is int and 0 <= e["seq"] <= 9007199254740991, e
        assert e["seq"] >= previous, "event sequence went backwards"
        previous = e["seq"]
        assert isinstance(e["source"], str) and re.fullmatch(re.escape(tool) + r"/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}", e["source"]), e
        if source is None:
            source = e["source"]
        assert e["source"] == source, "event source changed within subscription"
        assert isinstance(e["ts"], str) and re.fullmatch(r"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}(?:\.\d+)?Z", e["ts"]), e
        datetime.datetime.fromisoformat(e["ts"].replace("Z", "+00:00"))
        assert isinstance(e["type"], str) and re.fullmatch(r"[a-z][a-z0-9_]*(?:\.[a-z][a-z0-9_]*)*", e["type"]), e
        assert isinstance(e["data"], dict), e
        if e["type"] == "stream.checkpoint":
            assert e["data"] == {}, e
        elif e["type"] == "state.snapshot":
            data = e["data"]
            assert data.get("reason") in ("initial", "expired", "source_changed"), e
            assert type(data.get("complete")) is bool and isinstance(data.get("entities"), list), e
            for entity in data["entities"]:
                assert isinstance(entity, dict) and all(isinstance(entity.get(k), str) for k in ("resource", "entity_type", "content")), entity
                assert isinstance(json.loads(entity["content"]), dict), entity
    if snapshot:
        assert items[-1]["type"] == "stream.checkpoint", "finite events did not end at checkpoint (or emitted final success)"
        chunks = items[:-1]
        assert chunks and all(e["type"] == "state.snapshot" for e in chunks), "initial snapshot missing"
        assert all(e["seq"] == items[-1]["seq"] for e in chunks), "snapshot/checkpoint watermark mismatch"
        assert [e["data"]["complete"] for e in chunks] == [False] * (len(chunks) - 1) + [True], "incomplete or repeated snapshot commit"
        entities = [entity["resource"] for e in chunks for entity in e["data"]["entities"]]
        assert len(entities) == len(set(entities)), "duplicate snapshot entity"


def checkpoint(proc, tool):
    """Read through the initial checkpoint with a deadline, retaining read-ahead.

    Use binary unbuffered pipes: select() cannot see a TextIOWrapper's buffered
    lines, and readline() alone could block forever on a partial/missing line.
    """
    pending = bytearray()
    items = []
    deadline = time.monotonic() + TIMEOUT
    size = 0
    while True:
        while b"\n" not in pending:
            remaining = deadline - time.monotonic()
            assert remaining > 0 and select.select([proc.stdout], [], [], max(0, remaining))[0], "events did not reach initial checkpoint"
            chunk = os.read(proc.stdout.fileno(), 65536)
            assert chunk, "events ended before initial checkpoint"
            size += len(chunk)
            assert size <= 16 * 1024 * 1024, "initial events exceed test read budget"
            pending.extend(chunk)
        line, _, rest = pending.partition(b"\n")
        pending = bytearray(rest)
        items.extend(ndjson(line.decode() + "\n"))
        if items[-1].get("type") == "stream.checkpoint":
            event_items(items, tool, snapshot=True)
            assert proc.poll() is None, "follow stream completed before action"
            return bytes(pending)


def event_follow(p, *, revoke=False):
    """Exercise a real live stream through cancellation or lost read authority."""
    env = p.env
    issued = None
    if revoke:
        issued = p.json("grant", "issue", '--grants=[{"right":"read","scope":"config:root"}]', "--ttl=60", env=p.owner)
        env = dict(p.env, **{p.token_var: issued["token"]})
    proc = subprocess.Popen([p.exe, "events", '--resources=["config:root"]', "--socket", p.socket, "--json"],
                            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            env=env, start_new_session=True, bufsize=0)
    try:
        pending = checkpoint(proc, p.tool)
        if revoke:
            p.json("grant", "revoke", f"--principal={issued['principal']}", env=p.owner)
        else:
            proc.send_signal(signal.SIGINT)
        out, err = proc.communicate(timeout=TIMEOUT)
        lines = ndjson((pending + out).decode())
        assert err == b"", err
        if revoke:
            assert proc.returncode == 4, f"revoked events exited {proc.returncode}, want 4"
            assert lines and set(lines[-1]) == {"error"} and lines[-1]["error"]["code"] == "denied.event_scope", "missing terminal denied.event_scope"
            trailing = lines[:-1]
        else:
            assert proc.returncode == 8, f"cancelled events exited {proc.returncode}, want 8"
            trailing = lines
            if lines and "error" in lines[-1]:
                assert set(lines[-1]) == {"error"} and lines[-1]["error"]["code"].startswith("cancelled"), lines[-1]
                trailing = lines[:-1]
        if trailing:
            event_items(trailing, p.tool)
    finally:
        if proc.poll() is None:
            proc.kill()
        proc.communicate()
        if issued is not None:
            # Also revoke on assertion/timeout so failures do not leave credentials.
            p.json("grant", "revoke", f"--principal={issued['principal']}", env=p.owner)


# --- checklist ----------------------------------------------------------

def check_binary(p):
    """One executable serves and invokes verbs; locking; exit 6 without a daemon."""
    missing = str(p.root / "none.sock")
    err = p.error(*p.p["read"]["args"], "--socket", missing, code=6, socket=False)
    assert err["code"].startswith("unavailable"), err
    p.start()
    conflict = p.error("serve", code=5)
    assert conflict["code"] == "conflict.already_running", conflict
    p.run("ping")  # the first instance survived the second one's attempt


def check_generation(p):
    """CLI help, MCP tools/list, docs and completions agree on one schema."""
    verbs = p.help_verbs()
    docs = p.run("docs", socket=False, json_flag=False).stdout
    # Generated docs record each verb's local dispatch and interactivity.
    # Compare that catalog with help first, so missing documentation cannot
    # silently remove a remote verb from the MCP agreement check.
    records = {}
    for section in re.split(r"(?m)^### ", docs)[1:]:
        wire = re.search(r"(?m)^- Wire name: `([^`]+)`$", section)
        assert wire, "command docs lack wire name"
        wire = wire[1]
        assert wire not in records, f"duplicate docs for {wire}"
        mcp = re.search(r"(?m)^- MCP tool: (.+)$", section)
        assert mcp, f"docs lack MCP metadata for {wire}"
        local = mcp[1] == "none (local command)"
        assert local or mcp[1] == f"`{mcp_name(wire)}`", f"invalid MCP metadata for {wire}"
        interactive = "\n- Interactive: needs a terminal on stdin and stdout\n" in section
        assert not interactive or local, f"interactive remote verb {wire}"
        records[wire] = (local, interactive)
    assert set(records) == {w for w, _ in verbs}, "docs and CLI help commands differ"
    remote = sorted(w for w, (local, _) in records.items() if not local)
    assert remote, "no remote verbs in --help --json"
    tools = p.mcp([{"method": "tools/list"}])[0]["result"]["tools"]
    names = sorted(t["name"] for t in tools)
    want = sorted(mcp_name(w) for w in remote)
    assert names == want, f"MCP tools {names} != CLI verbs {want}"
    for t in tools:
        assert t["inputSchema"]["type"] == "object" and t["inputSchema"]["additionalProperties"] is False, t["name"]
    skill = p.run("skill", json_flag=False).stdout
    for wire, (local, interactive) in records.items():
        spelled = wire.replace(".", " ").replace("_", "-")
        command = f"`{p.tool} {spelled}`"
        assert command in docs, f"docs lack {wire}"
        if interactive:
            assert command not in skill, f"skill includes interactive command {wire}"
        else:
            assert command in skill, f"skill lacks {wire}"
    for shell in ("bash", "zsh", "fish"):
        script = p.json("completions", "--shell", shell, socket=False)["content"]
        for wire in records:
            assert wire.split(".")[0].replace("_", "-") in script, f"{shell} completions lack {wire}"
    assert skill.startswith(f"---\nname: {p.tool}\n"), skill[:80]


def check_json(p):
    """--json success, usage error, denied and stable exit codes."""
    read = p.p["read"]
    assert p.json(*read["args"]) == read["result"]
    human = p.run(*read["args"], json_flag=False)
    assert human.stdout.endswith("\n")
    usage = p.p["usage_error"]
    err = p.error(*usage["args"], code=2)
    assert err["code"] == usage["code"], err
    err = p.error(*usage["args"], code=2, socket=False)  # validated before connecting
    assert err["code"] == usage["code"], err
    err = p.error(*p.p["mutation"]["args"], code=4)
    assert err["code"].startswith("denied."), err
    help_json = p.json(*read["args"][:1], "--help", socket=False)
    assert set(help_json) == {"help"} and help_json["help"], help_json
    assert set(p.json("serve", "--help", socket=False)) == {"help"}


def check_streams(p):
    """events --json replay and product streams: completion, error, cancel."""
    first = ndjson(p.run("events", "--follow=false").stdout)
    event_items(first, p.tool, snapshot=True)
    cursor = f"{first[-1]['source']}:{first[-1]['seq']}"
    # A config change is published, and replay after the old cursor shows it.
    cfg = p.p["config"]
    p.json("config", "set", f"--key={cfg['key']}", f"--value={cfg['value']}", env=p.owner)
    p.json("config", "reload", env=p.owner)
    replay = ndjson(p.run("events", f"--after={cursor}", "--follow=false").stdout)
    event_items(replay, p.tool)
    types = [e["type"] for e in replay]
    assert "config.changed" in types and "config.reloaded" in types and types[-1] == "stream.checkpoint", types
    seqs = [e["seq"] for e in replay]
    assert seqs == sorted(seqs) and seqs[0] > first[-1]["seq"] - 1, seqs
    # Replaying from the newest cursor yields nothing already seen.
    cursor = f"{replay[-1]['source']}:{replay[-1]['seq']}"
    again = ndjson(p.run("events", f"--after={cursor}", "--follow=false").stdout)
    event_items(again, p.tool)
    assert [e["type"] for e in again] == ["stream.checkpoint"], again
    filtered = ndjson(p.run("events", "--types=[\"config.*\"]", "--follow=false").stdout)
    event_items(filtered, p.tool, snapshot=True)
    assert all(e["type"].startswith(("config.", "state.", "stream.")) for e in filtered), filtered
    bad = p.error("events", "--types=[\"x*\"]", "--follow=false", code=2)
    assert bad["code"] == "invalid_params.event_filter", bad
    if stream_kind(p.p) == "events":
        # Completion was checked above against live dynamic envelopes. These
        # are exercised, not skipped, when there is no separate product stream.
        event_follow(p)
        event_follow(p, revoke=True)
        p.run("ping")
        return
    # Product stream: items only, no final success line.
    s = p.p["stream"]
    assert ndjson(p.run(*s["args"]).stdout) == s["items"]
    # Terminal error: items, then the error wrapper and its exit code.
    r = subprocess.run([p.exe, *s["error_args"], "--socket", p.socket, "--json"], stdin=subprocess.DEVNULL,
                       capture_output=True, text=True, timeout=TIMEOUT, env=p.env, start_new_session=True)
    lines = ndjson(r.stdout)
    assert len(lines) >= 2 and "error" not in lines[0] and lines[-1]["error"]["code"] == s["error_code"], lines
    assert r.returncode not in (0, 8) and r.stderr == "", (r.returncode, r.stderr)
    # Cancellation: SIGINT after the first item ends with exit 8, no success.
    for argv in ([*s["slow_args"]], ["events"]):
        proc = subprocess.Popen([p.exe, *argv, "--socket", p.socket, "--json"], stdin=subprocess.DEVNULL,
                                stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=p.env, start_new_session=True)
        try:
            assert select.select([proc.stdout], [], [], TIMEOUT)[0], f"{argv}: no first item"
            first_item = json.loads(proc.stdout.readline())
            assert "error" not in first_item, first_item
            proc.send_signal(signal.SIGINT)
            out, err = proc.communicate(timeout=TIMEOUT)
            assert proc.returncode == 8 and err == "", (argv, proc.returncode, err)
            for line in ndjson(out):
                assert "error" not in line or line["error"]["code"].startswith("cancelled"), line
        finally:
            if proc.poll() is None:
                proc.kill()
                proc.communicate()
    p.run("ping")


def check_skills(p):
    """skill output, install for all targets, default roots, no-op, conflict, replace."""
    text = p.run("skill", json_flag=False).stdout
    assert p.json("skill") == {"content": text}
    assert "read-only" in text.lower()
    defaults = {"claude-code": p.home / ".claude/skills", "codex": p.home / ".agents/skills", "opencode": p.home / ".config/opencode/skills"}
    override = p.root / "skills"
    override.mkdir()
    denied = p.error("skill", "install", "--target=codex", "--directory", str(override), code=4)
    assert denied["code"].startswith("denied."), denied
    for target, root in defaults.items():
        res = p.json("skill", "install", f"--target={target}", env=p.owner)
        want = (root / p.tool / "SKILL.md").resolve()
        assert res == {"target": target, "path": str(want), "changed": True}, res
        assert want.read_text() == text
        # An explicit root takes precedence over the target default.
        explicit = override / target
        explicit.mkdir()
        res = p.json("skill", "install", f"--target={target}", "--directory", str(explicit), env=p.owner)
        assert res["path"] == str((explicit / p.tool / "SKILL.md").resolve()) and res["changed"] is True, res
        assert Path(res["path"]).read_bytes() == want.read_bytes()
    again = p.json("skill", "install", "--target=codex", env=p.owner)
    assert again["changed"] is False, again
    installed = defaults["codex"] / p.tool / "SKILL.md"
    installed.write_text("edited\n")
    assert p.error("skill", "install", "--target=codex", code=5, env=p.owner)["code"] == "conflict.skill_exists"
    assert installed.read_text() == "edited\n"
    assert p.json("skill", "install", "--target=codex", "--replace=true", env=p.owner)["changed"] is True
    assert installed.read_text() == text
    assert p.error("skill", "install", "--target=nope", code=2, env=p.owner)["code"].startswith("invalid_params")
    assert p.error("skill", "install", "--target=codex", "--directory=relative", code=2, env=p.owner)["code"] == "invalid_params.skill_directory"


def check_config(p):
    """All five config verbs, invalid input, no-op writes, failed reload, redaction."""
    cfg = p.p["config"]
    schema = json.loads(p.json("config", "schema")["content"])
    assert schema.get("type") == "object" and cfg["key"].split(".")[0] in schema["properties"], schema
    assert p.json("config", "check") == {"valid": True}
    whole = p.json("config", "get")
    assert set(whole) == {"content", "source", "sources"}, whole
    assert whole["source"] in ("builtin", "defaults", "user") and all(set(e) == {"key", "source"} for e in whole["sources"]), whole
    obs = cfg["observe"]
    # Earlier checks may have applied the value already; start from the default.
    p.json("config", "set", f"--key={cfg['key']}", f"--value={cfg['default']}", env=p.owner)
    p.json("config", "reload", env=p.owner)
    assert p.json(*obs["args"]) == obs["before"]
    assert p.error("config", "set", f"--key={cfg['key']}", f"--value={cfg['value']}", code=4)["code"].startswith("denied.")
    assert p.json("config", "set", f"--key={cfg['key']}", f"--value={cfg['value']}", env=p.owner)["changed"] is True
    assert p.json(*obs["args"]) == obs["before"], "set must not reload implicitly"
    assert p.json("config", "set", f"--key={cfg['key']}", f"--value={cfg['value']}", env=p.owner)["changed"] is False
    got = p.json("config", "get", f"--key={cfg['key']}")
    assert got["content"] == cfg["value"] and got["source"] == "user", got
    assert p.json("config", "reload", env=p.owner) == {"changed": True, "restart_required": False}
    assert p.json(*obs["args"]) == obs["after"]
    assert p.json("config", "reload", env=p.owner)["changed"] is False
    before = p.config_file.read_bytes()
    for value in ("@import(\"x.zig\")", ".{ .unterminated = "):
        assert p.error("config", "set", f"--key={cfg['key']}", f"--value={value}", code=2, env=p.owner)["code"].startswith("invalid_params")
    assert p.error("config", "set", "--key=conformance_no_such_key", "--value=1", code=2, env=p.owner)["code"].startswith("invalid_params")
    assert p.config_file.read_bytes() == before, "failed set changed the file"
    if "secret_key" in cfg:
        assert "<redacted>" in p.json("config", "get")["content"]
        assert p.json("config", "get", f"--key={cfg['secret_key']}")["content"] == '"<redacted>"'
        assert json.loads(p.json("config", "schema")["content"])["properties"][cfg["secret_key"]].get("writeOnly") is True
    # A broken file fails check and reload, and the active snapshot survives.
    p.config_file.write_text(".{ .broken = ")
    assert p.error("config", "check", code=2)["code"].startswith("invalid_params")
    assert p.error("config", "reload", code=2, env=p.owner)["code"].startswith("invalid_params")
    assert p.json(*obs["args"]) == obs["after"]
    p.config_file.write_bytes(before)
    assert p.json("config", "check") == {"valid": True}
    # Leave the default active for later checks.
    p.json("config", "set", f"--key={cfg['key']}", f"--value={cfg['default']}", env=p.owner)
    p.json("config", "reload", env=p.owner)
    assert p.json(*obs["args"]) == obs["before"]


def check_doctor(p):
    """doctor ok/warn/fail reports, digest skew, runnable fixes, no-daemon error."""
    report = p.json("doctor")
    assert report["status"] == 0, report
    ids = [c["id"] for c in report["checks"]]
    assert "config.valid" in ids and any(i.startswith("runtime.") for i in ids), ids
    for c in report["checks"]:
        assert set(c) == {"id", "status", "message", "fix"} and c["status"] in ("ok", "warn", "fail") and c["fix"], c
        assert subprocess.run(["sh", "-n", "-c", c["fix"]], capture_output=True).returncode == 0, f"fix is not POSIX sh: {c['fix']}"
    human = p.run("doctor", json_flag=False).stdout
    assert "[ok] config.valid" in human and "fix: " in human, human
    # Schema skew: the CLI supplies its own complete-schema digest,
    # which matches the one hello advertises; a stale one is a warning only.
    with sockets.socket(sockets.AF_UNIX) as raw:
        raw.settimeout(TIMEOUT)
        raw.connect(p.socket)
        wire = raw.makefile("rwb", buffering=0)
        wire.write(b'{"id":1,"verb":"hello","params":{"proto":[1]}}\n')
        advertised = json.loads(wire.readline())["ok"].get("schema")
        wire.close()
    assert isinstance(advertised, str) and re.fullmatch(r"sha256:[0-9a-f]{64}", advertised), advertised
    digest = {c["id"]: c for c in report["checks"]}.get("schema.digest")
    assert digest and digest["status"] == "ok" and advertised in digest["message"], digest
    stale = "sha256:" + "0" * 64
    skew = p.json("doctor", f"--client-schema={stale}")
    assert skew["status"] == 0, skew
    warned = [c for c in skew["checks"] if c["status"] != "ok"]
    assert [(c["id"], c["status"]) for c in warned] == [("schema.digest", "warn")], warned
    assert stale in warned[0]["message"] and advertised in warned[0]["message"], warned
    assert "[warn] schema.digest" in p.run("doctor", f"--client-schema={stale}", json_flag=False).stdout
    mcp = p.tool_call("doctor", {"client_schema": stale})
    assert mcp["isError"] is False and mcp["structuredContent"]["result"]["status"] == 0, mcp
    # A failing check: status 1, exit 1 through the result exit policy.
    saved = p.config_file.read_bytes() if p.config_file.exists() else None
    p.config_file.parent.mkdir(parents=True, exist_ok=True)
    p.config_file.write_text(".{ .broken = ")
    try:
        bad = p.json("doctor", code=1, result_exit=True)
        assert bad["status"] == 1, bad
        failing = [c for c in bad["checks"] if c["status"] == "fail"]
        assert [c["id"] for c in failing] == ["config.valid"], failing
        assert "[fail] config.valid" in p.run("doctor", json_flag=False, code=1).stdout
        # MCP returns the report as data.
        mcp = p.tool_call("doctor", {})
        assert mcp["isError"] is False and mcp["structuredContent"]["result"]["status"] == 1, mcp
    finally:
        if saved is None:
            p.config_file.unlink()
        else:
            p.config_file.write_bytes(saved)
    assert p.json("doctor")["status"] == 0
    # No daemon: the usual error with a runnable fix, never a fake report.
    # A missing daemon's fix starts it; the data names the socket.
    none = str(p.root / "none.sock")
    err = p.error("doctor", "--socket", none, code=6, socket=False)
    assert err["code"] == "unavailable.not_running" and err["data"] == {"socket": none, "fix": f"{p.tool} serve"}, err
    # Other path failures keep a runnable diagnostic fix.
    long = str(p.root / ("x" * 120 + ".sock"))
    err = p.error("doctor", "--socket", long, code=6, socket=False)
    assert err["code"] == "unavailable.path_too_long" and err["data"]["fix"], err
    assert subprocess.run(["sh", "-n", "-c", err["data"]["fix"]], capture_output=True).returncode == 0, err


def check_grants(p):
    """Read-only default, denial before the handler, scoped tokens, MCP parity."""
    m = p.p["mutation"]
    obs = m["observe"]
    assert p.json(*obs["args"]) == obs["before"]
    who = p.json("whoami")
    assert who["principal"] == "unknown", who
    spoof = dict(p.env, **{p.tool.upper().replace("-", "_") + "_PRINCIPAL": "owner", "VENOM_PANE_ID": "p1"})
    assert p.json("whoami", env=spoof)["principal"] == "unknown"
    denied = p.error(*m["args"], code=4)
    assert denied["code"].startswith("denied.") and denied["data"]["principal"] == "unknown", denied
    # MCP runs as the same caller and is denied the same way.
    res = p.tool_call(m["mcp"]["name"], m["mcp"]["arguments"])
    assert res["isError"] is True and json.loads(res["content"][0]["text"])["error"]["code"] == denied["code"], res
    assert p.json(*obs["args"]) == obs["before"], "denied mutation ran its handler"
    # A read-only token is attenuated: reads succeed, the mutation is denied.
    issued = p.json("grant", "issue", '--grants=[{"right":"read","scope":"*"}]', "--ttl=60", env=p.owner)
    reader = dict(p.env, **{p.token_var: issued["token"]})
    assert p.json("whoami", env=reader)["principal"] == issued["principal"]
    assert p.json(*p.p["read"]["args"], env=reader) == p.p["read"]["result"]
    assert p.error(*m["args"], code=4, env=reader)["code"].startswith("denied.")
    p.json("grant", "revoke", f"--principal={issued['principal']}", env=p.owner)
    assert p.error("whoami", code=4, env=reader)["code"].startswith("denied.")
    assert p.error("grant", "issue", "--grants=[]", code=4)["code"].startswith("denied.")
    # The owner may mutate, through CLI and MCP alike.
    res = p.tool_call(m["mcp"]["name"], m["mcp"]["arguments"], env=p.owner)
    assert res["isError"] is False and res["structuredContent"]["result"] == m["result"], res
    assert p.json(*obs["args"]) == obs["after"]
    p.json(*m["args"], env=p.owner)
    # Read parity: MCP returns the same payload as the CLI.
    read = p.p["read"]
    res = p.tool_call(read["mcp"]["name"], read["mcp"]["arguments"])
    assert res == {"content": [{"type": "text", "text": json.dumps({"result": read["result"]}, separators=(",", ":"))}],
                   "structuredContent": {"result": read["result"]}, "isError": False}, res
    records = p.json("audit", env=p.owner)["records"]
    assert {"denied", "issued", "revoked"} <= {r["event"] for r in records}, records
    assert p.error("audit", code=4)["code"].startswith("denied.")


def check_headless(p):
    """Every call above ran with stdin closed and no controlling TTY; the
    daemon kept serving with no clients attached, and stops cleanly."""
    assert p.daemon is not None and p.daemon.poll() is None
    time.sleep(0.2)
    p.run("ping")
    p.stop()
    p.start()  # restart works with the persisted state
    p.run("ping")


def check_boundary(p):
    """No scripting, JIT, plugin or hook entry points in the verb surface."""
    for wire, grant in p.help_verbs():
        assert not re.search(r"(^|[._])(eval|exec_script|script|plugin|plugins|jit|load_module)($|[._])", wire), wire
    tools = p.mcp([{"method": "tools/list"}])[0]["result"]["tools"]
    for t in tools:
        assert not re.search(r"plugin|script|eval", t["name"]), t["name"]


CHECKS = [
    ("binary, locking and no-daemon exit", check_binary),
    ("action parity", None),
    ("generation agreement", check_generation),
    ("JSON output and exit codes", check_json),
    ("streams and events replay", check_streams),
    ("skills", check_skills),
    ("config verbs", check_config),
    ("doctor", check_doctor),
    ("grants", check_grants),
    ("headless", check_headless),
    ("OSC ingestion", None),
    ("extension boundary", check_boundary),
]
SKIPS = {
    "action parity": "product-specific: needs the product's TUI action/keybinding table",
    "OSC ingestion": "PTY consumers only (venomx); venom-std ships no OSC parser",
}


def main(argv):
    if len(argv) != 3:
        print(__doc__, file=sys.stderr)
        return 2
    exe, profile_path = argv[1:]
    profile = json.loads(Path(profile_path).read_text())
    stream_kind(profile)
    # Unix socket paths must fit sun_path; keep the root near /.
    with tempfile.TemporaryDirectory(prefix="vc-", dir=short_tempdir()) as root:
        p = Product(exe, profile, root)
        failed = 0
        try:
            for name, fn in CHECKS:
                if fn is None:
                    print(f"skip {name}: {SKIPS[name]}")
                    continue
                if fn is not check_binary and (p.daemon is None or p.daemon.poll() is not None):
                    print(f"not ok {name}: daemon is not running")
                    failed += 1
                    continue
                try:
                    fn(p)
                    print(f"ok {name}")
                except Exception:
                    failed += 1
                    print(f"not ok {name}")
                    for line in traceback.format_exc().rstrip().splitlines():
                        print("#   " + line)
                sys.stdout.flush()
        finally:
            try:
                p.stop()
            except Exception:
                failed += 1
                print("not ok shutdown")
                traceback.print_exc(file=sys.stdout)
    print(f"# {profile['tool']}: {'FAIL' if failed else 'PASS'} ({failed} failed)")
    return 1 if failed else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
