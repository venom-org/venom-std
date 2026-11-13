const std = @import("std");
const cfg = @import("root.zig");
const a = std.testing.allocator;
const Config = struct {
    appearance: struct { theme: []const u8 = "dark", color: bool = true } = .{},
    count: u32 = 4,
    port: u16 = 80,
    token: []const u8 = "",
    names: []const []const u8 = &.{"one"},
};
const Store = cfg.Store(Config, &.{ .{ .key = "port", .restart = true }, .{ .key = "token", .secret = true } });
fn validate(c: Config) ?cfg.Validation {
    return if (c.count == 0) .{ .key = "count" } else null;
}
fn path(tmp: *std.testing.TmpDir) ![:0]u8 {
    return tmp.dir.realPathFileAlloc(std.testing.io, ".", a);
}
test "typed defaults, dotted set, no implicit reload, restart overlay, redaction and schema" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try path(&tmp);
    defer a.free(dir);
    const p = try std.fmt.allocPrint(a, "{s}/config.zon", .{dir});
    defer a.free(p);
    var store = try Store.init(a, .{ .io = std.testing.io, .path = p, .validate = validate });
    defer store.deinit();
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    try std.testing.expectEqualStrings("\"dark\"", try store.get(alloc, "appearance.theme"));
    try std.testing.expect((try store.set("appearance.theme", "\"light\"")).changed);
    try std.testing.expectEqualStrings("dark", store.current().appearance.theme);
    try store.watch(1000);
    try std.testing.expectEqualStrings("dark", store.current().appearance.theme);
    try std.testing.expect((try store.reload()).changed);
    try std.testing.expectEqualStrings("light", store.current().appearance.theme);
    try std.testing.expect(!(try store.set("appearance.theme", "\"light\"")).changed);
    try std.testing.expect((try store.set("port", "90")).restart_required);
    const reload = try store.reload();
    try std.testing.expect(!reload.changed and reload.restart_required);
    try std.testing.expectEqual(@as(u16, 80), store.current().port);
    try std.testing.expectEqualStrings("90", try store.get(alloc, "port"));
    try std.testing.expectError(error.InvalidConfig, store.set("count", "0"));
    try std.testing.expectEqualStrings("count", store.failure.key());
    try std.testing.expectEqualStrings("4", try store.get(alloc, "count"));
    try std.testing.expectError(error.InvalidConfig, store.set("names.0", "\"bad\""));
    try std.testing.expectError(error.InvalidConfig, store.set("appearance.", "true"));
    try std.testing.expectError(error.InvalidConfig, store.set("appearance.missing", "true"));
    try std.testing.expectEqualStrings("appearance.missing", store.failure.key());
    try std.testing.expectError(error.InvalidConfig, store.set("count", "@import(\"evil.zig\")"));
    try std.testing.expectError(error.InvalidConfig, store.set("token", "\"plaintext\""));
    _ = try store.set("token", "\"secret:ref1\"");
    try std.testing.expectEqualStrings("\"<redacted>\"", try store.get(alloc, "token"));
    const full = try store.get(alloc, "");
    try std.testing.expect(std.mem.indexOf(u8, full, "secret:ref1") == null);
    const schema = try std.json.parseFromSlice(std.json.Value, a, try store.schema(alloc), .{});
    defer schema.deinit();
    try std.testing.expect(schema.value.object.get("properties").?.object.get("token").?.object.get("x-venom-secret").?.bool);
}
test "external edits reload only valid configs and retain active state on failure" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try path(&tmp);
    defer a.free(dir);
    const p = try std.fmt.allocPrint(a, "{s}/config.zon", .{dir});
    defer a.free(p);
    var store = try Store.init(a, .{ .io = std.testing.io, .path = p, .validate = validate });
    defer store.deinit();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.zon", .data = ".{ .count = 9 }" });
    try store.watch(1000);
    try std.testing.expectEqual(@as(u32, 9), store.current().count);
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.zon", .data = ".{ .count = 0 }" });
    try std.testing.expectError(error.InvalidConfig, store.watch(1500));
    try std.testing.expectEqual(@as(u32, 9), store.current().count);
    try store.watch(2000); // unchanged rejected content is not retried
    try std.testing.expectError(error.InvalidConfig, store.check());
}

test "failed rename aborts prepared event and preserves persisted and active config" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.zon", .data = ".{ .count = 7 }" });
    const dir = try path(&tmp);
    defer a.free(dir);
    const p = try std.fmt.allocPrint(a, "{s}/config.zon", .{dir});
    defer a.free(p);
    var log = try @import("proto").events.Log.init(a, "cfg-test", .{}, null);
    defer log.deinit();
    var vtable = std.testing.io.vtable.*;
    vtable.dirRename = struct {
        fn fail(_: ?*anyopaque, _: std.Io.Dir, _: []const u8, _: std.Io.Dir, _: []const u8) std.Io.Dir.RenameError!void {
            return error.AccessDenied;
        }
    }.fail;
    var io = std.testing.io;
    io.vtable = &vtable;
    var store = try Store.init(a, .{ .io = io, .path = p, .events = &log });
    defer store.deinit();
    try std.testing.expectError(error.InvalidConfig, store.set("count", "8"));
    try std.testing.expectEqualStrings("failed.config_io", store.failure.code);
    try std.testing.expectEqual(@as(u64, 0), log.high);
    try std.testing.expectEqual(@as(usize, 0), log.entries.items.len);
    try std.testing.expectEqual(@as(u32, 7), store.current().count);
    const contents = try tmp.dir.readFileAlloc(std.testing.io, "config.zon", a, .limited(4096));
    defer a.free(contents);
    try std.testing.expectEqualStrings(".{ .count = 7 }", contents);
}

test "secret store receives plaintext but config and snapshots contain only references or redaction" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try path(&tmp);
    defer a.free(dir);
    const p = try std.fmt.allocPrint(a, "{s}/config.zon", .{dir});
    defer a.free(p);
    var log = try @import("proto").events.Log.init(a, "cfg-test", .{}, null);
    defer log.deinit();
    const Secrets = struct {
        called: bool = false,
        pub fn put(self: *@This(), alloc: std.mem.Allocator, key: []const u8, secret: []const u8) anyerror![]const u8 {
            try std.testing.expectEqualStrings("token", key);
            try std.testing.expectEqualStrings("sensitive-value", secret);
            self.called = true;
            return alloc.dupe(u8, "secret:opaque1");
        }
    };
    var secrets: Secrets = .{};
    var store = try Store.init(a, .{ .io = std.testing.io, .path = p, .events = &log, .secrets = cfg.SecretStore.init(&secrets) });
    defer store.deinit();
    _ = try store.set("token", "\"sensitive-value\"");
    try std.testing.expect(secrets.called);
    try std.testing.expectEqualStrings("", store.current().token);
    _ = try store.reload();
    try std.testing.expectEqualStrings("secret:opaque1", store.current().token);
    const file = try tmp.dir.readFileAlloc(std.testing.io, "config.zon", a, .limited(4096));
    defer a.free(file);
    try std.testing.expect(std.mem.indexOf(u8, file, "secret:opaque1") != null);
    try std.testing.expect(std.mem.indexOf(u8, file, "sensitive-value") == null);
    for (log.entries.items) |event| try std.testing.expect(std.mem.indexOf(u8, event.bytes, "sensitive-value") == null);
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const entities = try store.capture(arena.allocator());
    try std.testing.expect(std.mem.indexOf(u8, entities[0].content, "sensitive-value") == null);
    try std.testing.expect(std.mem.indexOf(u8, entities[0].content, "secret:opaque1") == null);
    try std.testing.expect(std.mem.indexOf(u8, entities[0].content, "<redacted>") != null);
}

test "set can repair invalid persisted values and rejects parent secret bypass" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try path(&tmp);
    defer a.free(dir);
    const p = try std.fmt.allocPrint(a, "{s}/config.zon", .{dir});
    defer a.free(p);
    var store = try Store.init(a, .{ .io = std.testing.io, .path = p, .validate = validate });
    defer store.deinit();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.zon", .data = ".{ .count = 0 }" });
    try std.testing.expectError(error.InvalidConfig, store.check());
    _ = try store.set("count", "3");
    try store.check();
    try std.testing.expectError(error.InvalidConfig, store.set("count", "true"));
    try std.testing.expectEqualStrings("count", store.failure.key());
    try std.testing.expectError(error.InvalidConfig, store.set("", ".{}"));
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.zon", .data = ".{ .token = \"plaintext\" }" });
    try std.testing.expectError(error.InvalidConfig, store.check());
    _ = try store.set("token", "\"\"");
    try store.check();
}

test "JSON-equivalent schema covers typed defaults, enum, optional, arrays and finite numbers" {
    const Typed = struct { mode: enum { quiet, loud } = .quiet, option: ?i16 = null, scale: f64 = 1, list: []const u32 = &.{ 1, 2 } };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try path(&tmp);
    defer a.free(dir);
    const p = try std.fmt.allocPrint(a, "{s}/config.zon", .{dir});
    defer a.free(p);
    var store = try cfg.Store(Typed, &.{}).init(a, .{ .io = std.testing.io, .path = p });
    defer store.deinit();
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    const schema = try std.json.parseFromSlice(std.json.Value, a, try store.schema(alloc), .{});
    defer schema.deinit();
    const props = schema.value.object.get("properties").?.object;
    try std.testing.expectEqualStrings("quiet", props.get("mode").?.object.get("default").?.string);
    try std.testing.expectEqual(@as(usize, 2), props.get("option").?.object.get("anyOf").?.array.items.len);
    _ = try store.set("mode", ".loud");
    _ = try store.set("option", "-12");
    _ = try store.set("list", ".{3,4}");
    try std.testing.expectError(error.InvalidConfig, store.set("scale", "nan"));
    try std.testing.expectError(error.InvalidConfig, store.set("scale", "inf"));
    try std.testing.expectError(error.InvalidConfig, store.set("mode", ".unknown"));
}

