# venom-std

Shared Zig modules every Venom binary builds on: `proto` (socket, framing, NDJSON verbs, events, grants), `cfg` (ZON config and the `config` verbs), `cli` (generates the CLI, MCP, completions, docs, skill and doctor from the verb schema), `log`, `secrets`, `xdg`, `supervisor`. It also ships the toy daemon `venom-echo` and the agent-contract conformance suite.

Part of [Venom](https://venom.tools). Status: **alpha**; interfaces may still change. Documentation: [venom.tools](https://venom.tools).

Build from source with the Zig version in `.zigversion` (see [Build and test](#build-and-test)), or add it to your project as a Zig package (see [Using venom-std from another repo](#using-venom-std-from-another-repo)).

Licensed under the [MIT License](LICENSE). To report a vulnerability, see [SECURITY.md](SECURITY.md).

## Modules

Each module is importable on its own.

| Module | Purpose | Status |
|---|---|---|
| `iface` | vtable + comptime-assert interface helper | ready |
| `proto` | Unix socket, framing, hello, NDJSON dispatch and error model | transport, dispatch, grants and events ready |
| `cfg` | ZON config and `config` verbs | ready |
| `cli` | CLI / MCP / completions / docs / skill / doctor generator | ready |
| `xdg` | XDG config/data/state/cache/runtime dirs with `venom/<tool>` subpaths; socket, lock and status paths | ready |
| `log` | structured text/JSON logging to stderr and a state-dir file; levels from config | ready |
| `supervisor` | threads and child processes, exponential-backoff restarts, status file, graceful SIGTERM; `Leaders`: nonblocking pinned process-group termination of PTY leaders (Linux and macOS) | ready |
| `secrets` | encrypted secret store (ChaCha20-Poly1305), `secrets.*` verbs, the `secret:<name>` reference grammar | ready |

## Using venom-std from another repo

```sh
zig fetch --save=venom_std git+https://github.com/venom-org/venom-std.git#<commit>
```

For local cross-repo work, use a relative path dependency instead (`.venom_std = .{ .path = "../venom-std" }`) and don't commit it.

In `build.zig`:

```zig
const venom_std = b.dependency("venom_std", .{ .target = target, .optimize = optimize });
exe.root_module.addImport("proto", venom_std.module("proto"));
```

`test/consumer/` is a working example and runs as part of `zig build test`.

## Build and test

Zig version: see `.zigversion` for the exact compiler; the shared release line
is currently 0.17. All Venom repos build on the same release line, checked by
CI, and move to a new release line within four weeks of its release.

```sh
zig build                    # build and install zig-out/bin/venom-echo
zig build test               # everything below
zig build test-unit          # every module's tests, on std.testing.allocator
zig build test-leak-canary   # checks that a leaking test fails the build
zig build test-consumer      # builds test/consumer against this package
zig build test-cli           # real socket CLI + invalid manifest tests (Python 3)
zig build test-conformance   # agent-contract conformance suite against venom-echo (Python 3)
zig fmt --check .
```

## CI

`.github/workflows/ci.yml` runs on pull requests and on pushes to `main`. The
`zig` job checks that `.zigversion` is on the 0.17 release line, installs that
exact Zig, then runs `zig fmt --check .`, `zig build` and `zig build test`. The
`policy` job rejects `pull_request_target` workflows and `.path` dependencies
in `build.zig.zon`.

## Unix transport (`proto`)

The transport links libc through its build module and supports Linux and macOS.
It uses a single-threaded, non-blocking `poll` reactor with bounded input,
output and connection counts. Each connection independently selects NDJSON
(`{`, preserved) or binary (`0xF5`, consumed). Binary headers are ten bytes,
big-endian; the payload limit defaults to 1 MiB and negotiates up to 16 MiB.

Start a daemon with the environment supplied by Zig's process entry point:

```zig
const std = @import("std");
const proto = @import("proto");

pub fn main(init: std.process.Init) !void {
    var server = try proto.Server.init(init.gpa, .{
        .hello = .{ .identity = .{ .name = "venom-demo", .version = "0.1.0" } },
        .path = .{ .environ = init.minimal.environ },
    }, null);
    defer server.deinit();
    while (true) try server.poll(1000);
}
```

`path.socket` is the `--socket` override. Otherwise the resolver checks
`<TOOL>_SOCKET`, then `$XDG_RUNTIME_DIR/venom/<tool>.sock`, with
`${TMPDIR:-/tmp}/venom-<real-uid>/<tool>.sock` as the fallback. A null
`path.environ` explicitly uses an empty environment. The immediate runtime
directory is created with 0700 and checked for ownership, permissions and
symlinks; override parents receive the same checks. The socket is 0600,
accepted peers must have the same UID, and a held flock serializes startup
and recovery of sockets left after a crash. Lock files remain after shutdown.

`Server` handles hello, binary PING/PONG and framing. To receive application
messages, pass `proto.Handler.init(&implementation)` with these public methods:

```zig
pub fn message(self: *Implementation, conn: *proto.Connection, msg: proto.Message) anyerror!void;
pub fn allowFrame(self: *Implementation, conn: *const proto.Connection, kind: u16) bool;
```

Handlers run after hello negotiation (or implicit v1 for NDJSON). Keep them
brief; queue responses with `conn.sendMessage`. A `.ndjson` message sent on a
binary connection becomes a CONTROL frame. `allowFrame` must check the
negotiated capability with `conn.hasCap` before accepting a tool frame.
Messages and connection pointers are borrowed for the callback. Handler errors
close that connection; allocation failures propagate from `Server.poll`.
Verb dispatch and the request/error model are in `proto.dispatch`.

Clients call `proto.Client.init` with the tool, hello identity, path options and
`.protocol = .ndjson` or `.binary`. Init connects without blocking and queues
hello. Repeatedly call `client.pollHello(timeout_ms)` until it returns true,
while the daemon runs its reactor. The client validates the selected version,
capabilities and frame limit. Then use `client.connection.sendMessage` and
`client.receive(timeout_ms)`, which flushes queued output while waiting for
input. Received slices last until the next receive call. Always call deinit.
A full Unix listen backlog returns `error.WouldBlock`; callers may retry init.

Transport failures preserve distinct Zig errors for the generated CLI:

| Zig error | Protocol error code |
|---|---|
| `InsecurePath` | `denied.insecure_path` |
| `AlreadyRunning` | `conflict.already_running` |
| `NotASocket` | `conflict.not_a_socket` |
| `NotRunning` | `unavailable.not_running` |
| `PathTooLong` | `unavailable.path_too_long` |
| `VersionMismatch` | `protocol.version_mismatch` |

`unavailable.not_running` carries the message `No daemon at the selected
socket` and `data: {"socket": "<absolute selected path>"}` in both the CLI and
MCP (`cli.runtime.transportMessage` / `transportData`). A `doctor` that fails
before dispatch adds `data.fix`: `<tool> serve` for a missing daemon, otherwise a quoted runtime-directory diagnostic.

Idle and unfinished handshakes expire after ten seconds. Slow readers cannot
block other peers; exceeding a connection's output limit closes it. Call
`server.shutdown()` and continue polling until `server.connections.items` is empty
for graceful output draining and binary CLOSE frames. `deinit` releases
resources immediately, with one best-effort flush. Start and stop on the
daemon thread: binding briefly changes the process umask.

## Caller identity and grants (`proto`)

Every server creates a grant registry and a fresh mode-0600 owner token file
next to its socket. Unknown callers have `read` on `*` by default. Sharing the
UID or setting an informational pane/principal variable never grants mutation
rights. The generated CLI and MCP adapter present `<TOOL>_TOKEN` in `hello.auth`
(for example `VENOM_ECHO_TOKEN`). Invalid credentials return `denied.token`
with a reason and exit 4. Human clients may explicitly set the variable to
`@owner` to read the owner file; owner authentication is refused inside managed
process trees and for orphaned daemon descendants.

For managed processes, supply `ServerOptions.registry` with a
`proto.grants.Registry`, issue an agent or pane principal with `issueChild`,
and bind its `root` to `proto.process.stat(pid).ref` before exec. Free the
returned token with the registry allocator after passing it to the child.
Enable `ServerOptions.subreaper` for products that spawn processes. On Linux,
accept checks peer credentials, obtains a peer pidfd where supported, and walks
`/proc` using PID/starttime pairs. The nearest binding wins. Identity is cached
at accept; rights, ancestor caps, expiry and revocation are checked live.
Linux without peer pidfds uses a starttime recheck. macOS uses LOCAL_PEERPID
and proc_pidinfo; a missing PID gives an outside floor.

`Dispatcher` checks the schema's grant before calling a handler. A handler
must also call `call.authorize(right, resource)` **before** looking up that
resource, returning immediately when it returns false (the call has ended).
Use `Registry.containment = proto.grants.Containment.init(&product)` to supply
`parentOf` and `ownerOf`. Exact resource scopes include containment descendants;
`self` follows resource creators. `proto.authorizePath` returns a canonical
checked destination, including missing leaves; create destinations with
`O_NOFOLLOW`, preferably through a checked parent descriptor. `Registry.canRespond`
checks the self-approval restriction; inbox handlers also require `respond`.

The CLI generator merges the shared `whoami`, `grant.list`, `grant.issue`,
`grant.revoke` and `audit` schema bundle automatically. The dispatcher supplies
their handlers. Non-generator consumers can use `proto.grant_verbs.merge`.
`grant.issue` takes an optional tool `namespace` (`[a-z][a-z0-9-]{0,31}`):
the owner and `admin` callers may pass any but the owner's namespace, other
issuers only their own, and an omitted namespace inherits the issuer's. The
owner's namespace is the registry's tool (`Registry.ownerNamespace()`:
`venomx` in venomx, `venom` in venom) and is reserved for the product's
built-ins; a principal without one is `user`. Handlers read the
caller's namespace with `Call.namespace()` (or `Registry.namespaceOf`);
`whoami` and `grant.list` report it.

`grant.issue` with `pid` binds a principal of kind `process` to that process's
`(pid, starttime)` instead of returning a token: that
process alone resolves to it, not its children, and nothing can be stolen from
its environment. Only the owner, an `admin` or a `process` principal may bind,
and never a process holding a manager's marker. The server keeps these in `<tool>.bound` next to the socket and restores,
under new IDs, those whose process still lives, except any holding `admin`. These
show as `restored` in `grant.list`, in the audit log and in `doctor`.
Principals retain issued grants, while the registry intersects all ancestor and
connection-floor grants at use time. Delegated credentials preserve additional
floor caps. Revocation cascades; the reactor ends affected streaming calls
within one second. Products must filter each streamed resource by its current
read scope and recheck binary stream roles.

Audit records cover denials, admin requests, owner authentication and principal
issuance/revocation. Defaults are `$XDG_STATE_HOME/venom/<tool>/audit.ndjson`
or `~/.local/state/venom/<tool>/audit.ndjson`, mode 0600 in a mode-0700 directory.
Server options expose path, size and retention overrides. Audit failure never
changes authorization. `server.grantDiagnostics()` supplies the grant checks
that `cli.doctor.ServerCheck` reports. `Registry.setPolicy` validates unknown's
read-only ceiling and applies policy changes to existing connections; the cfg
bundle can use it on reload. Registry observers receive issued/revoked/denied
changes for the principal event catalog; the audit sink preserves an existing
observer. The cfg, doctor and product event bundles are separate consumers of
these APIs.

## Event streams (`proto.events`)

The event log provides epoch-qualified cursor replay, filtered snapshots,
live delivery and five-second checkpoints. Add `proto.events.manifest` to your
manifest's verb tuple and bind `events` to `proto.VerbHandler.init(&log)`.
Initialize `proto.events.Log` with the tool name, retention limits and optional
`Snapshot.init(&provider)`. A provider implements
`capture(*Provider, allocator) anyerror![]const proto.events.Entity`, returning
a consistent current projection in the supplied bounded allocator. A null
provider represents a product with no state entities.

Run all state changes, `append`, snapshot capture and `log.tick()` on the same
reactor thread. Prepare a transition first, append its redacted event, then
commit state without further fallible work or yielding. Capture must not
re-enter the log. Call `log.tick()` after appends and each poll (at least every
five seconds), after the dispatcher's authorization tick. The dispatcher must
outlive registered subscriptions. Disconnected and cancelled tickets are pruned
on the next tick. Report `log.status()` from a product doctor check; the toy's
`events.log` check does.

Defaults retain a contiguous suffix for at most ten monotonic minutes, 10,000
events or 16 MiB of compact envelopes, with an 8 MiB snapshot view budget.
Resource and type filters apply before replay, snapshot and live delivery.
Explicit unauthorized resources fail without revealing existence; empty lists
select the authorized subset. Policy reload invalidates existing projections
with `denied.event_scope`; clients take a fresh snapshot. Slow readers are
disconnected by the transport; lost live history returns
`unavailable.event_gap`. Oversized entities/items fail with
`unsupported.event_size`. Sequence exhaustion rotates the epoch and ends old
followers with a gap error; their cursors then recover through a new snapshot.

The shared publisher catalog validates closed per-type payloads before append:

| Events | Resource | Payload | Snapshot entity |
|---|---|---|---|
| `config.changed`, `config.reloaded` | `config:root` | `restart_required` | `config` |
| `pane.created` | `pane:<pane>` | `pane`, `session` | `pane` |
| `pane.title_changed` | `pane:<pane>` | `pane`, `title` | `pane` |
| `pane.exited` | `pane:<pane>` | `pane`, optional `exit_code` | `pane` |
| `pane.removed` | `pane:<pane>` | `pane` | removes `pane` |
| `program.status_changed` | `pane:<pane>` | `pane`, `reason`, `records` | `program_status` |
| `command.started` | `pane:<pane>` | `pane`, `command` | active `command` |
| `command.finished` | `pane:<pane>` | `pane`, `command`, `reason`, optional `exit_code` | removes `command` |
| `state.snapshot` | subscription | `reason`, `entities`, `complete` | control item |
| `stream.checkpoint` | subscription | empty object | control item |

Snapshot entities carry `resource`, `entity_type`, compact JSON `content` and
internal `event_types` selecting that entity. Providers must redact and validate
product state, include each selected entity once, and implement the catalog's
snapshot semantics of the event stream. Product additions extend both `log.catalog`
and the static envelope descriptor with their own payload shapes; no new event
semantics are implied by this API.

The toy publishes config changes/reloads and a redacted current config entity.
It demonstrates snapshot recovery and checkpoint tailing; unit tests publish other catalog events
through the real dispatcher to check nonempty replay and live delivery:

```sh
zig-out/bin/venom-echo events --follow=false --json
zig-out/bin/venom-echo events --after '<source>:0' --json
zig-out/bin/venom-echo doctor --json
```

## Generated CLI (`cli`)

`cli.Generator(@import("verbs.zon")) loads a format-1 verb-schema data manifest
at compile time. It rejects unknown members, invalid schemas/defaults/examples,
reserved names and global flag collisions. Its `schema` is the normalized
`proto.schema.Schema` used by the daemon's dispatcher. `parse` and `help` derive
command paths, dotted aliases and named flags from that declaration. Callers of
these two allocation APIs supply an arena that owns the returned data.

`Generator.run(gpa, argv_without_program_name, options)` executes the generated
CLI and returns the process exit status. `options` supplies stdout/stderr
writers, the process environment and an optional `Bootstrap.init(&daemon)`.
The bootstrap implements `pub fn serve(*Daemon, proto.SocketOptions) anyerror!void`;
it starts the daemon in this executable and returns on clean shutdown.
`serve` stays local, while `ping` and declared product verbs use a socket client
with hello negotiation. `run` owns its scratch memory and releases temporary
response data after every item. Embedders can pass an atomic interruption flag
set by their SIGINT handler; remote calls negotiate and send `cancel`.

Products can extend local bootstrap metadata through the compiled construction
API without opening format 1 or declaring a reserved shared verb:

```zig
const model = cli.manifest.normalize(@import("verbs.zon"));
const App = cli.WithBootstrap(model, cli.manifest.examples(@import("verbs.zon")), .{
    .serve_params = .{.{
        .name = "lifetime", .summary = "Daemon lifetime policy",
        .type = .{ .kind = .string, .choices = .{ "persistent", "on-demand" } },
        .default = "persistent",
    }},
    .startup = .{
        .verb = "session.create",
        .summary = "Only eligible ordinary local CLI calls may start a missing daemon; MCP never starts it.",
    },
});
```

Both extension members are optional. Parameters are normalized and validated
with the manifest parser before generating help, docs, completions and digest.
`App.schema` excludes local verbs; `App.verbs` and the complete digest include
them. `serve` remains absent from daemon dispatch and MCP. The startup policy
must name an existing product verb; its summary and bootstrap error declarations
join that declaration so help, docs, skill and digest share one policy source.
Products supply the full user-facing policy text themselves.

For extended serve parameters use `Bootstrap.initWithParams(&daemon)` with
`pub fn serve(*Daemon, proto.SocketOptions, std.json.Value) anyerror!void`.
The value is a borrowed validated parameter object with defaults inserted.
The legacy bootstrap API remains supported for parameter-free serve; it rejects
extended parameters rather than discarding them.

An optional `RunOptions.startup = cli.runtime.Startup.init(&launcher)` registers
three typed, cooperative callbacks: `prepare(Context) anyerror!?u32`,
`launch(Context) anyerror!void`, and `poll(Context) anyerror!Startup.Status`.
Each has a `*Launcher` receiver. Only the compiled eligible ordinary CLI verb,
after parameter validation and initial `NotRunning`, reaches `prepare`.
No hook is invoked for MCP, help, local generators or a reachable daemon.
`prepare` validates product authority and persisted config without launching;
null declines startup. A selected budget must be 100–60000 ms, measured from
the first connect attempt, including preparation time. The context supplies
that start time, a monotonic deadline, one absolute selected socket, allocator,
validated invocation and interruption flag. Context values are borrowed for
this run; the initial preparation deadline is the maximum 60000 ms budget.

`launch` runs at most once. `AlreadyRunning` is absorbed as a launch race;
`StartupFailed` or a `poll` status of `failed` records candidate failure while
allowing a winner to become ready within the budget. Otherwise `poll` returns
`pending`. Callbacks must return promptly, use bounded regular-file I/O and
honor the deadline/interruption flag: the library cannot preempt a blocking
callback. Products own eligibility, owner intent/context checks, config,
process spawning/reaping, bounded diagnostics and child lifetime. They must
keep startup output out of stdout and never send the user's mutation.
Use `StartupConfig` and `StartupContext` for redacted config/context errors.
For a product parameter rule the schema cannot express, `prepare` returns
`ctx.reject(code, message, data)`: the CLI renders that error with exit 2 and
nothing is launched. The code must be `invalid_params` or
an `invalid_params.*` code the verb declares; anything else becomes `internal`.
`data` may borrow `ctx.allocator`.

The runtime retries connection with 5–100 ms backoff and checks normal hello
authentication plus ping before dispatching the original command once. It
never unlinks paths, kills a winner or replays a sent mutation. Lost transport
after dispatch returns `unavailable.startup_result`; unresolved readiness
returns `unavailable.startup_deadline`, known candidate failure without a
winner returns `unavailable.startup_failed`, and interruption returns
`cancelled`. Startup errors have empty data and standard class exits.
Without a hook, missing-daemon behavior is unchanged.

Product-local commands (offline, never sent to the daemon) use the same compiled extension:

```zig
const App = cli.WithBootstrap(model, examples, .{ .local = .{
    .{ .name = "attach", .summary = "Attach this terminal", .interactive = true,
       .result = .{ .kind = .object, .fields = .{} } },
    .{ .name = "inspect", .summary = "Inspect local state",
       .result = .{ .kind = .string } },
} });
const Presentation = struct {
    pub const commands = .{ "attach", "inspect" };
    pub fn call(self: *@This(), ctx: cli.Local.Context) anyerror!cli.Local.Outcome {
        // Dispatch ctx.name using ctx.params (validated, defaults inserted).
        // Implement the product's presentation and local inspection here.
        _ = self;
        if (std.mem.eql(u8, ctx.name, "inspect"))
            return .{ .result = .{ .string = "local state" } };
        return .{ .result = .{ .object = .empty } };
    }
};
var presentation: Presentation = .{};
const status = try App.run(gpa, argv, .{
    .stdout = out, .stderr = err, .environ = environ,
    .local = cli.Local.init(&presentation),
});
```

`Local.init` checks the typed `call` interface; `App.run` checks that its
`commands` list serves every declaration exactly once, with no extra names.
Pass the typed registration in the options literal alongside the usual
`RunOptions` fields. `Local.Context` supplies a call allocator, wire name,
parameters, socket options (including environment), writers and interruption
flag. Values borrow the call's lifetime; allocate returned values with that
allocator. Handlers return `result`, `failure` (`code`, `message`, `data`), or
`status` (0–11). Results validate against the declaration and respect `exit`;
failures use declared errors or shared class codes, standard exits and JSON
rendering. Human mode suppresses an empty object result. Restore the terminal
before returning from a UI.

Local declarations share manifest validation, examples, parsing and defaults.
They allow an optional `grant = .none` and `interactive` boolean, and reject
streams, items, unknown fields and colliding CLI paths. They appear in help,
docs, man pages, completions and the complete digest (`dispatch: "local"` and
`interactive`), and stay outside `App.schema` and MCP. Non-interactive local
commands get a skill section; interactive commands are omitted. Interactive
commands require terminals on stdin and stdout, else `unsupported.terminal`
(exit 10) precedes handler invocation. `stdin` and `stdout_fd` identify those
descriptors (defaults 0 and 1). Local dispatch never invokes the startup hook.

Parameters use `--name value` or `--name=value`; dash-leading values require
`=`. Boolean values require `=true` or `=false`. Arrays/objects use one JSON
value. The generated parser applies defaults and the same recursive validation
as daemon dispatch, rejects repeated options, and accepts global options
between command segments. `--socket` selects the socket; `--help` works without
a daemon. Integers accept signed decimal digits; numbers use JSON syntax.

Human success output defaults to compact JSON, one result per line; human
errors go to stderr. `--json` emits only the payload or standard error wrapper
on stdout, including usage failures; help becomes `{"help":"..."}`. Streams
flush one item per line immediately, suppress successful final summaries, and
validate final results before applying result-based exit policies. Error exits
use the protocol's error-class exit codes, including transport and cancellation errors.

`src/echo/` is a minimal working toy: the ZON manifest declares `echo`,
`counter.inc` (needs `write`), `counter.get` and the streaming `sleep`, and
`main.zig` provides only bootstrap and handler logic, with no argument parsing.
Start it in one terminal, then call it from another:

```sh
zig build
zig-out/bin/venom-echo serve --json
zig-out/bin/venom-echo echo --text hi --style upper --json
zig-out/bin/venom-echo --help --json
```

Use Ctrl-C to terminate `serve` cleanly; its final JSON output is `{}`.

### Agent-contract conformance suite

`conformance/agent_contract.py` runs a product binary through the agent-contract
checks headlessly (stdin closed, no controlling TTY), one line per check:

- `binary, locking and no-daemon exit`
- `generation agreement`: the CLI, MCP tools, docs and completions agree
- `JSON output and exit codes`: `--json`
- `streams and events replay`: `events --json` replay, stream completion, terminal errors and cancellation
- `skills`, `config verbs`, `doctor` (including the `schema.digest` skew warning)
- `grants`: grant denial and MCP parity
- `headless`: the daemon serves with no client attached and restarts cleanly
- `extension boundary`: no scripting, JIT, plugin or hook entry points

`action parity` and `OSC ingestion` are product-specific and reported as `skip`.

The suite ships in the package. A product supplies a JSON profile naming a
few of its own verbs (`conformance/venom-echo.json` is the reference) and
calls the build helper:

```zig
const venom_std = b.dependency("venom_std", .{});
const check = @import("venom_std").addConformance(b, .{
    .suite = venom_std.path("conformance/agent_contract.py"),
    .exe = exe,
    .profile = b.path("conformance.json"),
});
b.step("test-conformance", "Agent-contract conformance").dependOn(&check.step);
```

The `stream` profile has two forms. The original product-stream form in
`venom-echo.json` supplies `args`, exact `items`, `slow_args`, `error_args`
and `error_code`: the runner checks finite completion, cancellation and a
terminal error after at least one item. It may explicitly set `kind` to
`"product"`; omitting `kind` preserves existing profiles.

For a product whose only ordinary stream is `events`, use:

```json
"stream": {"kind": "events"}
```

This form requires no product-specific streaming verb or error injection.
The runner validates dynamic event envelopes (source UUID, UTC timestamp,
safe sequence numbers, snapshot chunks/entities and final checkpoint), checks
finite `events --follow=false` completion without a final success record, and
cancels a live subscription with SIGINT (exit 8). It then issues a read-only
`config:root` token, follows that resource through its initial checkpoint,
and revokes the token from an owner client. The existing subscription must
end with `denied.event_scope` and exit 4. No streaming checks are skipped.
Extra event-only fields and unknown kinds are rejected. The remaining
`read`, `mutation`, `usage_error` and `config` profile entries are unchanged;
`conformance/venom-echo-events.json` is a complete working example.

`zig build test` runs both forms against venom-echo, preserves the original
read-only-mutation negative canary, and rejects deliberately broken event
completion, envelopes, cancellation and terminal errors. Run the event-only
checks separately with `zig build test-conformance-events`.

### Standard bundle, docs and completions

Every generated schema merges the shared remote verbs `skill`,
`skill.install` and `doctor` (products cannot declare them). Bind their
handlers next to the product's own:

```zig
var standard: cli.Standard(App) = .init(.{ .notes = "Hand-written SKILL.md notes", .home = home, .checks = &checks });
var dispatcher = try proto.Dispatcher.init(gpa, &App.schema, &(product_bindings ++ standard.bindings()), .{}, null);
```

- `skill` returns the deterministic SKILL.md (front matter, invocation
  conventions, read-only default, verb/grant table, per-verb reference,
  examples from the manifest, then the notes). `skill install --target
  claude-code|codex|opencode [--directory /abs/root] [--replace=true]` writes
  exactly those bytes to `<root>/<tool>/SKILL.md` on the daemon's host. It
  needs the `files` grant on the destination, resolves the root once, refuses
  symlinks below it, is a no-op for identical content and replaces atomically.
- `doctor` runs registered `cli.doctor.Check`s (vtable pattern: `pub fn
  run(*T, *cli.doctor.Report) anyerror!void`). Each result has a stable `id`,
  `ok`/`warn`/`fail`, a message and a runnable, shell-quoted `fix`; the
  report's `status` (1 if anything failed) is the CLI exit status.
  `cli.doctor.ServerCheck` covers the socket path, runtime directory, owner
  file, audit log and peer attribution; the toy adds `config.valid` (via
  `Store.check`) and `events.log`.
- `completions --shell bash|zsh|fish` and `docs [--format markdown|man]
  [--directory dir]` are local commands like `serve` and `mcp`: they never
  contact the daemon and are not MCP tools. Man pages are `<tool>.1` plus
  `<tool>-<verb>.1`; colliding page names fail generation.

```sh
source <(zig-out/bin/venom-echo completions --shell bash)
zig-out/bin/venom-echo docs --format man --directory /tmp/man
zig-out/bin/venom-echo skill
zig-out/bin/venom-echo doctor
```

## Typed ZON configuration (`cfg`)

`cfg.Store(Config, policies)` owns an arena-backed active typed snapshot.
Each struct field's Zig default is applied to missing fields. Supported data
is structs, bools, finite JSON-safe numbers, enums, optional values and slices
(strings or arrays). Unknown members, imports and executable expressions are
rejected by the standard data-only ZON parser. Policies name dotted object
fields with `secret` and/or `restart` flags. A whole-config validation callback
can report the failing dotted key. Arrays are replaced as a whole.

```zig
const Config = struct {
    appearance: struct { theme: []const u8 = "dark" } = .{},
    port: u16 = 8080,
    token: []const u8 = "",
};
const ConfigStore = cfg.Store(Config, &.{
    .{ .key = "port", .restart = true },
    .{ .key = "token", .secret = true },
});
// Own on the reactor, with an absolute path and the process's std.Io:
var config = try ConfigStore.init(gpa, .{ .io = io, .path = config_path });
defer config.deinit();
```

`cfg.configPath(gpa, tool, environ)` selects
`$XDG_CONFIG_HOME/<tool>/config.zon`, falling back to
`$HOME/.config/<tool>/config.zon`; relative roots and invalid tool names fail.
A missing file uses defaults and is not created by reads.

**Defaults layer.** Pass
`.defaults = try cfg.defaultsPaths(gpa, tool, environ)` (free with
`cfg.freePaths`; init copies it): `<dir>/<tool>/defaults.zon` for each absolute
`$XDG_CONFIG_DIRS` entry, `/etc/xdg` when unset or empty. The first existing
file is a read-only layer: builtin Zig defaults < `defaults.zon` <
`config.zon`. Struct fields merge key by key and other values are replaced by
the higher layer; a policy with `.by_name = true` (a slice of structs with a
`name: []const u8` field, e.g. venomx `keys.tables`) merges per entry name,
with user entries replacing same-named defaults in place and new names
appended. `config set` only ever writes the user file, which keeps only the
user's own keys; the value at the set key replaces the user's previous one,
by-name lists included. `config check`, `reload` and the watcher read both
files; every value in both is type-checked, so an invalid defaults file fails
like an invalid user file, and error data then carries
`source: "defaults"|"user"`. Cross-field validation runs on the effective config.
`config get` returns `{content, source, sources}`: the effective value, the
highest layer behind the key (`builtin`, `defaults`, `user`), and the source of
every value under it.

**Map keys.** A field of type `cfg.Map(V)` is written as
a struct literal with arbitrary entry names, e.g. venomx `floats.presets`:

```zig
const Floats = struct {
    default: Preset = .{},
    presets: cfg.Map(Preset) = .{}, // .entries = &.{ .{ .name = "venom.diff", .value = .{ ... } } }
};
```

```zon
.floats = .{ .presets = .{ .@"venom.settings" = .{ .width = "80%", .title = "venom settings" } } },
```

Entries merge per name across builtin (the field's Zig default entries) <
`defaults.zon` < `config.zon`; within one name the value merges like any value
of its type, so struct entries merge field by field and a user file that sets
only `.width` keeps the defaults' other fields. New names keep first-seen
order. Read entries with `map.get(name)` or iterate `map.entries`. Maps must be
reached through struct fields (not slices or optionals), and field policies
cannot address keys inside a map. `config schema` reports a map as
`{"type":"object","additionalProperties":<entry schema>}`.

Key grammar for entry names (which may contain dots): a segment after a map
key is either a **quoted name**, `floats.presets."venom.settings".width`, which
always works and is the canonical form (`sources` uses it, e.g.
`floats.presets."venom.settings"`), or **unquoted**, in which case it resolves
to the longest entry name present in the effective config that the key
continues with a valid field path (`floats.presets.venom.settings.width`). An
unquoted remainder that matches no known name is a new entry name as a whole,
so `config set floats.presets.my.tool '.{ ... }'` creates `my.tool`; set a
field of a not-yet-existing dotted entry with the quoted form. Names are
non-empty and contain no `"` or control bytes. `config set` of an entry
replaces the user's entry (defaults still merge underneath); `config set` of
the map replaces the user's entries; builtin entries are never copied into the
user file.

`current()` borrows
active typed state until successful reload; callers must not retain its slices
across a reload. The product supplies its config type and validator, including
shared grant policy validation when that section is present.

Merge `cfg.merge(cli.manifest.normalize(manifest))` into `cli.FromSchema(...)`
(or `cli.FromModel(..., cli.manifest.examples(manifest))` to keep manifest
examples in docs and the skill) to generate the five shared config verbs. Add `config.bindings()` to the
ordinary dispatcher bindings. Products cannot override these shared names.
The normalized bundle declares all refinement codes and their error data
(`{param,key}` plus an optional `source` file, except activation errors below); diagnostics never echo config
values or secret text.

**Product validation codes.** A validator may return its own
`invalid_params.*` code, e.g. `invalid_params.key_conflict`:
`cfg.Validation{ .key = "keys.tables", .code = "invalid_params.key_conflict" }`,
plus an optional `.source` to name the failing file. Declare those codes with
`cfg.mergeWith(model, .{ .errors = &.{.{ .code = "invalid_params.key_conflict", .summary = "…" }} })`
instead of `cfg.merge(model)`. They are added to `config.get`, `set`, `check`
and `reload` with the shared config error data, and `mergeWith(model, .{})`
equals `merge(model)`. A code outside `invalid_params` is reported as
`invalid_params.config_value`, which is also the default. For checks that are
per file (e.g. same-layer key conflicts), set
`.validate_layer = fn (Config, cfg.Source) ?cfg.Validation`. It runs before
`validate`, wherever the layers merge (init, get, set, check, reload, watch),
once per file: defaults when present, user, then each present overlay. Each
call gets the value that file alone gives over the builtin Zig defaults, and
for `config set` the candidate file. Its failures report that file as `source`
(and `path` for an overlay).

**Scope params.** A product whose config resolves per scope adds
optional params to `config.get` and `config.set`, and the errors they can fail
with, through `cfg.mergeWith(model, .{ .scope_params = &.{…}, .scope_errors = &.{…} })`.
The CLI, MCP tools and docs then carry them. They come after the shared params
and errors, and must have no default: absent means the store's own scope. The
shared handler ignores them, so route those two verbs to a handler of your own
(replace them in `store.bindings()`) that builds a per-call store with
`.overlays` when a scope is given and calls `store.call` when none is.

**Why `init` failed.** `Store.init` loses `failure` with the store. Use
`Store.initReporting(gpa, options, &failure)` to get the code, key and failing
file of `error.InvalidConfig`; `options.sourceName(source)` and
`options.sourcePath(source)` name the file. A validator's failure on the merged
config has no source at `check` or `reload`; at `initReporting` it goes to the
narrowest file that sets the failing key.

| CLI | Behavior |
|---|---|
| `config get --key appearance.theme --json` | Read effective ZON (builtin < defaults.zon < config.zon) with `source`/`sources`; omit `key` for the whole config; secrets are `"<redacted>"` |
| `config set --key appearance.theme --value '"light"' --json` | Parse a field value, validate the resulting effective config, atomically replace the user file; never reload implicitly |
| `config check --json` | Validate defaults.zon and config.zon; failure is an error, never `{valid:false}` |
| `config reload --json` | Stage validated hot settings and keep old restart-only values; failure leaves active state intact |
| `config schema --json` | JSON Schema inside `content`, with defaults, closed objects, enum/array/optional types, secret/restart metadata and per-key annotations |

Annotate a key for `config schema` through its field policy. The annotations
only describe: the product's validator enforces what they promise (`cfg` has no
regex engine), so keep the two side by side.

```zig
const Store = cfg.Store(Config, &.{
    .{ .key = "agents.archive_after", .description = "Idle time before archiving.", .pattern = "^[1-9][0-9]*(ms|s|m|h|d)$", .format = "duration" },
    .{ .key = "agents.max_concurrent", .minimum = 1, .maximum = 64 },
});
```

`description` fits any key and sits beside its `type` or `anyOf`. `pattern` and
`format` fit string keys, not secret ones; `minimum` and `maximum` fit numeric
keys and must lie inside the type's range. Those four land on the schema that
holds the type: inside `anyOf` for an optional, inside `items` for a list. A
misplaced annotation is a compile error. A policy with annotations alone leaves
out the secret and restart flags, like a key with no policy.

`set`/`reload` require admin; reads require read on `config:root`. Both CLI and
MCP use the same declaration and handlers. `changed` on set reflects an actual
persisted update; on reload it reflects the active snapshot. Equivalent writes
leave original bytes, comments and formatting untouched. **A changed write
serializes the user's keys canonically and discards comments/custom
formatting.** This is the initial explicit formatting policy. Temp-file writes,
flush and file sync precede same-directory atomic rename, with mode `0600`.
The default input/serialized config bound is 1 MiB.

Call `watch(monotonic_ms)` from the reactor: it checks external content at
most twice per second, applies only validated hot changes, and reports an
invalid edit once per content hash. No background thread is created. The
watcher skips the store's own writes, so set remains separate from reload.
Watcher errors leave active config intact; the owner may report the safe
refinement code. Restart requirements remain until the persisted restart
fields equal active values or a new daemon starts with them.

For fallible retention cleanup, supply
`.pre_activate = ConfigStore.PreActivate.init(&retention)`. The backend implements
`pub fn apply(self: *Retention, previous: Config, candidate: Config) ?cfg.ActivationFailure`.
Both explicit reload and watcher activation validate persisted data, overlay
restart-only fields, validate that effective candidate, and prepare all shared
allocations and any `config.reloaded` event **before** calling this hook. The
candidate is the effective config, not the persisted restart-only request.
Returning `null` certifies that cleanup, including required directory syncs,
succeeded; swapping active state and committing the event then cannot fail.
Reply delivery can still fail after activation; a lost reply does not undo it.

The hook runs synchronously on the reactor, including explicit no-op reloads
so failed cleanup can be retried. It must bound enumeration/deletions and I/O
by product limits and a deadline, returning `.limit` when exhausted. It must
prepare its own allocations and validation before irreversible effects. It
cannot yield, reenter the store, or touch the event log while an event is
prepared. The backend must outlive the store; config arguments are borrowed
only for the call and must not be retained or mutated. `init`, `set`, and
`check` never invoke it; the product enforces startup retention before readiness.

On failure return `.{ .reason = .io, .partial = true }` (categories: `io`,
`unsafe_store`, `limit`, `other`). Set `partial` whenever effects may have
occurred, including deletions whose directory sync failed. Reload returns
`error.InvalidConfig`, with `failure.code = "failed.config_activation"`; the
shared verb reports only `{reason,partial}` and a fixed message. Active values
and restart status survive, and no successful reload event is emitted. Deletions
are not rolled back. `activation_failure` retains the last effect failure for
product doctor output until a successful activation attempt; intervening
validation/check/set operations do not erase it. Never include paths, terminal
text, credentials or OS error strings in diagnostics. The watcher reports a
failed content hash once; use explicit reload to retry it without editing the
file. Successful no-op enforcement clears the diagnostic without a change event.

Secret fields in files must be empty or `secret:<name>` references, the one
reference convention; its grammar lives in `secrets.reference` and cfg uses it.
`cfg.SecretStore.init(&store)` takes a `secrets.Store` (or any backend with
`put(allocator, key, plaintext) anyerror![]const u8`): `config set` of plaintext
stores it under a fresh `cfg-<hex>` name and persists only the reference, while
a value that is already a reference (e.g. `"secret:anthropic"` after
`secrets set --name anthropic`) is kept as-is. Resolve references with
`secrets.Store.resolve`. With no backend, plaintext secret updates fail
closed. Parent-object replacement cannot bypass reference
validation. `get` and event snapshots redact both active and persisted secret
references; schema output marks them `writeOnly` and `x-venom-secret`.

With `options.events = &log`, config commits publish only
`{restart_required}`; values never enter events. `capture(allocator)` provides
the redacted `config` snapshot entity to compose with other product entities.
The event log's `prepare` allocates and validates an event without publishing;
commit it only after a successful state/file commit, or abort it on failure.
No log operation or callback may reenter between prepare and commit/abort.

The toy daemon supplies `appearance.prefix` (hot), `suffix` (restart-only),
positive `count`, and a secret `api_token` reference. Prefix/suffix affect echo
results, so the reload behavior can be tested end to end:

```sh
venom-echo serve
# In another outside shell, explicitly opt in to owner authority:
VENOM_ECHO_TOKEN=@owner venom-echo config set --key appearance.prefix --value '"hello: "' --json
VENOM_ECHO_TOKEN=@owner venom-echo config reload --json
venom-echo echo --text world --json
```

`zig build test-cfg` exercises all five verbs and MCP over the real daemon,
including watcher rejection, redaction, owner/read-only behavior and restart.
Unit tests cover typed/schema round-trips, injected rename failure/event abort,
immutable secret adapters and every allocation failure in a config lifecycle.
