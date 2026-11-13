#!/usr/bin/env python3
"""Check the streams check against real CLI processes with deliberately broken output.

The proxy changes only events. All daemon, token and config operations still
use venom-echo; no mock handler or fixture verb can make revocation pass.
"""
import copy
import importlib.util
import json
from pathlib import Path
import sys
import tempfile

suite_path, exe, profile_path = map(Path, sys.argv[1:])
sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("agent_contract", suite_path)
suite = importlib.util.module_from_spec(spec)
spec.loader.exec_module(suite)
profile = json.loads(profile_path.read_text())
assert profile["stream"] == {"kind": "events"}

# A fresh process wrapper for each fault. SIGINT goes to the actual CLI and
# each child is waited, including if the checker kills the proxy on failure.
PROXY = r'''
import json
import os
import signal
import subprocess
import sys

EXE = __EXE__
MODE = __MODE__
args = sys.argv[1:]
if not args or args[0] != "events":
    os.execv(EXE, [EXE, *args])
finite = "--follow=false" in args
if MODE == "early-error" and not finite:
    print('{"error":{"code":"denied.event_scope","message":"early"}}', flush=True)
    sys.exit(4)
child = subprocess.Popen([EXE, *args], stdout=subprocess.PIPE)
def forward(sig, frame):
    if child.poll() is None:
        child.send_signal(sig)
signal.signal(signal.SIGINT, forward)
signal.signal(signal.SIGTERM, forward)
try:
    for line in child.stdout:
        value = json.loads(line)
        if finite and MODE == "missing-checkpoint" and value.get("type") == "stream.checkpoint":
            continue
        if finite and MODE == "invalid-envelope":
            value["seq"] = True
        if MODE == "missing-error" and not finite and "error" in value:
            continue
        print(json.dumps(value, separators=(",", ":")), flush=True)
    status = child.wait()
    if finite and MODE == "extra-success":
        print("{}", flush=True)
    if MODE == "cancel-success" and status == 8:
        status = 0
    if MODE == "revoke-success" and status == 4:
        status = 0
    sys.exit(status)
finally:
    if child.poll() is None:
        child.kill()
    child.wait()
'''

faults = {
    "extra-success": "AssertionError",       # final ok must be suppressed
    "missing-checkpoint": "finite events did not end at checkpoint",
    "invalid-envelope": "AssertionError",    # bool is not a sequence number
    "cancel-success": "cancelled events exited 0, want 8",
    "revoke-success": "revoked events exited 0, want 4",
    "missing-error": "missing terminal denied.event_scope",
    "early-error": "events ended before initial checkpoint",
}
for mode, expected in faults.items():
    with tempfile.TemporaryDirectory(prefix="vc-canary-") as directory:
        root = Path(directory)
        proxy = root / "proxy"
        proxy.write_text("#!" + sys.executable + "\n" + PROXY.replace("__EXE__", repr(str(exe.resolve()))).replace("__MODE__", repr(mode)))
        proxy.chmod(0o700)
        p = suite.Product(proxy, profile, root)
        try:
            p.start()
            try:
                suite.check_streams(p)
            except AssertionError as error:
                message = f"{type(error).__name__}: {error}"
                assert expected in message, (mode, message)
            else:
                raise AssertionError(f"streams check accepted broken {mode}")
        finally:
            p.stop()
        print(f"ok event-only canary: {mode}")

# Invalid/absent profile forms must fail rather than silently skip the streams check.
for stream in ({"kind": "unknown"}, {"kind": "events", "args": []}, {}):
    bad = copy.deepcopy(profile)
    bad["stream"] = stream
    try:
        suite.stream_kind(bad)
    except AssertionError:
        pass
    else:
        raise AssertionError(f"accepted malformed stream profile: {stream}")
print("ok event-only profile validation")