test "schema emits per-key annotations where each kind of key holds its type" {
    const Annotated = struct {
        agents: struct {
            archive_after: []const u8 = "3d",
            max_concurrent: u32 = 4,
            plain: u32 = 1,
        } = .{},
        timeout: ?[]const u8 = null,
        warn_at: ?u8 = 80,
        ratio: f64 = 0.5,
        tags: []const []const u8 = &.{},
        port: u16 = 80,
        token: []const u8 = "",
        unannotated: []const u8 = "",
    };
    const duration = "^[1-9][0-9]*(ms|s|m|h|d)$";
    const S = cfg.Store(Annotated, &.{
        .{ .key = "agents", .description = "Agent lifecycle." },
        .{ .key = "agents.archive_after", .description = "Idle time before archiving.", .pattern = duration, .format = "duration" },
        .{ .key = "agents.max_concurrent", .minimum = 1, .maximum = 64 },
        .{ .key = "agents.plain", .restart = true },
        .{ .key = "timeout", .pattern = duration, .description = "Null never times out." },
        .{ .key = "warn_at", .maximum = 100 },
        .{ .key = "ratio", .minimum = 0, .maximum = 1.5 },
        .{ .key = "tags", .pattern = "^[a-z]+$", .description = "Lowercase tags." },
        .{ .key = "port", .restart = true, .description = "Listening port.", .minimum = 1024 },
        .{ .key = "token", .secret = true, .description = "API token." },
    });
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try path(&tmp);
    defer a.free(dir);
    const p = try std.fmt.allocPrint(a, "{s}/config.zon", .{dir});
    defer a.free(p);
    var store = try S.init(a, .{ .io = std.testing.io, .path = p });
    defer store.deinit();
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const parsed = try std.json.parseFromSlice(std.json.Value, a, try store.schema(arena.allocator()), .{});
    defer parsed.deinit();
    const props = parsed.value.object.get("properties").?.object;
    const expect = std.testing.expect;
    const expectStr = std.testing.expectEqualStrings;
    const expectInt = struct {
        fn f(want: i64, got: std.json.Value) !void {
            try std.testing.expectEqual(want, got.integer);
        }
    }.f;

    // A table: description, and no flags to contradict a child's.
    const agents = props.get("agents").?.object;
    try expectStr("Agent lifecycle.", agents.get("description").?.string);
    try expect(agents.get("x-venom-restart-required") == null and agents.get("writeOnly") == null);
    const inner = agents.get("properties").?.object;
    // A string: everything beside its type and default.
    const archive = inner.get("archive_after").?.object;
    try expectStr("Idle time before archiving.", archive.get("description").?.string);
    try expectStr(duration, archive.get("pattern").?.string);
    try expectStr("duration", archive.get("format").?.string);
    try expectStr("3d", archive.get("default").?.string);
    try expect(archive.get("x-venom-secret") == null);
    // An integer: bounds replace the type's; absent ones keep it.
    const limit = inner.get("max_concurrent").?.object;
    try expectInt(1, limit.get("minimum").?);
    try expectInt(64, limit.get("maximum").?);
    const warn_at = props.get("warn_at").?.object;
    const warn_variant = warn_at.get("anyOf").?.array.items[0].object;
    try expectInt(0, warn_variant.get("minimum").?);
    try expectInt(100, warn_variant.get("maximum").?);
    try expect(warn_at.get("maximum") == null);
    // An optional: the description outside `anyOf`, the constraint on the string.
    const timeout = props.get("timeout").?.object;
    try expectStr("Null never times out.", timeout.get("description").?.string);
    try expect(timeout.get("pattern") == null);
    const variants = timeout.get("anyOf").?.array.items;
    try expectStr(duration, variants[0].object.get("pattern").?.string);
    try expect(variants[0].object.get("description") == null);
    try expect(variants[1].object.get("pattern") == null);
    // A float.
    const ratio = props.get("ratio").?.object;
    try std.testing.expectEqual(@as(f64, 1.5), ratio.get("maximum").?.float);
    try expect(ratio.get("minimum") != null);
    // A list: the description on the key, the pattern on each element.
    const tags = props.get("tags").?.object;
    try expectStr("Lowercase tags.", tags.get("description").?.string);
    try expect(tags.get("pattern") == null);
    try expectStr("^[a-z]+$", tags.get("items").?.object.get("pattern").?.string);
    try expect(tags.get("items").?.object.get("description") == null);
    // Annotations sit next to the flags they do not replace.
    const port = props.get("port").?.object;
    try expect(port.get("x-venom-restart-required").?.bool);
    try expectStr("Listening port.", port.get("description").?.string);
    try expectInt(1024, port.get("minimum").?);
    try expectInt(65535, port.get("maximum").?);
    const token = props.get("token").?.object;
    try expect(token.get("x-venom-secret").?.bool);
    try expectStr("API token.", token.get("description").?.string);
    try expect(token.get("default") == null);
    // No policy, or a policy without annotations: as before.
    try expect(inner.get("plain").?.object.get("description") == null);
    try expect(inner.get("plain").?.object.get("x-venom-restart-required").?.bool);
    const plain = props.get("unannotated").?.object;
    try std.testing.expectEqual(@as(usize, 2), plain.count());
    // Annotations describe; the product's validator enforces.
    _ = try store.set("agents.max_concurrent", "65");
    try store.check();
}

test "config location honors XDG and rejects relative or missing homes" {
    const env: std.process.Environ = .{ .block = .{ .slice = &[_:null]?[*:0]const u8{ "XDG_CONFIG_HOME=/cfg", "HOME=/home/u" } } };
    const p = try cfg.configPath(a, "test", env);
    defer a.free(p);
    try std.testing.expectEqualStrings("/cfg/test/config.zon", p);
    const fallback: std.process.Environ = .{ .block = .{ .slice = &[_:null]?[*:0]const u8{ "XDG_CONFIG_HOME=", "HOME=/home/u" } } };
    const q = try cfg.configPath(a, "test", fallback);
    defer a.free(q);
    try std.testing.expectEqualStrings("/home/u/.config/test/config.zon", q);
    const invalid: std.process.Environ = .{ .block = .{ .slice = &[_:null]?[*:0]const u8{"XDG_CONFIG_HOME=relative"} } };
    try std.testing.expectError(error.InvalidConfigPath, cfg.configPath(a, "test", invalid));
}

test "all config snapshot and event allocation failures release ownership" {
    // Like std.testing.checkAllAllocationFailures, but a run that needs fewer
    // allocations than the first is accepted: ArenaAllocator grows in place
    // when the backing allocator's layout allows it, so the count varies by
    // one or two between runs. Swallowed failures still fail, and the testing
    // allocator still reports any leak.
    const needed = blk: {
        var counting = std.testing.FailingAllocator.init(a, .{});
        try allocationLifecycle(counting.allocator());
        break :blk counting.alloc_index;
    };
    for (0..needed) |index| {
        var failing = std.testing.FailingAllocator.init(a, .{ .fail_index = index });
        if (allocationLifecycle(failing.allocator())) |_| {
            if (failing.has_induced_failure) return error.SwallowedOutOfMemoryError;
        } else |err| switch (err) {
            error.OutOfMemory => try std.testing.expectEqual(failing.allocated_bytes, failing.freed_bytes),
            else => return err,
        }
    }
}
fn allocationLifecycle(alloc: std.mem.Allocator) !void {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try path(&tmp);
    defer a.free(dir);
    const p = try std.fmt.allocPrint(a, "{s}/config.zon", .{dir});
    defer a.free(p);
    var log = try @import("proto").events.Log.init(alloc, "cfg-test", .{}, null);
    defer log.deinit();
    var retention: Retention = .{};
    var store = try Store.init(alloc, .{ .io = std.testing.io, .path = p, .events = &log, .pre_activate = Store.PreActivate.init(&retention) });
    defer store.deinit();
    _ = try store.set("count", "7");
    _ = store.reload() catch |err| {
        try std.testing.expectEqual(@as(usize, 0), retention.calls);
        try std.testing.expectEqual(@as(u32, 4), store.current().count);
        try std.testing.expectEqual(@as(u64, 1), log.high);
        return err;
    };
    try std.testing.expectEqual(@as(usize, 1), retention.calls);
    try std.testing.expectEqual(@as(u64, 2), log.high);
}

test "the real secrets store backs secret fields; files hold only secret:<name> references" {
    const secrets = @import("secrets");
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try path(&tmp);
    defer a.free(dir);
    const config_path = try std.fmt.allocPrint(a, "{s}/config.zon", .{dir});
    defer a.free(config_path);
    var vault = try secrets.Store.open(a, io, tmp.dir, .{});
    defer vault.deinit();
    var store = try Store.init(a, .{ .io = io, .path = config_path, .secrets = cfg.SecretStore.init(&vault) });
    defer store.deinit();

    // Plaintext goes to the encrypted store; config keeps a reference.
    _ = try store.set("token", "\"sk-ant-plaintext\"");
    _ = try store.reload();
    const generated = store.current().token;
    try std.testing.expect(std.mem.startsWith(u8, generated, "secret:cfg-"));
    try std.testing.expectEqualStrings("sk-ant-plaintext", try vault.resolve(generated));
    const file = try tmp.dir.readFileAlloc(io, "config.zon", a, .limited(4096));
    defer a.free(file);
    try std.testing.expect(std.mem.indexOf(u8, file, "sk-ant-plaintext") == null);

    // A secret stored by name (`secrets.set`) is referenced the same way,
    // dotted names included; the reference is kept as-is, not re-stored.
    _ = try vault.set("anthropic.prod", "sk-named");
    const before = vault.list().len;
    _ = try store.set("token", "\"secret:anthropic.prod\"");
    _ = try store.reload();
    try std.testing.expectEqual(before, vault.list().len);
    try std.testing.expectEqualStrings("sk-named", try vault.resolve(store.current().token));
}

// A bounded retention backend: injected failure either precedes deletion or
// follows one deletion (including a failed directory-sync equivalent).
const Retention = struct {
    calls: usize = 0,
    deleted: usize = 0,
    fail: ?cfg.ActivationFailure = null,
    previous_port: u16 = 0,
    candidate_port: u16 = 0,
    pub fn apply(self: *@This(), previous: Config, candidate: Config) ?cfg.ActivationFailure {
        self.calls += 1;
        self.previous_port = previous.port;
        self.candidate_port = candidate.port;
        if (self.fail) |failure| {
            if (failure.partial) self.deleted += 1;
            return failure;
        }
        self.deleted += 1;
        return null;
    }
};

test "explicit and watcher activation share fallible retention and never publish false success" {
    for ([_]bool{ false, true }) |watcher| {
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const dir = try path(&tmp);
        defer a.free(dir);
        const p = try std.fmt.allocPrint(a, "{s}/config.zon", .{dir});
        defer a.free(p);
        var log = try @import("proto").events.Log.init(a, "cfg-test", .{}, null);
        defer log.deinit();
        var retention: Retention = .{};
        var store = try Store.init(a, .{ .io = std.testing.io, .path = p, .validate = validate, .events = &log, .pre_activate = Store.PreActivate.init(&retention) });
        defer store.deinit();
        try std.testing.expectEqual(@as(usize, 0), retention.calls);
        _ = try store.set("count", "7");
        try store.check();
        try store.watch(0); // own persisted writes never activate
        try std.testing.expectEqual(@as(usize, 0), retention.calls);
        const high = log.high;
        // Invalid persisted and invalid effective hot/restart combinations must
        // both be rejected before any hook call.
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.zon", .data = ".{ .count = 0 }" });
        try std.testing.expectError(error.InvalidConfig, activate(&store, watcher, 500));
        try std.testing.expectEqual(@as(usize, 0), retention.calls);
        try std.testing.expectEqual(high, log.high);

        for ([_]bool{ false, true }, 0..) |partial, i| {
            retention.fail = .{ .reason = .io, .partial = partial };
            const data = if (partial) ".{ .count = 8, .port = 90 }" else ".{ .count = 9, .port = 90 }";
            try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.zon", .data = data });
            try std.testing.expectError(error.InvalidConfig, activate(&store, watcher, 1000 + @as(i64, @intCast(i)) * 500));
            try std.testing.expectEqualStrings("failed.config_activation", store.failure.code);
            try std.testing.expectEqualStrings("", store.failure.key());
            try std.testing.expectEqual(partial, store.activation_failure.?.partial);
            try std.testing.expectEqual(@as(u32, 4), store.current().count);
            try std.testing.expect(!store.restart_required);
            try std.testing.expectEqual(high, log.high);
            try std.testing.expectEqual(@as(u16, 80), retention.previous_port);
            try std.testing.expectEqual(@as(u16, 80), retention.candidate_port);
        }
        try std.testing.expectEqual(@as(usize, 1), retention.deleted);
        if (watcher) {
            try store.watch(2000); // rejected hash is not retried automatically
            try std.testing.expectEqual(@as(usize, 2), retention.calls);
        }
        retention.fail = null;
        // Explicit reload retries unchanged persisted content after failure.
        try std.testing.expect((try store.reload()).changed);
        try std.testing.expectEqual(@as(u32, 8), store.current().count);
        try std.testing.expect(store.restart_required);
        try std.testing.expect(store.activation_failure == null);
        try std.testing.expectEqual(high + 1, log.high);
        try std.testing.expectEqual(@as(usize, 2), retention.deleted);
        try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.zon", .data = ".{ .count = 10, .port = 90 }" });
        try activate(&store, watcher, 2500);
        try std.testing.expectEqual(@as(u32, 10), store.current().count);
        try std.testing.expectEqual(high + 2, log.high);
        // No-op explicit retry still enforces policy but emits no change event.
        try std.testing.expect(!(try store.reload()).changed);
        try std.testing.expectEqual(high + 2, log.high);
    }
}
fn activate(store: *Store, watcher: bool, now: i64) !void {
    if (watcher) return store.watch(now);
    _ = try store.reload();
}

