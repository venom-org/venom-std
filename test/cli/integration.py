"""Exercise the installed generated CLI and its socket boundary, without a TTY."""
import json
import os
from pathlib import Path
import signal
import socket as sockets
import select
import shutil
import subprocess
import sys
import tempfile
import time

exe, zig, fixture_exe = sys.argv[1:]
root = Path(__file__).resolve().parents[2]


def invoke(*args, code=0, env=None):
    result = subprocess.run([exe, *args], stdin=subprocess.DEVNULL, capture_output=True, text=True, timeout=10, env=env)
    assert result.returncode == code, (args, result.returncode, result.stdout, result.stderr)
    return result


with tempfile.TemporaryDirectory(prefix="venom-cli-") as directory:
    socket = str(Path(directory) / "echo.sock")
    invoke("echo", "--text=hi", "--socket", socket, "--json", code=6)
    daemon_env = dict(os.environ, XDG_STATE_HOME=str(Path(directory) / "state"), XDG_CONFIG_HOME=str(Path(directory) / "config"))
    with subprocess.Popen([exe, "serve", "--socket", socket, "--json"], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=daemon_env) as daemon:
        try:
            deadline = time.monotonic() + 10
            while not Path(socket).exists():
                assert daemon.poll() is None, daemon.communicate()
                assert time.monotonic() < deadline, "daemon did not create socket"
                time.sleep(0.01)
            # The serving loop runs under the supervisor, which publishes
            # its status next to the socket.
            status_file = Path(directory) / "echo.status.json"
            while not status_file.exists():
                assert time.monotonic() < deadline, "daemon did not write status file"
                time.sleep(0.01)
            status = json.loads(status_file.read_text())
            assert status["pid"] == daemon.pid and status["stopping"] is False, status
            assert [(w["name"], w["kind"], w["state"]) for w in status["workers"]] == [("serve", "thread", "running")], status
            assert status_file.stat().st_mode & 0o777 == 0o600
            result = invoke("--socket", socket, "echo", "--text", "hello", "--style=upper", "--json")
            assert json.loads(result.stdout) == {"text": "HELLO"}
            assert result.stderr == ""
            assert json.loads(invoke("echo", "--socket", socket, "--text=hello").stdout) == {"text": "hello"}
            assert json.loads(invoke("ping", "--socket", socket, "--json").stdout) == {}
            conflict = invoke("serve", "--socket", socket, "--json", code=5)
            assert json.loads(conflict.stdout)["error"]["code"] == "conflict.already_running"
            invalid = invoke("echo", "--socket", socket, "--style=loud", "--text=hi", "--json", code=2)
            assert json.loads(invalid.stdout)["error"]["code"] == "invalid_params.enum"
            missing = invoke("echo", "--json", code=2)
            assert json.loads(missing.stdout)["error"]["data"]["param"] == "text"
            help_result = invoke("serve", "--socket", socket, "--help", "--json")
            assert "Start the daemon" in json.loads(help_result.stdout)["help"]
            # The server is still alive after usage/help and failed second startup.
            invoke("ping", "--socket", socket)
            # Standard doctor with registered product checks.
            report = json.loads(invoke("doctor", "--socket", socket, "--json").stdout)
            assert report["status"] == 0, report
            ids = [c["id"] for c in report["checks"]]
            assert ids == ["config.valid", "runtime.socket_path", "runtime.directory", "grants.owner_file", "grants.audit", "grants.isolation", "grants.peer_attribution", "events.log", "schema.digest"], ids
            # hello advertises the complete-schema digest;
            # the CLI supplies its compiled digest to doctor, which matches.
            with sockets.socket(sockets.AF_UNIX) as raw:
                raw.settimeout(3)
                raw.connect(socket)
                raw_wire = raw.makefile("rwb", buffering=0)
                raw_wire.write(b'{"id":1,"verb":"hello","params":{"proto":[1]}}\n')
                advertised = json.loads(raw_wire.readline())["ok"]["schema"]
                raw_wire.close()
            assert advertised.startswith("sha256:") and len(advertised) == 71 and all(c in "0123456789abcdef" for c in advertised[7:]), advertised
            assert report["checks"][-1]["status"] == "ok" and advertised in report["checks"][-1]["message"], report["checks"][-1]
            stale = "sha256:" + "0" * 64
            skew = json.loads(invoke("doctor", "--client-schema=" + stale, "--socket", socket, "--json").stdout)
            assert skew["status"] == 0, skew
            assert skew["checks"][-1]["status"] == "warn" and stale in skew["checks"][-1]["message"] and advertised in skew["checks"][-1]["message"], skew["checks"][-1]
            assert "[warn] schema.digest:" in invoke("doctor", "--client-schema=" + stale, "--socket", socket).stdout
            assert all(set(c) == {"id", "status", "message", "fix"} and c["status"] in ("ok", "warn", "fail") and c["fix"] for c in report["checks"])
            events_check = report["checks"][-2]["message"]
            assert "retains seq 1..0 (0 of 16777216 bytes)" in events_check, events_check
            human = invoke("doctor", "--socket", socket).stdout
            assert "[ok] runtime.directory:" in human and "fix: " in human, human
            # skill output and installation.
            skill = invoke("skill", "--socket", socket).stdout
            assert skill.startswith("---\nname: venom-echo\ndescription: \"A toy daemon for protocol conformance\"\n---\n"), skill[:200]
            assert "Read-only by default" in skill and "venom-echo echo --text hi --json" in skill and "## Notes" in skill
            assert json.loads(invoke("skill", "--socket", socket, "--json").stdout) == {"content": skill}
            skill_root = Path(directory) / "skills"
            denied = invoke("skill", "install", "--target=codex", "--directory", str(skill_root), "--socket", socket, "--json", code=4)
            assert json.loads(denied.stdout)["error"]["code"] == "denied.files"
            assert not skill_root.exists()
            initial = list(map(json.loads, invoke("events", "--follow=false", "--socket", socket, "--json").stdout.splitlines()))
            assert [x["type"] for x in initial] == ["state.snapshot", "stream.checkpoint"]
            assert initial[0]["data"]["reason"] == "initial" and initial[0]["data"]["complete"] is True
            assert initial[0]["data"]["entities"][0]["entity_type"] == "config"
            cursor = initial[-1]["source"] + ":" + str(initial[-1]["seq"])
            replay = list(map(json.loads, invoke("events", "--after=" + cursor, "--follow=false", "--socket", socket, "--json").stdout.splitlines()))
            assert [x["type"] for x in replay] == ["stream.checkpoint"]
            invalid = invoke("events", "--types=[\"pane*\"]", "--follow=false", "--socket", socket, "--json", code=2)
            assert json.loads(invalid.stdout)["error"]["code"] == "invalid_params.event_filter"
            # Follow emits immediately, checkpoints while idle, and cancels cleanly.
            tail = subprocess.Popen([exe, "events", "--after=" + cursor, "--socket", socket, "--json"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
            try:
                assert select.select([tail.stdout], [], [], 7)[0], "event checkpoint timed out"
                assert json.loads(tail.stdout.readline())["type"] == "stream.checkpoint"
                assert select.select([tail.stdout], [], [], 7)[0], "event checkpoint timed out"
                assert json.loads(tail.stdout.readline())["type"] == "stream.checkpoint"
                tail.send_signal(signal.SIGINT)
                out, err = tail.communicate(timeout=5)
                assert tail.returncode == 8 and not err, (tail.returncode, out, err)
            finally:
                if tail.poll() is None:
                    tail.kill()
                    tail.wait()
            # Grants: environment fallback, explicit owner opt-in, attenuation,
            # live revocation, and no implicit trust in informational pane IDs.
            anon = json.loads(invoke("whoami", "--socket", socket, "--json").stdout)
            assert anon["principal"] == "unknown" and anon["parent"] is None
            spoof = dict(os.environ, VENOM_ECHO_PRINCIPAL="owner", VENOM_PANE_ID="p1")
            assert json.loads(invoke("whoami", "--socket", socket, "--json", env=spoof).stdout)["principal"] == "unknown"
            denied = invoke("grant", "issue", "--grants=[]", "--socket", socket, "--json", code=4)
            assert json.loads(denied.stdout)["error"]["code"] == "denied.spawn"
            owner_env = dict(os.environ, VENOM_ECHO_TOKEN="@owner")
            assert Path(socket).with_suffix(".owner").stat().st_mode & 0o777 == 0o600
            assert json.loads(invoke("whoami", "--socket", socket, "--json", env=owner_env).stdout)["principal"] == "owner"
            issued = json.loads(invoke("grant", "issue", '--grants=[{"right":"read","scope":"*"}]', "--ttl=60", "--socket", socket, "--json", env=owner_env).stdout)
            token_env = dict(os.environ, VENOM_ECHO_TOKEN=issued["token"])
            # Namespaced issuance shows in grant list --json.
            named = json.loads(invoke("grant", "issue", "--grants=[]", "--namespace=venom", "--ttl=60", "--socket", socket, "--json", env=owner_env).stdout)
            listed = {x["principal"]: x["namespace"] for x in json.loads(invoke("grant", "list", "--socket", socket, "--json", env=owner_env).stdout)["principals"]}
            # The owner's namespace is the daemon's tool, reserved for it.
            assert listed["owner"] == "venom-echo" and listed[issued["principal"]] == "user" and listed[named["principal"]] == "venom", listed
            reserved = invoke("grant", "issue", "--grants=[]", "--namespace=venom-echo", "--socket", socket, "--json", env=owner_env, code=4)
            assert json.loads(reserved.stdout)["error"]["code"] == "denied.namespace"
            assert json.loads(invoke("whoami", "--socket", socket, "--json", env=token_env).stdout)["principal"] == issued["principal"]
            invoke("echo", "--text=token", "--socket", socket, "--json", env=token_env)
            invoke("grant", "issue", "--grants=[]", "--socket", socket, "--json", env=token_env, code=4)
            invalid = dict(os.environ, VENOM_ECHO_TOKEN="vnt1.bad.owner.invalid")
            assert json.loads(invoke("whoami", "--socket", socket, "--json", env=invalid, code=4).stdout)["error"]["code"] == "denied.token"
            with sockets.socket(sockets.AF_UNIX) as cached:
                cached.settimeout(3)
                cached.connect(socket)
                wire = cached.makefile("rwb", buffering=0)
                wire.write((json.dumps({"id": 1, "verb": "hello", "params": {"proto": [1], "auth": {"token": issued["token"]}}}) + "\n").encode())
                assert json.loads(wire.readline())["ok"]["principal"]["principal"] == issued["principal"]
                invoke("grant", "revoke", "--principal=" + issued["principal"], "--socket", socket, "--json", env=owner_env)
                wire.write(b'{"id":2,"verb":"whoami"}\n')
                assert json.loads(wire.readline())["error"]["code"] == "denied.revoked"
                wire.close()
            records = json.loads(invoke("audit", "--socket", socket, "--json", env=owner_env).stdout)["records"]
            assert {"denied", "admin", "owner_auth", "issued", "revoked"} <= {r["event"] for r in records}
            installed = json.loads(invoke("skill", "install", "--target=codex", "--directory", str(skill_root), "--socket", socket, "--json", env=owner_env).stdout)
            skill_file = skill_root / "venom-echo" / "SKILL.md"
            assert installed == {"target": "codex", "path": str(skill_file.resolve()), "changed": True}, installed
            assert skill_file.read_text() == skill
            again = json.loads(invoke("skill.install", "--target=codex", "--directory", str(skill_root), "--socket", socket, "--json", env=owner_env).stdout)
            assert again["changed"] is False
            skill_file.write_text("edited\n")
            conflict = invoke("skill", "install", "--target=codex", "--directory", str(skill_root), "--socket", socket, "--json", env=owner_env, code=5)
            assert json.loads(conflict.stdout)["error"]["code"] == "conflict.skill_exists"
            invoke("skill", "install", "--target=codex", "--directory", str(skill_root), "--replace=true", "--socket", socket, "--json", env=owner_env)
            assert skill_file.read_text() == skill
            relative = invoke("skill", "install", "--target=codex", "--directory=skills", "--socket", socket, "--json", env=owner_env, code=2)
            assert json.loads(relative.stdout)["error"]["code"] == "invalid_params.skill_directory"
            audit_text = (Path(directory) / "state/venom/venom-echo/audit.ndjson").read_text()
            assert "vnt1." not in audit_text and issued["token"].split(".")[-1] not in audit_text
            # MCP stdio adapter, driven like an MCP client.
            requests = [
                {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {"protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "integration", "version": "0"}}},
                {"jsonrpc": "2.0", "method": "notifications/initialized"},
                {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
                {"jsonrpc": "2.0", "id": 3, "method": "tools/call", "params": {"name": "echo", "arguments": {"text": "hi"}}},
                {"jsonrpc": "2.0", "id": 4, "method": "tools/call", "params": {"name": "echo", "arguments": {"text": "hi", "style": "loud"}}},
            ]
            mcp = subprocess.run([exe, "mcp", "--socket", socket], input="".join(json.dumps(r) + "\n" for r in requests), capture_output=True, text=True, timeout=10)
            assert mcp.returncode == 0 and mcp.stderr == "", (mcp.returncode, mcp.stderr)
            replies = {r["id"]: r for r in map(json.loads, mcp.stdout.splitlines())}
            assert sorted(replies) == [1, 2, 3, 4], mcp.stdout
            assert replies[1]["result"]["serverInfo"]["name"] == "venom-echo"
            assert [t["name"] for t in replies[2]["result"]["tools"]] == ["audit", "config_dcheck", "config_dget", "config_dreload", "config_dschema", "config_dset", "counter_dget", "counter_dinc", "doctor", "echo", "events", "grant_dissue", "grant_dlist", "grant_drevoke", "ping", "skill", "skill_dinstall", "sleep", "whoami"]
            assert replies[3]["result"] == {"content": [{"type": "text", "text": '{"result":{"text":"hi"}}'}], "structuredContent": {"result": {"text": "hi"}}, "isError": False}
            assert replies[4]["result"]["isError"] is True
            assert json.loads(replies[4]["result"]["content"][0]["text"])["error"]["code"] == "invalid_params.enum"
            # Log levels come from config and apply live, so the
            # shutdown records below `warn` never reach the log file.
            assert json.loads(invoke("config", "set", "--key=log.level", "--value=.warn", "--socket", socket, "--json", env=owner_env).stdout)["changed"] is True
            invoke("config", "reload", "--socket", socket, "--json", env=owner_env)  # set is staged until reload
            invoke("ping", "--socket", socket)  # one more loop turn applies it
            daemon.send_signal(signal.SIGINT)
            out, err = daemon.communicate(timeout=10)
            assert daemon.returncode == 0, (out, err)
            assert out == "{}\n", out
            assert err == "", err
            assert not Path(socket).exists(), "clean shutdown did not remove socket"
            assert not Path(socket).with_suffix(".owner").exists()
            assert not status_file.exists(), "clean shutdown did not remove status file"
            # Structured JSON log in the XDG state directory.
            log_file = Path(directory) / "state/venom/venom-echo/venom-echo.log"
            assert log_file.stat().st_mode & 0o777 == 0o600
            records = [json.loads(line) for line in log_file.read_text().splitlines()]
            assert all(r["source"] == "venom-echo" and r["level"] == "info" for r in records), records
            messages = [r["msg"] for r in records]
            assert messages[0] == "listening" and records[0]["socket"] == socket and records[0]["pid"] == daemon.pid, records
            assert "worker started" in messages and "stopped" not in messages, messages
        finally:
            if daemon.poll() is None:
                daemon.kill()
                daemon.communicate()

# Offline generators: no daemon is running here.
with tempfile.TemporaryDirectory(prefix="venom-cli-docs-") as directory:
    markdown = invoke("docs").stdout
    assert markdown.startswith("# venom-echo\n") and "### `venom-echo skill install`" in markdown
    assert json.loads(invoke("docs", "--json").stdout) == {"content": markdown}
    man = invoke("docs", "--format=man").stdout
    assert man.startswith('.TH "VENOM-ECHO" "1"')
    written = json.loads(invoke("docs", "--format=man", "--directory", directory, "--json").stdout)["files"]
    names = sorted(Path(f).name for f in written)
    assert "venom-echo.1" in names and "venom-echo-skill-install.1" in names and "venom-echo-grant-issue.1" in names, names
    for f in written:
        lint = subprocess.run(["groff", "-man", "-ww", "-z", f], capture_output=True, text=True) if shutil.which("groff") else None
        assert lint is None or (lint.returncode == 0 and lint.stderr == ""), (f, lint.stderr)
    missing = invoke("docs", "--directory", str(Path(directory) / "missing"), "--json", code=2)
    assert json.loads(missing.stdout)["error"]["code"] == "invalid_params.directory"
    for shell, check in [("bash", ["bash", "-n"]), ("zsh", ["zsh", "-n"]), ("fish", ["fish", "--no-execute"])]:
        script = invoke("completions", "--shell", shell).stdout
        assert "skill.install" in script and "'target enum'" in script, shell
        assert json.loads(invoke("completions", "--shell", shell, "--json").stdout) == {"content": script}
        if shutil.which(check[0]):
            path = Path(directory) / ("completion." + shell)
            path.write_text(script)
            syntax = subprocess.run([*check, str(path)], capture_output=True, text=True)
            assert syntax.returncode == 0, (shell, syntax.stderr)
    if shutil.which("bash"):
        # Drive the bash engine like readline does.
        driver = 'source <("$0" completions --shell bash); COMP_LINE="venom-echo skill install --target "; COMP_POINT=${#COMP_LINE}; _venom_echo; echo "${COMPREPLY[*]}"'
        out = subprocess.run(["bash", "-c", driver, exe], capture_output=True, text=True, timeout=10)
        assert out.stdout == "claude-code codex opencode\n", (out.stdout, out.stderr)
    invoke("completions", "--shell=tcsh", "--json", code=2)
print("CLI generators: docs (Markdown, man), completions (bash, zsh, fish) passed")

# Generation must fail before a binary is produced for malformed manifests.
base = '.{ .format = 1, .tool = "bad", .summary = "Bad", .verbs = .{VERB} }'
verb = '.{ .name = "check", .summary = "Check", .result = .{ .kind = .null }, .grant = .read, PARAMS }'
cases = [
    (verb.replace('PARAMS', '.extra = true'), 'unknown manifest member'),
    (verb.replace('PARAMS', '.params = .{.{ .name = "json", .summary = "Bad", .type = .{ .kind = .string } }}'), 'collides with global'),
    (verb.replace('PARAMS', '.params = .{.{ .name = "count", .summary = "Bad", .type = .{ .kind = .integer }, .default = "x" }}'), 'expected number'),
    (verb.replace('PARAMS', '.examples = .{.{ .params = .{ .unknown = 1 }, .result = null }}'), 'unknown manifest member'),
    (verb.replace('PARAMS', '').replace('"check"', '"serve"'), 'reserved bootstrap'),
    (verb.replace('PARAMS', '').replace('"check"', '"a-b"'), 'invalid verb schema'),
    (verb.replace('PARAMS', '').replace('"check"', '"skill"'), 'reserved bootstrap or shared'),
    (verb.replace('PARAMS', '').replace('"check"', '"docs.extra"'), 'reserved bootstrap or shared'),
    (verb.replace('PARAMS', '') + ', ' + verb.replace('PARAMS', '').replace('"check"', '"a_b.c"').replace('"Check"', '"One"') + ', ' + verb.replace('PARAMS', '').replace('"check"', '"a.b_c"'), 'man page name collision'),
]
with tempfile.TemporaryDirectory(prefix="venom-cli-invalid-") as directory:
    fixture = Path(directory) / "invalid.zig"
    for body, diagnostic in cases:
        fixture.write_text('const cli = @import("cli");\ncomptime { _ = cli.Generator(' + base.replace('VERB', body) + '); }\n')
        result = subprocess.run([
            zig, "test", "--dep", "cli", f"-Mroot={fixture}",
            "--dep", "proto", "--dep", "iface", f"-Mcli={root / 'src/cli/root.zig'}",
            "--dep", "iface", "--dep", "xdg", f"-Mproto={root / 'src/proto/root.zig'}",
            f"-Miface={root / 'src/iface.zig'}", f"-Mxdg={root / 'src/xdg/root.zig'}", "-lc",
        ], capture_output=True, text=True, timeout=30)
        assert result.returncode != 0 and diagnostic in result.stderr, result.stderr
# Compiled extensions use the same closed parameter normalization and cannot
# become a format-1 serve override or collide with global flags.
with tempfile.TemporaryDirectory(prefix="venom-cli-bootstrap-invalid-") as directory:
    fixture = Path(directory) / "invalid.zig"
    for extension, diagnostic in [
        ('.{ .serve_params = .{.{ .name = "lifetime", .summary = "Lifetime", .type = .{ .kind = .string, .choices = .{"persistent"} }, .default = "bad" }} }', 'invalid enum value'),
        ('.{ .serve_params = .{.{ .name = "socket", .summary = "Socket", .type = .{ .kind = .string } }} }', 'collides with global flag'),
        ('.{ .startup = .{ .verb = "missing", .summary = "Policy" } }', 'startup policy verb is absent'),
        ('.{ .startup = .{ .verb = "grant.issue", .summary = "Policy" } }', 'startup policy verb is absent'),
        ('.{ .startup = .{ .verb = "doctor", .summary = "Policy" } }', 'startup policy requires a product verb'),
        ('.{ .serve = .{} }', 'unknown bootstrap extension member'),
    ]:
        source = 'const cli = @import("cli");\ncomptime { _ = cli.WithBootstrap(cli.manifest.normalize(' + base.replace('VERB', verb.replace('PARAMS', '')) + '), &.{}, ' + extension + '); }\n'
        fixture.write_text(source)
        result = subprocess.run([
            zig, "test", "--dep", "cli", f"-Mroot={fixture}",
            "--dep", "proto", "--dep", "iface", f"-Mcli={root / 'src/cli/root.zig'}",
            "--dep", "iface", "--dep", "xdg", f"-Mproto={root / 'src/proto/root.zig'}",
            f"-Miface={root / 'src/iface.zig'}", f"-Mxdg={root / 'src/xdg/root.zig'}", "-lc",
        ], capture_output=True, text=True, timeout=30)
        assert result.returncode != 0 and diagnostic in result.stderr, result.stderr
print("CLI integration: socket dispatch, bootstrap, MCP adapter, help, JSON/exits and invalid manifests passed")

# Drive the generated client from a controlled wire peer. Check observable
# streaming/cancellation behavior independently of the daemon dispatcher.
with tempfile.TemporaryDirectory(prefix="venom-cli-wire-") as directory:
    path = str(Path(directory) / "peer.sock")
    with sockets.socket(sockets.AF_UNIX) as listener:
        listener.bind(path)
        listener.listen()
        listener.settimeout(10)
        for verb_name, mode, expected in [("watch", "success", 0), ("watch", "denied", 4), ("watch", "cancel", 8), ("report", "status", 23), ("report", "bad-result", 11)]:
            with subprocess.Popen([fixture_exe, verb_name, "--json", "--socket", path], stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as client:
                try:
                    conn, _ = listener.accept()
                    with conn:
                        conn.settimeout(10)
                        wire = conn.makefile("rwb", buffering=0)
                        hello = json.loads(wire.readline())
                        assert hello["verb"] == "hello"
                        wire.write((json.dumps({"id": 0, "ok": {"proto": 1, "server": {"name": "test-cli", "version": "1"}, "caps": ["cancel"], "max_frame": 1048576, "schema": "sha256:" + "f" * 64}}) + "\n").encode())
                        # A skewed advertised digest never blocks normal calls.
                        request = json.loads(wire.readline())
                        assert request == {"id": 2, "verb": verb_name, "params": {}}
                        if verb_name == "watch":
                            wire.write(b'{"id":2,"item":"first"}\n')
                            # The item must flush before any final response arrives.
                            assert select.select([client.stdout], [], [], 3)[0], "stream item was buffered"
                            assert client.stdout.readline() == '\"first\"\n'
                            if mode == "cancel":
                                client.send_signal(signal.SIGINT)
                                cancel = json.loads(wire.readline())
                                assert cancel == {"id": 3, "verb": "cancel", "params": {"id": 2}}
                                wire.write(b'{"id":2,"error":{"code":"cancelled","message":"cancelled by client"}}\n{"id":3,"ok":null}\n')
                            elif mode == "denied":
                                wire.write(b'{"id":2,"error":{"code":"denied.scope","message":"No access","data":{"resource":"x"}}}\n')
                            else:
                                wire.write(b'{"id":2,"ok":null}\n')
                        elif mode == "status":
                            wire.write(b'{"id":2,"ok":{"status":23}}\n')
                        else:
                            wire.write(b'{"id":2,"ok":{"status":256}}\n')
                        out, err = client.communicate(timeout=10)
                        assert client.returncode == expected, (out, err, client.returncode)
                        assert err == "", err
                        if mode in ("success", "race", "failed-winner"):
                            assert out == "", "stream final success was not suppressed"
                        elif mode == "status":
                            assert json.loads(out) == {"status": 23}
                        else:
                            assert "error" in json.loads(out), out
                finally:
                    if client.poll() is None:
                        client.kill()
                        client.communicate()
print("CLI wire integration: streaming flush, final suppression, failure, cancellation and result exits passed")

# A cooperative test launcher signals intent through one marker file.
# The controlled peer then exercises real hello/ping readiness and a single
# mutation, including loss of the reply. No launcher output enters stdout.
with tempfile.TemporaryDirectory(prefix="venom-cli-startup-") as directory:
    for mode in ("success", "race", "failed-winner", "lost-reply", "hello-deadline", "ping-deadline", "cancel", "deadline"):
        path = str(Path(directory) / (mode + ".sock"))
        marker = Path(directory) / (mode + ".launch")
        env = dict(os.environ, TEST_STARTUP=mode, TEST_STARTUP_MARKER=str(marker))
        began = time.monotonic()
        with subprocess.Popen([fixture_exe, "report", "--json", "--socket", path], stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, env=env) as client:
            deadline = began + 3
            while not marker.exists():
                assert client.poll() is None, client.communicate()
                assert time.monotonic() < deadline
                time.sleep(.002)
            if mode == "cancel":
                client.send_signal(signal.SIGINT)
            if mode in ("deadline", "cancel"):
                out, err = client.communicate(timeout=3)
            else:
                with sockets.socket(sockets.AF_UNIX) as listener:
                    listener.bind(path)
                    listener.listen()
                    listener.settimeout(3)
                    conn, _ = listener.accept()
                    with conn:
                        conn.settimeout(3)
                        wire = conn.makefile("rwb", buffering=0)
                        assert json.loads(wire.readline())["verb"] == "hello"
                        if mode != "hello-deadline":
                            wire.write(b'{"id":0,"ok":{"proto":1,"server":{"name":"test-cli","version":"1"},"caps":["cancel"],"max_frame":1048576}}\n')
                            assert json.loads(wire.readline()) == {"id": 1, "verb": "ping", "params": {}}
                            if mode != "ping-deadline":
                                wire.write(b'{"id":1,"ok":{}}\n')
                                assert json.loads(wire.readline()) == {"id": 2, "verb": "report", "params": {}}
                                if mode in ("success", "race", "failed-winner"):
                                    wire.write(b'{"id":2,"ok":{"status":23}}\n')
                                else:
                                    wire.close()
                                    conn.shutdown(sockets.SHUT_RDWR)
                        out, err = client.communicate(timeout=3)
                        wire.close()
                    # No reconnect/replay after a mutation or deadline.
                    assert not select.select([listener], [], [], .05)[0]
            assert time.monotonic() - began < 2
            expected = 23 if mode in ("success", "race", "failed-winner") else 8 if mode == "cancel" else 6
            assert client.returncode == expected, (mode, client.returncode, out, err)
            assert err == "", (mode, err)
            payload = json.loads(out)
            if mode in ("success", "race", "failed-winner"):
                assert payload == {"status": 23}
            else:
                code = "cancelled" if mode == "cancel" else "unavailable.startup_result" if mode == "lost-reply" else "unavailable.startup_deadline"
                assert payload["error"]["code"] == code, (mode, payload)
    # Ineligible CLI and MCP calls cannot invoke the registered launcher.
    for command in (["watch"], ["report", "--help"], ["mcp"]):
        marker = Path(directory) / "forbidden.launch"
        env = dict(os.environ, TEST_STARTUP="1", TEST_STARTUP_MARKER=str(marker))
        request = '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"report","arguments":{}}}\n' if command == ["mcp"] else ""
        result = subprocess.run([fixture_exe, *command, "--json", "--socket", str(Path(directory) / "missing.sock")],
                                input=request, capture_output=True, text=True, env=env, timeout=3)
        assert not marker.exists(), (command, result.stdout, result.stderr)
        # A missing daemon is `unavailable.not_running` naming the socket, for CLI and MCP alike.
        missing = {"code": "unavailable.not_running", "message": "No daemon at the selected socket", "data": {"socket": str(Path(directory) / "missing.sock")}}
        if command == ["watch"]:
            assert result.returncode == 6
            assert json.loads(result.stdout) == {"error": missing}, result.stdout
        if command == ["mcp"]:
            reply = json.loads(result.stdout.splitlines()[-1])["result"]
            assert reply["isError"] is True and json.loads(reply["content"][0]["text"]) == {"error": missing}, reply
print("CLI startup integration: readiness, bounded waits, cancellation, no replay and MCP exclusion passed")

# Local commands are offline even with a launcher registered.
import pty
with tempfile.TemporaryDirectory(prefix="venom-cli-local-") as directory:
    marker = Path(directory) / "forbidden.launch"
    env = dict(os.environ, TEST_STARTUP="1", TEST_STARTUP_MARKER=str(marker))
    for args, status, payload in [
        (["inspect"], 0, "default"),
        (["inspect", "--name=chosen"], 0, "chosen"),
        (["inspect", "--name=missing"], 3, {"error": {"code": "not_found.target", "message": "target missing", "data": {}}}),
        (["attach"], 10, {"error": {"code": "unsupported.terminal", "message": "command needs a terminal on stdin and stdout", "data": {}}}),
    ]:
        result = subprocess.run([fixture_exe, *args, "--json", "--socket=/missing/local.sock"], stdin=subprocess.DEVNULL, capture_output=True, text=True, env=env, timeout=3)
        assert result.returncode == status, result
        assert json.loads(result.stdout) == payload, result
        assert result.stderr == ""
        assert not marker.exists()
    # Both descriptors must be terminals; one terminal is insufficient.
    master, slave = pty.openpty()
    try:
        for terminal_in, terminal_out, status in [(True, False, 10), (False, True, 10), (True, True, 0)]:
            result = subprocess.run([fixture_exe, "attach", "--json"], stdin=slave if terminal_in else subprocess.DEVNULL,
                                    stdout=slave if terminal_out else subprocess.PIPE, stderr=subprocess.PIPE, env=env, timeout=3)
            assert result.returncode == status, result
            assert result.stderr == b""
    finally:
        os.close(master)
        os.close(slave)
    requests = [
        {"jsonrpc": "2.0", "id": 1, "method": "tools/list"},
        *[{"jsonrpc": "2.0", "id": i + 2, "method": "tools/call", "params": {"name": name, "arguments": {}}} for i, name in enumerate(("attach", "inspect"))],
    ]
    result = subprocess.run([fixture_exe, "mcp"], input="".join(json.dumps(r) + "\n" for r in requests), capture_output=True, text=True, env=env, timeout=3)
    replies = [json.loads(line) for line in result.stdout.splitlines()]
    assert not {"attach", "inspect"} & {tool["name"] for tool in replies[0]["result"]["tools"]}
    for reply in replies[1:]:
        assert reply["error"]["code"] == -32602, reply
    assert not marker.exists()
print("CLI local integration: outcomes, terminals, offline dispatch and MCP exclusion passed")

# Compile-time local declaration and registration contract.
local_record = '.{ .name = "offline", .summary = "Offline", .result = .{ .kind = .null } EXTRA }'
local_cases = [
    (local_record.replace('EXTRA', ', .typo = true'), 'unknown manifest member'),
    (local_record.replace('EXTRA', ', .streams = false'), 'unknown manifest member'),
    (local_record.replace('EXTRA', ', .item = .{ .kind = .null }'), 'unknown manifest member'),
    (local_record.replace('EXTRA', ', .grant = .read'), 'local grant must be none'),
    (local_record.replace('EXTRA', ', .interactive = "yes"'), "expected type 'bool'"),
    (local_record.replace('EXTRA', ', .params = .{.{ .name = "json", .summary = "Bad", .type = .{ .kind = .string } }}'), 'collides with global flag'),
    (local_record.replace('EXTRA', '').replace('"offline"', '"check"'), 'local command collides'),
    (local_record.replace('EXTRA', '').replace('"offline"', '"check.child"'), 'local command collides'),
    (local_record.replace('EXTRA', '').replace('"offline"', '"grant"'), 'local command collides'),
    (local_record.replace('EXTRA', '').replace('"offline"', '"serve"'), 'reserved local command'),
    (local_record.replace('EXTRA', '').replace('"offline"', '"ping.child"'), 'reserved local command'),
    (local_record.replace('EXTRA', '') + ', ' + local_record.replace('EXTRA', ''), 'invalid verb schema'),
    (local_record.replace('EXTRA', '') + ', ' + local_record.replace('EXTRA', '').replace('"offline"', '"offline.child"'), 'local command path collision'),
    (local_record.replace('EXTRA', '').replace('"offline"', '"a_b.c"') + ', ' + local_record.replace('EXTRA', '').replace('"offline"', '"a.b_c"'), 'man page name collision'),
]
with tempfile.TemporaryDirectory(prefix="venom-cli-local-invalid-") as directory:
    fixture = Path(directory) / "invalid.zig"
    def reject(source, diagnostic):
        fixture.write_text(source)
        result = subprocess.run([
            zig, "test", "--dep", "cli", f"-Mroot={fixture}",
            "--dep", "proto", "--dep", "iface", f"-Mcli={root / 'src/cli/root.zig'}",
            "--dep", "iface", "--dep", "xdg", f"-Mproto={root / 'src/proto/root.zig'}",
            f"-Miface={root / 'src/iface.zig'}", f"-Mxdg={root / 'src/xdg/root.zig'}", "-lc",
        ], capture_output=True, text=True, timeout=30)
        assert result.returncode != 0 and diagnostic in result.stderr, (diagnostic, result.stderr)
    model_source = 'cli.manifest.normalize(' + base.replace('VERB', verb.replace('PARAMS', '')) + ')'
    for records, diagnostic in local_cases:
        reject('const cli = @import("cli"); comptime { _ = cli.WithBootstrap(' + model_source + ', &.{}, .{ .local = .{' + records + '} }); }', diagnostic)
    declaration = 'const G = cli.WithBootstrap(' + model_source + ', &.{}, .{ .local = .{' + local_record.replace('EXTRA', '') + '} });'
    handler_source = '''
const H = struct {
    pub const commands = NAMES;
    pub fn call(_: *@This(), _: cli.Local.Context) anyerror!cli.Local.Outcome { return .{ .result = .null }; }
};
test { var h: H = .{}; _ = &h; _ = try G.run(@import("std").testing.allocator, &.{"offline"}, .{ .stdout = undefined, .stderr = undefined LOCAL }); }
'''
    for names, registration, diagnostic in [
        ('.{"offline"}', '', 'local handlers required'),
        ('.{}', ', .local = cli.Local.init(&h)', 'missing or duplicate local handler'),
        ('.{"offline", "extra"}', ', .local = cli.Local.init(&h)', 'extra local handler'),
        ('.{"offline", "offline"}', ', .local = cli.Local.init(&h)', 'missing or duplicate local handler'),
    ]:
        reject('const cli = @import("cli");' + declaration + handler_source.replace('NAMES', names).replace('LOCAL', registration), diagnostic)
    reject('const cli = @import("cli"); const G = cli.FromSchema(' + model_source + ');' + handler_source.replace('NAMES', '.{"offline"}').replace('LOCAL', ', .local = cli.Local.init(&h)'), 'extra local handler')
print("CLI local compile checks: invalid declarations and missing/extra handlers rejected")
