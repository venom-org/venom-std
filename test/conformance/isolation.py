#!/usr/bin/env python3
"""Canary: the conformance suite never hands a product the caller's
real HOME, XDG base dirs, TMPDIR or runtime dir, and a daemon run under it
writes nothing outside the suite's temp root.

    python3 isolation.py <agent_contract.py> <venom-echo> <profile.json>
"""
import importlib.util
import json
import os
from pathlib import Path
import stat
import sys
import tempfile

sys.dont_write_bytecode = True
spec = importlib.util.spec_from_file_location("agent_contract", Path(sys.argv[1]))
suite = importlib.util.module_from_spec(spec)
spec.loader.exec_module(suite)
exe, profile = sys.argv[2], json.loads(Path(sys.argv[3]).read_text())


def files(directory):
    return sorted(str(p.relative_to(directory)) for p in Path(directory).rglob("*"))


with tempfile.TemporaryDirectory(prefix="vc-user-", dir=suite.short_tempdir()) as user, \
        tempfile.TemporaryDirectory(prefix="vc-", dir=suite.short_tempdir()) as root:
    # Stand-in for the caller's real environment: every isolated variable
    # points into `user`, which must stay empty.
    caller = {name: str(Path(user) / name.lower()) for name in suite.ISOLATED_VARS}
    os.environ.update(caller)
    p = suite.Product(exe, profile, root)

    for label, env in (("env", p.env), ("owner", p.owner)):
        for name in suite.ISOLATED_VARS:
            value = env.get(name)
            assert value, f"{label}: {name} is not set"
            for part in value.split(":"):
                assert Path(part).is_relative_to(root), f"{label}: {name}={value} is outside the temp root"
        leaked = [k for k, v in env.items() if user in v]
        assert not leaked, f"{label}: caller paths leak through {leaked}"
    print("ok every isolated variable points into the temp root")

    runtime = Path(p.env["XDG_RUNTIME_DIR"])
    mode = stat.S_IMODE(runtime.stat().st_mode)
    assert runtime.is_dir() and mode == 0o700, f"XDG_RUNTIME_DIR mode {mode:o}, want 700"
    # Runtime sockets must fit sun_path (108 bytes on Linux).
    longest = runtime / "venom" / f"{profile['tool']}.sock"
    assert len(str(longest).encode()) < 100, f"runtime socket path too long: {longest}"
    print("ok XDG_RUNTIME_DIR is 0700 with a short path")

    p.start()
    try:
        p.run("ping")
        p.json("whoami", env=p.owner)
        p.json("grant", "issue", '--grants=[{"right":"read","scope":"*"}]', "--ttl=60", env=p.owner)
    finally:
        p.stop()
    assert files(user) == [], f"daemon wrote outside the temp root: {files(user)}"
    print("ok a daemon run leaves the caller's directories untouched")