test "invalid effective restart overlay never invokes retention" {
    const Mixed = struct {
        pub fn validateMix(c: Config) ?cfg.Validation {
            return if (c.count > c.port) .{ .key = "count" } else null;
        }
    };
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try path(&tmp);
    defer a.free(dir);
    const p = try std.fmt.allocPrint(a, "{s}/config.zon", .{dir});
    defer a.free(p);
    var retention: Retention = .{};
    var store = try Store.init(a, .{ .io = std.testing.io, .path = p, .validate = Mixed.validateMix, .pre_activate = Store.PreActivate.init(&retention) });
    defer store.deinit();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.zon", .data = ".{ .count = 90, .port = 100 }" });
    try store.check();
    try std.testing.expectError(error.InvalidConfig, store.reload());
    try std.testing.expectEqual(@as(usize, 0), retention.calls);
}

test "shared reload handler exposes only declared activation failure data" {
    const proto = @import("proto");
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try path(&tmp);
    defer a.free(dir);
    const p = try std.fmt.allocPrint(a, "{s}/config.zon", .{dir});
    defer a.free(p);
    var retention: Retention = .{ .fail = .{ .reason = .unsafe_store, .partial = true } };
    var store = try Store.init(a, .{ .io = std.testing.io, .path = p, .pre_activate = Store.PreActivate.init(&retention) });
    defer store.deinit();
    const model: proto.schema.Schema = .{ .tool = "cfg-test", .summary = "Config", .verbs = &cfg.verbs };
    const bindings = store.bindings();
    var dispatcher = try proto.Dispatcher.init(a, &model, &bindings, .{}, null);
    defer dispatcher.deinit();
    var registry = try proto.grants.Registry.init(a, "cfg-test", .{});
    defer registry.deinit();
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds) != 0) return error.SystemResources;
    defer proto.os.close(fds[1]);
    var conn = proto.Connection.init(a, fds[0]);
    defer conn.deinit();
    conn.protocol = .ndjson;
    conn.ready = true;
    conn.version = 1;
    conn.registry = &registry;
    conn.identity = .{ .principal = proto.grants.owner };
    try dispatcher.message(&conn, .{ .ndjson = "{\"id\":1,\"verb\":\"config.reload\"}" });
    var response = try proto.Response.parse(a, std.mem.trim(u8, conn.output.items, "\n"));
    defer response.deinit();
    try std.testing.expect(response.body == .@"error");
    const failure = response.body.@"error";
    try std.testing.expectEqualStrings("failed.config_activation", failure.code);
    try std.testing.expectEqual(@as(usize, 2), failure.data.?.object.count());
    try std.testing.expectEqualStrings("unsafe_store", failure.data.?.object.get("reason").?.string);
    try std.testing.expect(failure.data.?.object.get("partial").?.bool);
}

const Layered = struct {
    appearance: struct { theme: []const u8 = "dark", color: bool = true } = .{},
    count: u32 = 4,
    token: []const u8 = "",
    tables: []const struct { name: []const u8, prefix: []const u8 = "", keys: []const []const u8 = &.{} } = &.{},
};
const LayeredStore = cfg.Store(Layered, &.{ .{ .key = "tables", .by_name = true }, .{ .key = "token", .secret = true } });
fn layeredValidate(c: Layered) ?cfg.Validation {
    return if (c.count == 0) .{ .key = "count" } else null;
}
fn sourceOf(found: cfg.Lookup, key: []const u8) ?cfg.Source {
    for (found.sources) |e| if (std.mem.eql(u8, e.key, key)) return e.source;
    return null;
}

test "defaults.zon is a read-only layer between builtin values and the user file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try path(&tmp);
    defer a.free(dir);
    try tmp.dir.createDirPath(io, "etc1/tool");
    try tmp.dir.createDirPath(io, "etc2/tool");
    try tmp.dir.createDirPath(io, "home/tool");
    const defaults_zon =
        \\.{
        \\    // shipped by the distribution
        \\    .appearance = .{ .theme = "os" },
        \\    .count = 6,
        \\    .tables = .{
        \\        .{ .name = "venom", .prefix = "a", .keys = .{"x"} },
        \\        .{ .name = "os", .prefix = "o" },
        \\    },
        \\}
    ;
    // The first existing candidate wins; etc1 has none.
    try tmp.dir.writeFile(io, .{ .sub_path = "etc2/tool/defaults.zon", .data = defaults_zon });
    try tmp.dir.writeFile(io, .{ .sub_path = "home/tool/config.zon", .data = ".{ .appearance = .{ .color = false }, .tables = .{ .{ .name = \"venom\", .prefix = \"v\" }, .{ .name = \"mine\" } } }" });
    const user = try std.fmt.allocPrint(a, "{s}/home/tool/config.zon", .{dir});
    defer a.free(user);
    const d1 = try std.fmt.allocPrint(a, "{s}/etc1/tool/defaults.zon", .{dir});
    defer a.free(d1);
    const d2 = try std.fmt.allocPrint(a, "{s}/etc2/tool/defaults.zon", .{dir});
    defer a.free(d2);
    const defaults_bytes = try tmp.dir.readFileAlloc(io, "etc2/tool/defaults.zon", a, .limited(4096));
    defer a.free(defaults_bytes);

    var store = try LayeredStore.init(a, .{ .io = io, .path = user, .defaults = &.{ d1, d2 }, .validate = layeredValidate });
    defer store.deinit();
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Struct fields merge key by key; scalars come from the highest layer.
    const c = store.current();
    try std.testing.expectEqualStrings("os", c.appearance.theme);
    try std.testing.expect(!c.appearance.color);
    try std.testing.expectEqual(@as(u32, 6), c.count);
    // by_name: user "venom" replaces the defaults entry in place, "os" stays, "mine" is appended.
    try std.testing.expectEqual(@as(usize, 3), c.tables.len);
    try std.testing.expectEqualStrings("venom", c.tables[0].name);
    try std.testing.expectEqualStrings("v", c.tables[0].prefix);
    try std.testing.expectEqual(@as(usize, 0), c.tables[0].keys.len);
    try std.testing.expectEqualStrings("os", c.tables[1].name);
    try std.testing.expectEqualStrings("mine", c.tables[2].name);

    // Sources per value.
    const all = try store.lookup(alloc, "");
    try std.testing.expectEqual(cfg.Source.user, all.source);
    try std.testing.expectEqual(cfg.Source.defaults, sourceOf(all, "appearance.theme").?);
    try std.testing.expectEqual(cfg.Source.user, sourceOf(all, "appearance.color").?);
    try std.testing.expectEqual(cfg.Source.defaults, sourceOf(all, "count").?);
    try std.testing.expectEqual(cfg.Source.builtin, sourceOf(all, "token").?);
    try std.testing.expectEqual(cfg.Source.user, sourceOf(all, "tables").?);
    const theme = try store.lookup(alloc, "appearance.theme");
    try std.testing.expectEqualStrings("\"os\"", theme.content);
    try std.testing.expectEqual(cfg.Source.defaults, theme.source);
    try std.testing.expectEqual(@as(usize, 1), theme.sources.len);
    try std.testing.expectEqual(cfg.Source.defaults, (try store.lookup(alloc, "count")).source);
    try std.testing.expectEqual(cfg.Source.user, (try store.lookup(alloc, "appearance")).source);

    // set writes only the user file, keeps only user keys and overrides the default.
    try std.testing.expect((try store.set("count", "9")).changed);
    _ = try store.reload();
    try std.testing.expectEqual(@as(u32, 9), store.current().count);
    try std.testing.expectEqual(cfg.Source.user, (try store.lookup(alloc, "count")).source);
    const written = try tmp.dir.readFileAlloc(io, "home/tool/config.zon", a, .limited(4096));
    defer a.free(written);
    try std.testing.expect(std.mem.indexOf(u8, written, ".count = 9") != null);
    try std.testing.expect(std.mem.indexOf(u8, written, "theme") == null);
    try std.testing.expect(std.mem.indexOf(u8, written, "\"os\"") == null);
    const after_defaults = try tmp.dir.readFileAlloc(io, "etc2/tool/defaults.zon", a, .limited(4096));
    defer a.free(after_defaults);
    try std.testing.expectEqualStrings(defaults_bytes, after_defaults);
    // Setting a by_name key replaces the user's list; defaults entries still merge in.
    _ = try store.set("tables", ".{ .{ .name = \"os\", .prefix = \"O\" } }");
    _ = try store.reload();
    try std.testing.expectEqual(@as(usize, 2), store.current().tables.len);
    try std.testing.expectEqualStrings("a", store.current().tables[0].prefix);
    try std.testing.expectEqualStrings("O", store.current().tables[1].prefix);
    // Setting a struct key replaces the user's struct, other defaults remain.
    _ = try store.set("appearance", ".{ .color = true }");
    _ = try store.reload();
    try std.testing.expectEqualStrings("os", store.current().appearance.theme);
    try std.testing.expect(store.current().appearance.color);
    // A value cannot reach another key through the nested set.
    try std.testing.expectError(error.InvalidConfig, store.set("count", "1, .token = \"x\""));
    try std.testing.expectEqualStrings("count", store.failure.key());

    // An external edit of the defaults file is watched like the user file.
    try tmp.dir.writeFile(io, .{ .sub_path = "etc2/tool/defaults.zon", .data = ".{ .appearance = .{ .theme = \"os2\" } }" });
    try store.watch(1000);
    try std.testing.expectEqualStrings("os2", store.current().appearance.theme);
    // An earlier candidate takes over once it exists.
    try tmp.dir.writeFile(io, .{ .sub_path = "etc1/tool/defaults.zon", .data = ".{ .appearance = .{ .theme = \"first\" } }" });
    try store.watch(2000);
    try std.testing.expectEqualStrings("first", store.current().appearance.theme);
}

test "an invalid defaults file fails check, reload and set like an invalid user file" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try path(&tmp);
    defer a.free(dir);
    const user = try std.fmt.allocPrint(a, "{s}/config.zon", .{dir});
    defer a.free(user);
    const defaults = try std.fmt.allocPrint(a, "{s}/defaults.zon", .{dir});
    defer a.free(defaults);
    var store = try LayeredStore.init(a, .{ .io = io, .path = user, .defaults = &.{defaults}, .validate = layeredValidate });
    defer store.deinit();
    const cases = [_]struct { zon: []const u8, code: []const u8, key: []const u8 }{
        .{ .zon = ".{ .broken = ", .code = "invalid_params.config_zon", .key = "" },
        .{ .zon = ".{ .count = \"six\" }", .code = "invalid_params.config_zon", .key = "count" },
        .{ .zon = ".{ .appearance = .{ .missing = 1 } }", .code = "invalid_params.config_zon", .key = "appearance.missing" },
        .{ .zon = ".{ .token = \"plaintext\" }", .code = "invalid_params.config_secret", .key = "token" },
        .{ .zon = ".{ .tables = .{ .{ .name = \"a\" }, .{ .name = \"a\" } } }", .code = "invalid_params.config_value", .key = "tables" },
        .{ .zon = ".{ .tables = .{ .{ .prefix = \"no name\" } } }", .code = "invalid_params.config_zon", .key = "tables" },
        .{ .zon = ".{ .count = 0 }", .code = "invalid_params.config_value", .key = "count" },
    };
    for (cases) |case| {
        try tmp.dir.writeFile(io, .{ .sub_path = "defaults.zon", .data = case.zon });
        try std.testing.expectError(error.InvalidConfig, store.check());
        try std.testing.expectEqualStrings(case.code, store.failure.code);
        try std.testing.expectEqualStrings(case.key, store.failure.key());
        // Semantic validation runs on the effective config, not a single file.
        if (!std.mem.eql(u8, case.code, "invalid_params.config_value") or !std.mem.eql(u8, case.key, "count"))
            try std.testing.expectEqual(cfg.Source.defaults, store.failure.source.?);
        try std.testing.expectError(error.InvalidConfig, store.reload());
        try std.testing.expectError(error.InvalidConfig, store.set("appearance.theme", "\"x\""));
    }
    try std.testing.expectEqual(@as(u32, 4), store.current().count);
    // The same errors in the user file are attributed to it.
    try tmp.dir.writeFile(io, .{ .sub_path = "defaults.zon", .data = ".{}" });
    try tmp.dir.writeFile(io, .{ .sub_path = "config.zon", .data = ".{ .count = \"six\" }" });
    try std.testing.expectError(error.InvalidConfig, store.check());
    try std.testing.expectEqual(cfg.Source.user, store.failure.source.?);
    try std.testing.expectEqualStrings("count", store.failure.key());
    // A user value that overrides a valid default is checked too; fixing it works.
    try tmp.dir.writeFile(io, .{ .sub_path = "config.zon", .data = ".{}" });
    try store.check();
    // A defaults path that is a directory is an I/O failure of the defaults layer.
    try tmp.dir.deleteFile(io, "defaults.zon");
    try tmp.dir.createDirPath(io, "defaults.zon");
    try std.testing.expectError(error.InvalidConfig, store.check());
    try std.testing.expectEqualStrings("failed.config_io", store.failure.code);
    try std.testing.expectEqual(cfg.Source.defaults, store.failure.source.?);
}

test "defaults candidates follow XDG_CONFIG_DIRS" {
    const env: std.process.Environ = .{ .block = .{ .slice = &[_:null]?[*:0]const u8{"XDG_CONFIG_DIRS=/opt/xdg/:relative::/etc/xdg"} } };
    const paths = try cfg.defaultsPaths(a, "venomx", env);
    defer cfg.freePaths(a, paths);
    try std.testing.expectEqual(@as(usize, 2), paths.len);
    try std.testing.expectEqualStrings("/opt/xdg/venomx/defaults.zon", paths[0]);
    try std.testing.expectEqualStrings("/etc/xdg/venomx/defaults.zon", paths[1]);
    for ([_][]const ?[*:0]const u8{ &.{}, &.{"XDG_CONFIG_DIRS="} }) |vars| {
        var block: [2:null]?[*:0]const u8 = .{ null, null };
        for (vars, 0..) |v, i| block[i] = v;
        const fallback = try cfg.defaultsPaths(a, "venomx", .{ .block = .{ .slice = block[0..vars.len :null] } });
        defer cfg.freePaths(a, fallback);
        try std.testing.expectEqual(@as(usize, 1), fallback.len);
        try std.testing.expectEqualStrings("/etc/xdg/venomx/defaults.zon", fallback[0]);
    }
    try std.testing.expectError(error.InvalidTool, cfg.defaultsPaths(a, "../x", env));
}

// floats.presets as a struct-literal map.
const Preset = struct { width: []const u8 = "60%", height: []const u8 = "60%", anchor: []const u8 = "center", y: i32 = 0, title: ?[]const u8 = null };
const Floats = struct {
    default: Preset = .{},
    presets: cfg.Map(Preset) = .{ .entries = &.{.{ .name = "venom.diff", .value = .{ .width = "100%", .height = "70%", .anchor = "bottom" } }} },
};
const Mapped = struct { count: u32 = 1, floats: Floats = .{} };
const MappedStore = cfg.Store(Mapped, &.{.{ .key = "count", .restart = true }});

test "map keys parse struct-literal preset syntax and merge per name across builtin, defaults and user" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try path(&tmp);
    defer a.free(dir);
    const user = try std.fmt.allocPrint(a, "{s}/config.zon", .{dir});
    defer a.free(user);
    const defaults = try std.fmt.allocPrint(a, "{s}/defaults.zon", .{dir});
    defer a.free(defaults);
    try tmp.dir.writeFile(io, .{ .sub_path = "defaults.zon", .data =
        \\.{
        \\    .floats = .{
        \\        .default = .{ .width = "60%", .height = "60%", .anchor = "center" },
        \\        .presets = .{
        \\            .@"venom.settings" = .{ .width = "80%", .height = "80%", .anchor = "center", .title = "venom settings" },
        \\            .@"venom-os.launcher" = .{ .width = "50%", .height = "40%", .anchor = "top", .y = 2 },
        \\            .@"venom.diff" = .{ .height = "50%" },
        \\        },
        \\    },
        \\}
    });
    try tmp.dir.writeFile(io, .{ .sub_path = "config.zon", .data = ".{ .floats = .{ .presets = .{ .@\"venom.settings\" = .{ .width = \"90%\" }, .mine = .{ .anchor = \"left\" } } } }" });
    var store = try MappedStore.init(a, .{ .io = io, .path = user, .defaults = &.{defaults} });
    defer store.deinit();
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const alloc = arena.allocator();

    const presets = store.current().floats.presets;
    try std.testing.expectEqual(@as(usize, 4), presets.entries.len);
    try std.testing.expectEqualStrings("venom.diff", presets.entries[0].name);
    // builtin width, defaults height: the entry merges field by field.
    try std.testing.expectEqualStrings("100%", presets.entries[0].value.width);
    try std.testing.expectEqualStrings("50%", presets.entries[0].value.height);
    try std.testing.expectEqualStrings("bottom", presets.entries[0].value.anchor);
    const settings = presets.get("venom.settings").?;
    try std.testing.expectEqualStrings("90%", settings.width);
    try std.testing.expectEqualStrings("80%", settings.height);
    try std.testing.expectEqualStrings("venom settings", settings.title.?);
    try std.testing.expectEqual(@as(i32, 2), presets.get("venom-os.launcher").?.y);
    try std.testing.expectEqualStrings("left", presets.get("mine").?.anchor);
    try std.testing.expectEqualStrings("60%", presets.get("mine").?.width);

    // Sources per entry, as `<map>."name"`.
    const found = try store.lookup(alloc, "floats.presets");
    try std.testing.expectEqual(cfg.Source.user, found.source);
    try std.testing.expectEqual(cfg.Source.defaults, sourceOf(found, "floats.presets.\"venom.diff\"").?);
    try std.testing.expectEqual(cfg.Source.user, sourceOf(found, "floats.presets.\"venom.settings\"").?);
    try std.testing.expectEqual(cfg.Source.defaults, sourceOf(found, "floats.presets.\"venom-os.launcher\"").?);
    try std.testing.expectEqual(cfg.Source.user, sourceOf(found, "floats.presets.\"mine\"").?);
    try std.testing.expect(std.mem.indexOf(u8, found.content, ".@\"venom.settings\" = .{") != null);
    // Unquoted (longest known name) and quoted keys address the same entry.
    try std.testing.expectEqualStrings("\"90%\"", try store.get(alloc, "floats.presets.venom.settings.width"));
    try std.testing.expectEqualStrings("\"90%\"", try store.get(alloc, "floats.presets.\"venom.settings\".width"));
    try std.testing.expectEqualStrings("2", try store.get(alloc, "floats.presets.venom-os.launcher.y"));
    try std.testing.expectEqual(cfg.Source.defaults, (try store.lookup(alloc, "floats.presets.venom-os.launcher.y")).source);
    try std.testing.expectError(error.InvalidConfig, store.get(alloc, "floats.presets.nope"));
    try std.testing.expectEqualStrings("floats.presets.nope", store.failure.key());
    try std.testing.expectError(error.InvalidConfig, store.get(alloc, "floats.presets.\"venom.settings"));

    // Schema: additionalProperties is the entry schema; the default is an object.
    const schema = try std.json.parseFromSlice(std.json.Value, a, try store.schema(alloc), .{});
    defer schema.deinit();
    const map = schema.value.object.get("properties").?.object.get("floats").?.object.get("properties").?.object.get("presets").?.object;
    try std.testing.expectEqualStrings("object", map.get("type").?.string);
    try std.testing.expect(map.get("additionalProperties").?.object.get("properties").?.object.get("width") != null);
    try std.testing.expectEqualStrings("100%", map.get("default").?.object.get("venom.diff").?.object.get("width").?.string);

    // An invalid entry in defaults.zon fails with the real entry key and file.
    try tmp.dir.writeFile(io, .{ .sub_path = "defaults.zon", .data = ".{ .floats = .{ .presets = .{ .@\"venom.settings\" = .{ .width = 80 } } } }" });
    try std.testing.expectError(error.InvalidConfig, store.check());
    try std.testing.expectEqualStrings("floats.presets.\"venom.settings\".width", store.failure.key());
    try std.testing.expectEqual(cfg.Source.defaults, store.failure.source.?);
    try tmp.dir.writeFile(io, .{ .sub_path = "defaults.zon", .data = ".{ .floats = .{ .presets = .{ .@\"venom.settings\" = .{ .bogus = 1 } } } }" });
    try std.testing.expectError(error.InvalidConfig, store.check());
    try std.testing.expectEqualStrings("floats.presets.\"venom.settings\".bogus", store.failure.key());
    try tmp.dir.writeFile(io, .{ .sub_path = "defaults.zon", .data = ".{ .floats = .{ .presets = .{ \"not a map\" } } }" });
    try std.testing.expectError(error.InvalidConfig, store.check());
    try std.testing.expectEqualStrings("floats.presets", store.failure.key());
}

test "config set addresses map entries and entry fields with dotted names" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const dir = try path(&tmp);
    defer a.free(dir);
    const user = try std.fmt.allocPrint(a, "{s}/config.zon", .{dir});
    defer a.free(user);
    const defaults = try std.fmt.allocPrint(a, "{s}/defaults.zon", .{dir});
    defer a.free(defaults);
    try tmp.dir.writeFile(io, .{ .sub_path = "defaults.zon", .data = ".{ .floats = .{ .presets = .{ .@\"venom.settings\" = .{ .width = \"80%\", .height = \"80%\", .title = \"venom settings\" } } } }" });
    var store = try MappedStore.init(a, .{ .io = io, .path = user, .defaults = &.{defaults} });
    defer store.deinit();
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const alloc = arena.allocator();

    // The defaults preset stays, one field changes.
    try std.testing.expect((try store.set("floats.presets.venom.settings.width", "\"90%\"")).changed);
    try std.testing.expect(!(try store.set("floats.presets.\"venom.settings\".width", "\"90%\"")).changed);
    _ = try store.reload();
    var settings = store.current().floats.presets.get("venom.settings").?;
    try std.testing.expectEqualStrings("90%", settings.width);
    try std.testing.expectEqualStrings("80%", settings.height);
    try std.testing.expectEqualStrings("venom settings", settings.title.?);
    const written = try tmp.dir.readFileAlloc(io, "config.zon", alloc, .limited(4096));
    try std.testing.expectEqualStrings(".{ .floats = .{ .presets = .{ .@\"venom.settings\" = .{ .width = \"90%\", }, }, }, }", written);
    try std.testing.expectEqual(cfg.Source.user, (try store.lookup(alloc, "floats.presets.venom.settings.width")).source);
    // Builtin entries are not copied into the user file.
    try std.testing.expect(std.mem.indexOf(u8, written, "venom.diff") == null);

    // A new dotted name: unquoted, the whole remainder is the name.
    _ = try store.set("floats.presets.my.tool", ".{ .anchor = \"top\" }");
    // A field of a new entry needs the quoted segment.
    _ = try store.set("floats.presets.\"x.y\".width", "\"5\"");
    // Builtin entries can be changed per field too.
    _ = try store.set("floats.presets.venom.diff.y", "3");
    _ = try store.reload();
    const presets = store.current().floats.presets;
    try std.testing.expectEqualStrings("top", presets.get("my.tool").?.anchor);
    try std.testing.expectEqualStrings("5", presets.get("x.y").?.width);
    try std.testing.expectEqual(@as(i32, 3), presets.get("venom.diff").?.y);
    try std.testing.expectEqualStrings("100%", presets.get("venom.diff").?.width);

    // Setting a whole entry replaces the user's entry; defaults fields still merge in.
    _ = try store.set("floats.presets.venom.settings", ".{ .height = \"50%\" }");
    _ = try store.reload();
    settings = store.current().floats.presets.get("venom.settings").?;
    try std.testing.expectEqualStrings("80%", settings.width);
    try std.testing.expectEqualStrings("50%", settings.height);
    // Setting the map replaces the user's entries only.
    _ = try store.set("floats.presets", ".{ .@\"venom.settings\" = .{ .y = 1 } }");
    _ = try store.reload();
    try std.testing.expectEqual(@as(usize, 2), store.current().floats.presets.entries.len);
    try std.testing.expectEqual(@as(i32, 1), store.current().floats.presets.get("venom.settings").?.y);
    try std.testing.expectEqualStrings("80%", store.current().floats.presets.get("venom.settings").?.height);

    // Invalid keys and values.
    for ([_][]const u8{ "floats.presets.", "floats.presets.\"\"", "floats.presets.\"a", "floats.presets.\"a\"x", "floats.presets.a..b", "floats.presets.\"a\".missing" }) |key| {
        try std.testing.expectError(error.InvalidConfig, store.set(key, "1"));
        try std.testing.expectEqualStrings("invalid_params.config_key", store.failure.code);
    }
    try std.testing.expectError(error.InvalidConfig, store.set("floats.presets.venom.settings.width", "80"));
    try std.testing.expectEqualStrings("invalid_params.config_zon", store.failure.code);
    try std.testing.expectEqualStrings("floats.presets.venom.settings.width", store.failure.key());
    try std.testing.expectError(error.InvalidConfig, store.set("floats.presets.venom.settings", ".{ .width = \"1\", .bogus = 2 }"));
}

// Scoped layers: user < workspace < repo, the narrowest file winning.
const ScopedFiles = struct {
    tmp: std.testing.TmpDir,
    dir: [:0]u8,
    user: []u8,
    defaults: []u8,
    workspace: []u8,
    repo: []u8,
    fn init() !ScopedFiles {
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const dir = try path(&tmp);
        return .{
            .tmp = tmp,
            .dir = dir,
            .user = try std.fmt.allocPrint(a, "{s}/home/config.zon", .{dir}),
            .defaults = try std.fmt.allocPrint(a, "{s}/defaults.zon", .{dir}),
            .workspace = try std.fmt.allocPrint(a, "{s}/ws/.venom/workspace.zon", .{dir}),
            .repo = try std.fmt.allocPrint(a, "{s}/ws/repo/.venom/repo.zon", .{dir}),
        };
    }
    fn deinit(f: *ScopedFiles) void {
        for ([_][]u8{ f.user, f.defaults, f.workspace, f.repo }) |p| a.free(p);
        a.free(f.dir);
        f.tmp.cleanup();
    }
    fn overlays(f: *const ScopedFiles) [2]cfg.Overlay {
        return .{ .{ .name = "workspace", .path = f.workspace }, .{ .name = "repo", .path = f.repo } };
    }
    fn write(f: *ScopedFiles, sub: []const u8, data: []const u8) !void {
        if (std.fs.path.dirname(sub)) |d| try f.tmp.dir.createDirPath(std.testing.io, d);
        try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = sub, .data = data });
    }
    fn read(f: *ScopedFiles, sub: []const u8) ![]u8 {
        return f.tmp.dir.readFileAlloc(std.testing.io, sub, a, .limited(4096));
    }
};
const workspace: cfg.Source = .overlay(0);
const repo: cfg.Source = .overlay(1);

test "overlays merge above the user file in order, the narrowest winning per key" {
    var f = try ScopedFiles.init();
    defer f.deinit();
    try f.write("defaults.zon", ".{ .count = 2, .tables = .{ .{ .name = \"d\", .prefix = \"d\" }, .{ .name = \"shared\", .prefix = \"d\" } } }");
    try f.write("home/config.zon", ".{ .count = 3, .appearance = .{ .theme = \"user\" }, .tables = .{ .{ .name = \"shared\", .prefix = \"u\" }, .{ .name = \"u\" } } }");
    try f.write("ws/.venom/workspace.zon", ".{ .count = 5, .appearance = .{ .theme = \"ws\", .color = false }, .tables = .{ .{ .name = \"shared\", .prefix = \"w\" }, .{ .name = \"w\" } } }");
    try f.write("ws/repo/.venom/repo.zon", ".{ .count = 7, .tables = .{ .{ .name = \"w\", .prefix = \"r\" } } }");
    const overlays = f.overlays();
    var store = try LayeredStore.init(a, .{ .io = std.testing.io, .path = f.user, .defaults = &.{f.defaults}, .overlays = &overlays, .validate = layeredValidate });
    defer store.deinit();
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const alloc = arena.allocator();

    // Scalars: the narrowest file that sets the key wins; structs merge per field.
    const c = store.current();
    try std.testing.expectEqual(@as(u32, 7), c.count);
    try std.testing.expectEqualStrings("ws", c.appearance.theme);
    try std.testing.expect(!c.appearance.color);
    // by_name: entries replace in place through every layer, new names append.
    try std.testing.expectEqual(@as(usize, 4), c.tables.len);
    const names = [_][]const u8{ "d", "shared", "u", "w" };
    const prefixes = [_][]const u8{ "d", "w", "", "r" };
    for (c.tables, names, prefixes) |t, n, p| {
        try std.testing.expectEqualStrings(n, t.name);
        try std.testing.expectEqualStrings(p, t.prefix);
    }

    const all = try store.lookup(alloc, "");
    try std.testing.expectEqual(repo, all.source);
    try std.testing.expectEqual(repo, sourceOf(all, "count").?);
    try std.testing.expectEqual(workspace, sourceOf(all, "appearance.theme").?);
    try std.testing.expectEqual(workspace, sourceOf(all, "appearance.color").?);
    try std.testing.expectEqual(repo, sourceOf(all, "tables").?);
    try std.testing.expectEqual(cfg.Source.builtin, sourceOf(all, "token").?);
    try std.testing.expectEqualStrings("repo", store.sourceName(repo));
    try std.testing.expectEqualStrings(f.workspace, store.sourcePath(workspace).?);
    try std.testing.expectEqualStrings("user", store.sourceName(.user));
    try std.testing.expect(store.sourcePath(.user) == null);

    // A missing overlay is an empty layer; removing one is watched.
    try f.tmp.dir.deleteFile(std.testing.io, "ws/repo/.venom/repo.zon");
    try store.watch(1000);
    try std.testing.expectEqual(@as(u32, 5), store.current().count);
    try std.testing.expectEqual(workspace, (try store.lookup(alloc, "count")).source);
    try f.tmp.dir.deleteTree(std.testing.io, "ws");
    try store.watch(2000);
    try std.testing.expectEqual(@as(u32, 3), store.current().count);
    try std.testing.expectEqual(cfg.Source.user, (try store.lookup(alloc, "count")).source);
}

test "maps merge per entry name through overlays" {
    var f = try ScopedFiles.init();
    defer f.deinit();
    try f.write("home/config.zon", ".{ .floats = .{ .presets = .{ .@\"venom.diff\" = .{ .width = \"90%\" } } } }");
    try f.write("ws/repo/.venom/repo.zon", ".{ .floats = .{ .presets = .{ .@\"venom.diff\" = .{ .anchor = \"top\" }, .repo = .{ .y = 3 } } } }");
    const overlays = f.overlays();
    var store = try MappedStore.init(a, .{ .io = std.testing.io, .path = f.user, .overlays = &overlays });
    defer store.deinit();
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const diff = store.current().floats.presets.get("venom.diff").?;
    try std.testing.expectEqualStrings("90%", diff.width);
    try std.testing.expectEqualStrings("70%", diff.height);
    try std.testing.expectEqualStrings("top", diff.anchor);
    try std.testing.expectEqual(@as(i32, 3), store.current().floats.presets.get("repo").?.y);
    const found = try store.lookup(arena.allocator(), "floats.presets");
    try std.testing.expectEqual(repo, sourceOf(found, "floats.presets.\"venom.diff\"").?);
    try std.testing.expectEqual(repo, sourceOf(found, "floats.presets.\"repo\"").?);
}

test "an invalid overlay fails check, reload and set and names its file" {
    var f = try ScopedFiles.init();
    defer f.deinit();
    const overlays = f.overlays();
    var store = try LayeredStore.init(a, .{ .io = std.testing.io, .path = f.user, .overlays = &overlays, .validate = layeredValidate });
    defer store.deinit();
    const cases = [_]struct { zon: []const u8, code: []const u8, key: []const u8 }{
        .{ .zon = ".{ .broken = ", .code = "invalid_params.config_zon", .key = "" },
        .{ .zon = ".{ .count = \"six\" }", .code = "invalid_params.config_zon", .key = "count" },
        .{ .zon = ".{ .appearance = .{ .missing = 1 } }", .code = "invalid_params.config_zon", .key = "appearance.missing" },
        .{ .zon = ".{ .token = \"plaintext\" }", .code = "invalid_params.config_secret", .key = "token" },
        .{ .zon = ".{ .tables = .{ .{ .name = \"a\" }, .{ .name = \"a\" } } }", .code = "invalid_params.config_value", .key = "tables" },
    };
    for (cases) |case| {
        try f.write("ws/repo/.venom/repo.zon", case.zon);
        try std.testing.expectError(error.InvalidConfig, store.check());
        try std.testing.expectEqualStrings(case.code, store.failure.code);
        try std.testing.expectEqualStrings(case.key, store.failure.key());
        try std.testing.expectEqual(repo, store.failure.source.?);
        try std.testing.expectError(error.InvalidConfig, store.reload());
        try std.testing.expectError(error.InvalidConfig, store.set("count", "9"));
    }
    try std.testing.expectEqual(@as(u32, 4), store.current().count);
    // The same error one layer down is attributed to the workspace file.
    try f.write("ws/repo/.venom/repo.zon", ".{}");
    try f.write("ws/.venom/workspace.zon", ".{ .count = \"six\" }");
    try std.testing.expectError(error.InvalidConfig, store.check());
    try std.testing.expectEqual(workspace, store.failure.source.?);
    // Semantic validation of the effective config names no file.
    try f.write("ws/.venom/workspace.zon", ".{ .count = 0 }");
    try std.testing.expectError(error.InvalidConfig, store.check());
    try std.testing.expect(store.failure.source == null);
    // An overlay path that is a directory is an I/O failure of that overlay.
    try f.tmp.dir.deleteFile(std.testing.io, "ws/.venom/workspace.zon");
    try f.tmp.dir.createDirPath(std.testing.io, "ws/.venom/workspace.zon");
    try std.testing.expectError(error.InvalidConfig, store.check());
    try std.testing.expectEqualStrings("failed.config_io", store.failure.code);
    try std.testing.expectEqual(workspace, store.failure.source.?);
}

test "config set writes the file the product picks; overlays are validated at init" {
    var f = try ScopedFiles.init();
    defer f.deinit();
    try f.write("home/config.zon", ".{ .count = 3 }");
    const overlays = f.overlays();
    var store = try LayeredStore.init(a, .{ .io = std.testing.io, .path = f.user, .overlays = &overlays, .write = repo, .validate = layeredValidate });
    defer store.deinit();
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    // `set` writes Options.write and creates the missing overlay file.
    try std.testing.expect((try store.set("count", "8")).changed);
    _ = try store.reload();
    try std.testing.expectEqual(@as(u32, 8), store.current().count);
    try std.testing.expectEqual(repo, (try store.lookup(alloc, "count")).source);
    const repo_bytes = try f.read("ws/repo/.venom/repo.zon");
    defer a.free(repo_bytes);
    try std.testing.expect(std.mem.indexOf(u8, repo_bytes, ".count = 8") != null);
    const user_bytes = try f.read("home/config.zon");
    defer a.free(user_bytes);
    try std.testing.expectEqualStrings(".{ .count = 3 }", user_bytes);
    // setIn picks the file per call; a lower layer's value stays shadowed.
    try std.testing.expect((try store.setIn(workspace, "appearance.theme", "\"ws\"")).changed);
    try std.testing.expect((try store.setIn(.user, "count", "5")).changed);
    _ = try store.reload();
    try std.testing.expectEqual(@as(u32, 8), store.current().count);
    try std.testing.expectEqualStrings("ws", store.current().appearance.theme);
    try std.testing.expectError(error.InvalidConfigPath, store.setIn(.defaults, "count", "1"));
    try std.testing.expectError(error.InvalidConfigPath, store.setIn(.overlay(2), "count", "1"));
    // The effective config must validate, whichever file is written: a
    // shadowed workspace value is accepted, the same value in repo is not.
    _ = try store.setIn(workspace, "count", "0");
    try std.testing.expectError(error.InvalidConfig, store.set("count", "0"));
    try std.testing.expectEqualStrings("count", store.failure.key());

    const bad = [_][]const cfg.Overlay{
        &.{.{ .name = "user", .path = f.repo }},
        &.{.{ .name = "Repo", .path = f.repo }},
        &.{.{ .name = "", .path = f.repo }},
        &.{.{ .name = "repo", .path = "relative/repo.zon" }},
        &.{ .{ .name = "repo", .path = f.repo }, .{ .name = "repo", .path = f.workspace } },
    };
    for (bad) |o| try std.testing.expectError(error.InvalidConfigPath, LayeredStore.init(a, .{ .io = std.testing.io, .path = f.user, .overlays = o }));
    try std.testing.expectError(error.InvalidConfigPath, LayeredStore.init(a, .{ .io = std.testing.io, .path = f.user, .write = .overlay(0) }));
    try std.testing.expectError(error.InvalidConfigPath, LayeredStore.init(a, .{ .io = std.testing.io, .path = f.user, .overlays = &overlays, .write = .defaults }));
}

fn callVerb(store: *LayeredStore, request: []const u8) !@import("proto").Response {
    const model: @import("proto").schema.Schema = .{ .tool = "cfg-test", .summary = "Config", .verbs = &cfg.verbs };
    return callModel(&model, store, request);
}
fn callModel(model: *const @import("proto").schema.Schema, store: *LayeredStore, request: []const u8) !@import("proto").Response {
    const proto = @import("proto");
    const bindings = store.bindings();
    var dispatcher = try proto.Dispatcher.init(a, model, &bindings, .{}, null);
    defer dispatcher.deinit();
    var registry = try proto.grants.Registry.init(a, "cfg-test", .{});
    defer registry.deinit();
    var fds: [2]std.c.fd_t = undefined;
    if (std.c.socketpair(std.c.AF.UNIX, std.c.SOCK.STREAM, 0, &fds) != 0) return error.SystemResources;
    defer proto.os.close(fds[1]);
    var conn = proto.Connection.init(a, fds[0]);
    defer conn.deinit();
    conn.protocol = .ndjson;
    conn.ready = true;
    conn.version = 1;
    conn.registry = &registry;
    conn.identity = .{ .principal = proto.grants.owner };
    try dispatcher.message(&conn, .{ .ndjson = request });
    return proto.Response.parse(a, std.mem.trim(u8, conn.output.items, "\n"));
}

test "config get --json reports the overlay each value came from; errors name the file" {
    var f = try ScopedFiles.init();
    defer f.deinit();
    try f.write("home/config.zon", ".{ .appearance = .{ .color = false } }");
    try f.write("ws/.venom/workspace.zon", ".{ .appearance = .{ .theme = \"ws\" } }");
    try f.write("ws/repo/.venom/repo.zon", ".{ .count = 6 }");
    const overlays = f.overlays();
    var store = try LayeredStore.init(a, .{ .io = std.testing.io, .path = f.user, .overlays = &overlays, .validate = layeredValidate });
    defer store.deinit();

    var response = try callVerb(&store, "{\"id\":1,\"verb\":\"config.get\",\"params\":{\"key\":\"appearance\"}}");
    defer response.deinit();
    try std.testing.expect(response.body == .ok);
    const result = response.body.ok.object;
    try std.testing.expectEqualStrings("workspace", result.get("source").?.string);
    try std.testing.expectEqualStrings(f.workspace, result.get("path").?.string);
    const sources = result.get("sources").?.array.items;
    try std.testing.expectEqual(@as(usize, 2), sources.len);
    for (sources) |e| {
        const o = e.object;
        if (std.mem.eql(u8, o.get("key").?.string, "appearance.theme")) {
            try std.testing.expectEqualStrings("workspace", o.get("source").?.string);
            try std.testing.expectEqualStrings(f.workspace, o.get("path").?.string);
        } else {
            try std.testing.expectEqualStrings("appearance.color", o.get("key").?.string);
            try std.testing.expectEqualStrings("user", o.get("source").?.string);
            try std.testing.expect(o.get("path") == null);
        }
    }
    var count = try callVerb(&store, "{\"id\":2,\"verb\":\"config.get\",\"params\":{\"key\":\"count\"}}");
    defer count.deinit();
    try std.testing.expectEqualStrings("repo", count.body.ok.object.get("source").?.string);
    try std.testing.expectEqualStrings(f.repo, count.body.ok.object.get("path").?.string);

    try f.write("ws/repo/.venom/repo.zon", ".{ .count = \"six\" }");
    var check = try callVerb(&store, "{\"id\":3,\"verb\":\"config.check\"}");
    defer check.deinit();
    try std.testing.expect(check.body == .@"error");
    const data = check.body.@"error".data.?.object;
    try std.testing.expectEqualStrings("invalid_params.config_zon", check.body.@"error".code);
    try std.testing.expectEqualStrings("count", data.get("key").?.string);
    try std.testing.expectEqualStrings("repo", data.get("source").?.string);
    try std.testing.expectEqualStrings(f.repo, data.get("path").?.string);
}

// Product-declared validation codes and per-file validation.
const product_errors = [_]cfg.ErrorCode{.{ .code = "invalid_params.key_conflict", .summary = "Two bindings in one config file share a key prefix" }};
const product_model = cfg.mergeWith(.{ .tool = "cfg-test", .summary = "Config", .verbs = &.{} }, .{ .errors = &product_errors });
/// Within one file, two tables may not share a prefix.
fn layerConflicts(c: Layered, source: cfg.Source) ?cfg.Validation {
    _ = source;
    for (c.tables, 0..) |t, i| for (c.tables[0..i]) |prev| {
        if (t.prefix.len > 0 and std.mem.eql(u8, t.prefix, prev.prefix)) return .{ .key = "tables", .code = "invalid_params.key_conflict" };
    };
    return null;
}
fn expectConflict(response: @import("proto").Response, source: []const u8, file: ?[]const u8) !void {
    try std.testing.expect(response.body == .@"error");
    try std.testing.expectEqualStrings("invalid_params.key_conflict", response.body.@"error".code);
    const data = response.body.@"error".data.?.object;
    try std.testing.expectEqualStrings("tables", data.get("key").?.string);
    try std.testing.expectEqualStrings(source, data.get("source").?.string);
    if (file) |f| try std.testing.expectEqualStrings(f, data.get("path").?.string) else try std.testing.expect(data.get("path") == null);
}

test "mergeWith declares product validation codes on the validating config verbs only" {
    const plain = cfg.merge(.{ .tool = "cfg-test", .summary = "Config", .verbs = &.{} });
    const same = cfg.mergeWith(.{ .tool = "cfg-test", .summary = "Config", .verbs = &.{} }, .{});
    for (plain.verbs, same.verbs) |p, q| try std.testing.expectEqual(p.errors.len, q.errors.len);
    try @import("proto").schema.check(&product_model, null);
    for (product_model.verbs, plain.verbs) |v, p| {
        const declared = for (v.errors) |e| {
            if (std.mem.eql(u8, e.code, "invalid_params.key_conflict")) break e;
        } else null;
        if (std.mem.eql(u8, v.name, "config.schema")) {
            try std.testing.expect(declared == null);
            try std.testing.expectEqual(p.errors.len, v.errors.len);
        } else {
            try std.testing.expectEqual(p.errors.len + 1, v.errors.len);
            // Same data as the shared config errors.
            try std.testing.expectEqual(p.errors[2].data.?.fields.?.len, declared.?.data.?.fields.?.len);
        }
    }
}

test "validate_layer reports declared codes per file from check, set and reload" {
    var f = try ScopedFiles.init();
    defer f.deinit();
    // The same prefix in different files is shadowing, not a conflict.
    try f.write("defaults.zon", ".{ .tables = .{ .{ .name = \"os\", .prefix = \"x\" } } }");
    try f.write("home/config.zon", ".{ .tables = .{ .{ .name = \"mine\", .prefix = \"x\" } } }");
    const overlays = f.overlays();
    var store = try LayeredStore.init(a, .{ .io = std.testing.io, .path = f.user, .defaults = &.{f.defaults}, .overlays = &overlays, .validate = layeredValidate, .validate_layer = layerConflicts });
    defer store.deinit();
    try store.check();

    // Two tables of the user file: check fails, naming the user file.
    try f.write("home/config.zon", ".{ .tables = .{ .{ .name = \"mine\", .prefix = \"x\" }, .{ .name = \"other\", .prefix = \"x\" } } }");
    var check = try callModel(&product_model, &store, "{\"id\":1,\"verb\":\"config.check\"}");
    defer check.deinit();
    try expectConflict(check, "user", null);
    var reload = try callModel(&product_model, &store, "{\"id\":2,\"verb\":\"config.reload\"}");
    defer reload.deinit();
    try expectConflict(reload, "user", null);
    try std.testing.expectEqual(@as(usize, 2), store.current().tables.len);

    // A conflicting defaults file is reported on defaults.
    try f.write("home/config.zon", ".{}");
    try f.write("defaults.zon", ".{ .tables = .{ .{ .name = \"os\", .prefix = \"x\" }, .{ .name = \"os2\", .prefix = \"x\" } } }");
    var defaults = try callModel(&product_model, &store, "{\"id\":3,\"verb\":\"config.check\"}");
    defer defaults.deinit();
    try expectConflict(defaults, "defaults", null);
    try f.write("defaults.zon", ".{ .tables = .{ .{ .name = \"os\", .prefix = \"x\" } } }");

    // An overlay conflict names the overlay and its file.
    try f.write("ws/.venom/workspace.zon", ".{ .tables = .{ .{ .name = \"w1\", .prefix = \"w\" }, .{ .name = \"w2\", .prefix = \"w\" } } }");
    var overlay = try callModel(&product_model, &store, "{\"id\":4,\"verb\":\"config.check\"}");
    defer overlay.deinit();
    try expectConflict(overlay, "workspace", f.workspace);
    try f.write("ws/.venom/workspace.zon", ".{}");

    // config set sees the candidate file and leaves it unwritten.
    try f.write("home/config.zon", ".{ .tables = .{ .{ .name = \"mine\", .prefix = \"x\" } } }");
    var set = try callModel(&product_model, &store, "{\"id\":5,\"verb\":\"config.set\",\"params\":{\"key\":\"tables\",\"value\":\".{ .{ .name = \\\"a\\\", .prefix = \\\"p\\\" }, .{ .name = \\\"b\\\", .prefix = \\\"p\\\" } }\"}}");
    defer set.deinit();
    try expectConflict(set, "user", null);
    try std.testing.expectEqualStrings("value", set.body.@"error".data.?.object.get("param").?.string);
    const kept = try f.read("home/config.zon");
    defer a.free(kept);
    try std.testing.expect(std.mem.indexOf(u8, kept, "\"p\"") == null);
    try store.check();
    _ = try store.set("tables", ".{ .{ .name = \"a\", .prefix = \"p\" }, .{ .name = \"b\", .prefix = \"q\" } }");
    _ = try store.reload();
    // defaults "os" plus the user's two tables.
    try std.testing.expectEqual(@as(usize, 3), store.current().tables.len);
}

fn effectiveCode(c: Layered) ?cfg.Validation {
    if (c.count == 7) return .{ .key = "count", .code = "invalid_params.key_conflict", .source = .user };
    // Not an invalid_params code: reported as config_value.
    if (c.count == 8) return .{ .key = "count", .code = "failed.config_io" };
    if (c.count == 9) return .{ .key = "count", .code = "invalid_params.Bad" };
    return null;
}

test "validate may return a declared code and source; other codes stay config_value" {
    var f = try ScopedFiles.init();
    defer f.deinit();
    try f.write("home/config.zon", ".{}");
    var store = try LayeredStore.init(a, .{ .io = std.testing.io, .path = f.user, .validate = effectiveCode });
    defer store.deinit();
    try std.testing.expectError(error.InvalidConfig, store.set("count", "7"));
    try std.testing.expectEqualStrings("invalid_params.key_conflict", store.failure.code);
    try std.testing.expectEqual(cfg.Source.user, store.failure.source.?);
    try std.testing.expectEqualStrings("count", store.failure.key());
    for ([_][]const u8{ "8", "9" }) |n| {
        try std.testing.expectError(error.InvalidConfig, store.set("count", n));
        try std.testing.expectEqualStrings("invalid_params.config_value", store.failure.code);
        try std.testing.expect(store.failure.source == null);
    }
    try f.write("home/config.zon", ".{ .count = 7 }");
    var check = try callModel(&product_model, &store, "{\"id\":1,\"verb\":\"config.check\"}");
    defer check.deinit();
    try std.testing.expectEqualStrings("invalid_params.key_conflict", check.body.@"error".code);
    try std.testing.expectEqualStrings("user", check.body.@"error".data.?.object.get("source").?.string);
}

const FileFixture = struct {
    tmp: std.testing.TmpDir,
    dir: [:0]u8,
    p: []u8,
    fn init(self: *FileFixture, name: []const u8) !void {
        self.tmp = std.testing.tmpDir(.{});
        self.dir = try path(&self.tmp);
        self.p = try std.fmt.allocPrint(a, "{s}/{s}", .{ self.dir, name });
    }
    fn deinit(self: *FileFixture) void {
        a.free(self.p);
        a.free(self.dir);
        self.tmp.cleanup();
    }
    /// `set` on a store over the fixture's file, then the file's bytes.
    fn set(self: *FileFixture, arena: std.mem.Allocator, file: []const u8, key: []const u8, value: []const u8) ![]const u8 {
        var store = try Store.init(a, .{ .io = std.testing.io, .path = self.p, .validate = validate });
        defer store.deinit();
        _ = try store.set(key, value);
        // The text means what `set` was asked for.
        var fresh = try Store.init(a, .{ .io = std.testing.io, .path = self.p, .validate = validate });
        defer fresh.deinit();
        try std.testing.expectEqualStrings(value, try fresh.get(arena, key));
        return self.tmp.dir.readFileAlloc(std.testing.io, file, arena, .limited(4096));
    }
};

test "set edits the key in place: comments and formatting stay" {
    var f: FileFixture = undefined;
    try f.init("config.zon");
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    const start =
        \\// My settings.
        \\.{
        \\    // How many.
        \\    .count = 4, // four is plenty
        \\
        \\    .appearance = .{
        \\        .theme = "dark", // easy on the eyes
        \\    },
        \\}
        \\
    ;
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.zon", .data = start });

    // A value in place.
    var text = try f.set(alloc, "config.zon", "count", "9");
    try std.testing.expectEqualStrings(try std.mem.replaceOwned(u8, alloc, start, ".count = 4,", ".count = 9,"), text);
    // Nested.
    text = try f.set(alloc, "config.zon", "appearance.theme", "\"light\"");
    try std.testing.expect(std.mem.indexOf(u8, text, ".theme = \"light\", // easy on the eyes") != null);
    // A new field goes last in its table, on its own line.
    text = try f.set(alloc, "config.zon", "appearance.color", "false");
    try std.testing.expect(std.mem.indexOf(u8, text, "// easy on the eyes\n        .color = false,\n    },") != null);
    text = try f.set(alloc, "config.zon", "port", "81");
    try std.testing.expectEqualStrings(
        \\// My settings.
        \\.{
        \\    // How many.
        \\    .count = 9, // four is plenty
        \\
        \\    .appearance = .{
        \\        .theme = "light", // easy on the eyes
        \\        .color = false,
        \\    },
        \\    .port = 81,
        \\}
        \\
    , text);
}

test "set inserts into tables on one line, without a trailing comma, and builds missing tables" {
    var f: FileFixture = undefined;
    try f.init("config.zon");
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.zon", .data = ".{ .count = 4 } // one line\n" });
    try std.testing.expectEqualStrings(".{ .count = 4, .port = 81 } // one line\n", try f.set(alloc, "config.zon", "port", "81"));
    try std.testing.expectEqualStrings(".{ .count = 4, .port = 81, .appearance = .{ .color = false } } // one line\n", try f.set(alloc, "config.zon", "appearance.color", "false"));
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.zon", .data = ".{\n    .count = 4\n    // the end\n}\n" });
    try std.testing.expectEqualStrings(".{\n    .count = 4,\n    // the end\n    .port = 81,\n}\n", try f.set(alloc, "config.zon", "port", "81"));
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.zon", .data = "// nothing yet\n.{}\n" });
    try std.testing.expectEqualStrings("// nothing yet\n.{ .port = 81 }\n", try f.set(alloc, "config.zon", "port", "81"));
    // A value that is a table, replaced whole; and a list.
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.zon", .data = ".{\n    .names = .{ \"a\", \"b\" }, // two\n}\n" });
    try std.testing.expectEqualStrings(".{\n    .names = .{\"c\"}, // two\n}\n", try f.set(alloc, "config.zon", "names", ".{\"c\"}"));
}

test "set writes through a symlink to its target, in the target's directory" {
    var f: FileFixture = undefined;
    try f.init("config.zon");
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    const io = std.testing.io;
    try f.tmp.dir.createDirPath(io, "dotfiles");
    try f.tmp.dir.writeFile(io, .{ .sub_path = "dotfiles/venom.zon", .data = ".{\n    .count = 4,\n}\n" });
    try f.tmp.dir.symLink(io, "dotfiles/venom.zon", "config.zon", .{});
    _ = try f.set(alloc, "dotfiles/venom.zon", "count", "9");
    var buffer: [std.fs.max_path_bytes]u8 = undefined;
    const n = try f.tmp.dir.readLink(io, "config.zon", &buffer);
    try std.testing.expectEqualStrings("dotfiles/venom.zon", buffer[0..n]);
    try std.testing.expectEqualStrings(".{\n    .count = 9,\n}\n", try f.tmp.dir.readFileAlloc(io, "dotfiles/venom.zon", alloc, .limited(4096)));

    // A dangling link: the target is created, and the link stays.
    try f.tmp.dir.deleteFile(io, "config.zon");
    try f.tmp.dir.symLink(io, "dotfiles/new.zon", "config.zon", .{});
    _ = try f.set(alloc, "dotfiles/new.zon", "count", "7");
    try std.testing.expectEqual(n - "venom.zon".len + "new.zon".len, try f.tmp.dir.readLink(io, "config.zon", &buffer));
}

test "set keeps an existing file's mode; a new file is 0600" {
    var f: FileFixture = undefined;
    try f.init("config.zon");
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    const io = std.testing.io;
    _ = try f.set(alloc, "config.zon", "count", "5");
    try std.testing.expectEqual(@as(u32, 0o600), @as(u32, @intCast((try f.tmp.dir.statFile(io, "config.zon", .{})).permissions.toMode() & 0o777)));
    for ([_]u32{ 0o640, 0o666 }) |mode| {
        try f.tmp.dir.setFilePermissions(io, "config.zon", .fromMode(mode), .{});
        _ = try f.set(alloc, "config.zon", "count", if (mode == 0o640) "6" else "7");
        try std.testing.expectEqual(mode, @as(u32, @intCast((try f.tmp.dir.statFile(io, "config.zon", .{})).permissions.toMode() & 0o777)));
    }
}

test "a value's comment is not written: it cannot swallow what follows it" {
    var f: FileFixture = undefined;
    try f.init("config.zon");
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const alloc = arena.allocator();
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.zon", .data = "// mine\n.{\n    .count = 4, // why not\n}\n" });
    var store = try Store.init(a, .{ .io = std.testing.io, .path = f.p, .validate = validate });
    defer store.deinit();
    _ = try store.set("count", "5 // why");
    try std.testing.expectEqualStrings("// mine\n.{\n    .count = 5, // why not\n}\n", try f.tmp.dir.readFileAlloc(std.testing.io, "config.zon", alloc, .limited(4096)));
    _ = try store.set("port", "// first\n81 // why");
    try std.testing.expectEqualStrings("// mine\n.{\n    .count = 5, // why not\n    .port = 81,\n}\n", try f.tmp.dir.readFileAlloc(std.testing.io, "config.zon", alloc, .limited(4096)));
}

test "a field spelled with an escape is the same field: edited in place" {
    var f: FileFixture = undefined;
    try f.init("config.zon");
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.zon", .data = "// mine\n.{ .@\"\\x63ount\" = 4 }\n" });
    try std.testing.expectEqualStrings("// mine\n.{ .@\"\\x63ount\" = 9 }\n", try f.set(arena.allocator(), "config.zon", "count", "9"));
}

test "an edit that can't be proven correct is refused and the file stays byte for byte" {
    var f: FileFixture = undefined;
    try f.init("config.zon");
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const start = "// mine\n.{ .appearance = .{ .theme = \"a\", .color = true } }\n";
    try f.tmp.dir.writeFile(std.testing.io, .{ .sub_path = "config.zon", .data = start });
    var store = try Store.init(a, .{ .io = std.testing.io, .path = f.p, .validate = validate });
    defer store.deinit();
    // A multi-line string runs to the end of its line: the rest would go.
    try std.testing.expectError(error.InvalidConfig, store.set("appearance.theme", "\\\\b"));
    try std.testing.expectEqualStrings("failed.config_edit", store.failure.code);
    try std.testing.expectEqualStrings("appearance.theme", store.failure.key());
    try std.testing.expectEqualStrings(start, try f.tmp.dir.readFileAlloc(std.testing.io, "config.zon", arena.allocator(), .limited(4096)));
}

test "a read-only file is refused, not replaced" {
    var f: FileFixture = undefined;
    try f.init("config.zon");
    defer f.deinit();
    var arena: std.heap.ArenaAllocator = .init(a);
    defer arena.deinit();
    const io = std.testing.io;
    const start = ".{\n    .count = 4,\n}\n";
    try f.tmp.dir.writeFile(io, .{ .sub_path = "config.zon", .data = start });
    try f.tmp.dir.setFilePermissions(io, "config.zon", .fromMode(0o444), .{});
    var store = try Store.init(a, .{ .io = io, .path = f.p, .validate = validate });
    defer store.deinit();
    try std.testing.expectError(error.InvalidConfig, store.set("count", "9"));
    try std.testing.expectEqualStrings("failed.config_io", store.failure.code);
    try std.testing.expectEqualStrings(start, try f.tmp.dir.readFileAlloc(io, "config.zon", arena.allocator(), .limited(4096)));
    try std.testing.expectEqual(@as(u32, 0o444), @as(u32, @intCast((try f.tmp.dir.statFile(io, "config.zon", .{})).permissions.toMode() & 0o777)));
}

// Scope params on config get|set, and failure detail from init.
const scope_field: @import("proto").schema.Type = .{ .kind = .string };
const scope_options: cfg.MergeOptions = .{
    .errors = &product_errors,
    .scope_params = &.{
        .{ .name = "workspace", .summary = "Workspace path", .type = scope_field },
        .{ .name = "repo", .summary = "Repo path", .type = scope_field },
    },
    .scope_errors = &.{.{ .code = "not_found.workspace", .summary = "Unknown workspace", .data = .{ .kind = .object, .fields = &.{.{ .name = "path", .summary = "Path", .type = scope_field }} } }},
};
const scope_model = cfg.mergeWith(.{ .tool = "cfg-test", .summary = "Config", .verbs = &.{} }, scope_options);

test "mergeWith adds scope params and errors to config get and set only" {
    const proto = @import("proto");
    try proto.schema.check(&scope_model, null);
    for (product_model.verbs, scope_model.verbs) |plain, v| {
        const get_or_set = std.mem.eql(u8, v.name, "config.get") or std.mem.eql(u8, v.name, "config.set");
        try std.testing.expectEqual(plain.errors.len + @as(usize, if (get_or_set) 1 else 0), v.errors.len);
        try std.testing.expectEqual(plain.params.len + @as(usize, if (get_or_set) 2 else 0), v.params.len);
        if (!get_or_set) continue;
        // After the shared params and errors, so their order stays stable.
        for (plain.params, v.params[0..plain.params.len]) |p, q| try std.testing.expectEqualStrings(p.name, q.name);
        try std.testing.expectEqualStrings("workspace", v.params[plain.params.len].name);
        try std.testing.expectEqualStrings("repo", v.params[plain.params.len + 1].name);
        try std.testing.expect(!v.params[plain.params.len].required);
        for (plain.errors, v.errors[0..plain.errors.len]) |p, q| try std.testing.expectEqualStrings(p.code, q.code);
        try std.testing.expectEqualStrings("not_found.workspace", v.errors[plain.errors.len].code);
    }
}

test "mergeWith with scope params builds the schema a post-merge rewrite built" {
    const proto = @import("proto");
    const rewritten = comptime blk: {
        const base = cfg.merge(.{ .tool = "cfg-test", .summary = "Config", .verbs = &.{} });
        var out = base.verbs[0..base.verbs.len].*;
        for (&out) |*v| if (std.mem.eql(u8, v.name, "config.get") or std.mem.eql(u8, v.name, "config.set")) {
            const p = v.params[0..v.params.len].* ++ scope_options.scope_params[0..2].*;
            const e = v.errors[0..v.errors.len].* ++ scope_options.scope_errors[0..1].*;
            v.params = &p;
            v.errors = &e;
        };
        const final = out;
        break :blk proto.schema.Schema{ .format = base.format, .tool = base.tool, .summary = base.summary, .verbs = &final };
    };
    const direct = comptime cfg.mergeWith(.{ .tool = "cfg-test", .summary = "Config", .verbs = &.{} }, .{ .scope_params = scope_options.scope_params, .scope_errors = scope_options.scope_errors });
    try std.testing.expectEqualDeep(rewritten, direct);
}

test "initReporting names the code, key and file of a failed init" {
    var f = try ScopedFiles.init();
    defer f.deinit();
    const overlays = f.overlays();
    const options: LayeredStore.Options = .{ .io = std.testing.io, .path = f.user, .defaults = &.{f.defaults}, .overlays = &overlays, .validate = layeredValidate };
    const expectFailure = struct {
        fn run(opts: LayeredStore.Options, code: []const u8, key: []const u8, source: ?cfg.Source) !void {
            var failure: cfg.Failure = .{};
            try std.testing.expectError(error.InvalidConfig, LayeredStore.initReporting(a, opts, &failure));
            try std.testing.expectEqualStrings(code, failure.code);
            try std.testing.expectEqualStrings(key, failure.key());
            try std.testing.expectEqual(source, failure.source);
        }
    }.run;
    // A malformed or mistyped file names itself, at any layer.
    try f.write("ws/repo/.venom/repo.zon", "not zon");
    try expectFailure(options, "invalid_params.config_zon", "", repo);
    try f.write("ws/repo/.venom/repo.zon", ".{ .count = \"six\" }");
    try expectFailure(options, "invalid_params.config_zon", "count", repo);
    try f.write("ws/repo/.venom/repo.zon", ".{}");
    try f.write("ws/.venom/workspace.zon", ".{ .count = \"six\" }");
    try expectFailure(options, "invalid_params.config_zon", "count", workspace);
    try f.write("ws/.venom/workspace.zon", ".{}");
    try f.write("home/config.zon", "not zon");
    try expectFailure(options, "invalid_params.config_zon", "", .user);
    try f.write("home/config.zon", ".{}");
    try f.write("defaults.zon", "not zon");
    try expectFailure(options, "invalid_params.config_zon", "", .defaults);
    try f.write("defaults.zon", ".{}");

    // A validator's failure goes to the narrowest file setting that key.
    try f.write("home/config.zon", ".{ .count = 0 }");
    try expectFailure(options, "invalid_params.config_value", "count", .user);
    try f.write("ws/.venom/workspace.zon", ".{ .count = 0 }");
    try expectFailure(options, "invalid_params.config_value", "count", workspace);
    try f.write("home/config.zon", ".{}");
    // A narrower file that sets some other key is not blamed.
    try f.write("ws/repo/.venom/repo.zon", ".{ .appearance = .{ .theme = \"dark\" } }");
    try expectFailure(options, "invalid_params.config_value", "count", workspace);

    // An unreadable overlay.
    try f.tmp.dir.deleteFile(std.testing.io, "ws/repo/.venom/repo.zon");
    try f.tmp.dir.createDirPath(std.testing.io, "ws/repo/.venom/repo.zon");
    try expectFailure(options, "failed.config_io", "", repo);

    // No store exists to ask, so the options name the source.
    try std.testing.expectEqualStrings("workspace", options.sourceName(workspace));
    try std.testing.expectEqualStrings(f.repo, options.sourcePath(repo).?);
    try std.testing.expectEqualStrings("user", options.sourceName(.user));
    try std.testing.expect(options.sourcePath(.user) == null);
}

test "initReporting leaves the failure alone on success and on other errors" {
    var f = try ScopedFiles.init();
    defer f.deinit();
    var failure: cfg.Failure = .{ .code = "untouched" };
    var store = try LayeredStore.initReporting(a, .{ .io = std.testing.io, .path = f.user }, &failure);
    store.deinit();
    try std.testing.expectEqualStrings("untouched", failure.code);
    try std.testing.expectError(error.InvalidConfigPath, LayeredStore.initReporting(a, .{ .io = std.testing.io, .path = "relative" }, &failure));
    try std.testing.expectEqualStrings("untouched", failure.code);
}

test "a validator's own source wins, and a key no file sets has none" {
    var f = try ScopedFiles.init();
    defer f.deinit();
    const overlays = f.overlays();
    const Validators = struct {
        fn own(_: Layered) ?cfg.Validation {
            return .{ .key = "count", .source = .defaults };
        }
        fn unset(_: Layered) ?cfg.Validation {
            return .{ .key = "appearance.theme" };
        }
        fn root(_: Layered) ?cfg.Validation {
            return .{ .key = "" };
        }
    };
    try f.write("home/config.zon", ".{ .count = 2 }");
    var failure: cfg.Failure = .{};
    try std.testing.expectError(error.InvalidConfig, LayeredStore.initReporting(a, .{ .io = std.testing.io, .path = f.user, .overlays = &overlays, .validate = Validators.own }, &failure));
    try std.testing.expectEqual(cfg.Source.defaults, failure.source.?);
    try std.testing.expectError(error.InvalidConfig, LayeredStore.initReporting(a, .{ .io = std.testing.io, .path = f.user, .overlays = &overlays, .validate = Validators.unset }, &failure));
    try std.testing.expect(failure.source == null);
    try std.testing.expectError(error.InvalidConfig, LayeredStore.initReporting(a, .{ .io = std.testing.io, .path = f.user, .overlays = &overlays, .validate = Validators.root }, &failure));
    try std.testing.expect(failure.source == null);
}
