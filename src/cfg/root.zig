//! Typed data-only ZON configuration.
//! All operations belong to the daemon reactor. The owner calls watch() from
//! its bounded poll loop; there are no background threads or implicit reloads.
const std = @import("std");
const proto = @import("proto");
pub const verbs = @import("verbs.zig").verbs;
pub const merge = @import("verbs.zig").merge;
pub const mergeWith = @import("verbs.zig").mergeWith;
pub const MergeOptions = @import("verbs.zig").MergeOptions;
pub const ErrorCode = @import("verbs.zig").ErrorCode;
/// `by_name` marks a map-like key: a slice of structs
/// with a `name: []const u8` field. Layers merge it per entry name instead of
/// replacing it; `config set` of the key itself still replaces the user list.
///
/// The other optional fields annotate the key in `config schema` for agents and
/// settings screens. They only describe: `config set` and `check` enforce the
/// types, and the product's validator must enforce what `pattern`, `format` and
/// the bounds promise. `description` fits any key. `pattern` (an ECMA-262
/// regular expression) and `format` fit string keys, `minimum` and `maximum`
/// (inclusive, and inside what the type holds) fit numeric keys. On an optional
/// or a list they apply to the value or to each element.
pub const FieldPolicy = struct {
    key: []const u8,
    secret: bool = false,
    restart: bool = false,
    by_name: bool = false,
    description: ?[]const u8 = null,
    pattern: ?[]const u8 = null,
    format: ?[]const u8 = null,
    minimum: ?f64 = null,
    maximum: ?f64 = null,
    fn annotates(p: FieldPolicy) bool {
        return p.description != null or p.pattern != null or p.format != null or p.minimum != null or p.maximum != null;
    }
    /// Annotations alone say nothing about the secret and restart flags: on a
    /// table they would contradict a child's.
    fn hasFlags(p: FieldPolicy) bool {
        return p.secret or p.restart or p.by_name or !p.annotates();
    }
};
/// A map-shaped key written as a struct literal with arbitrary entry names
/// such as `.presets = .{ .@"venom.settings" = .{ ... } }`.
/// Layers merge it per entry name; within one name, struct values merge
/// field by field like any struct key. Keys address an entry as
/// `presets."venom.settings"` or, unquoted, by the longest known entry name
/// (`presets.venom.settings.width`). Maps must be reached through struct
/// fields only, not through slices or optionals.
pub fn Map(comptime V: type) type {
    return struct {
        pub const cfg_map_value = V;
        pub const Entry = struct { name: []const u8, value: V };
        /// In file order; builtin entries first, then new names per layer.
        entries: []const Entry = &.{},
        pub fn get(self: @This(), name: []const u8) ?V {
            for (self.entries) |e| if (std.mem.eql(u8, e.name, name)) return e.value;
            return null;
        }
        pub fn jsonStringify(self: @This(), jw: anytype) !void {
            try jw.beginObject();
            for (self.entries) |e| {
                try jw.objectField(e.name);
                try jw.write(e.value);
            }
            try jw.endObject();
        }
    };
}
fn isMap(comptime V: type) bool {
    return @typeInfo(V) == .@"struct" and @hasDecl(V, "cfg_map_value");
}
/// Entry names: non-empty, no `"` (the key quote) and no control bytes.
fn validName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name) |c| if (c == '"' or c < 0x20 or c == 0x7f) return false;
    return true;
}
const NameSegment = struct { name: []const u8, rest: []const u8 };
/// Splits `"name"` or `"name".rest` off a key.
fn splitName(key: []const u8) ?NameSegment {
    if (key.len < 2 or key[0] != '"') return null;
    const close = std.mem.indexOfScalarPos(u8, key, 1, '"') orelse return null;
    const after = key[close + 1 ..];
    if (after.len == 0) return .{ .name = key[1..close], .rest = "" };
    if (after[0] != '.' or after.len == 1) return null;
    return .{ .name = key[1..close], .rest = after[1..] };
}
/// Next segment of a canonical key (map entry names quoted).
fn nextSegment(key: []const u8, pos: *usize) ?[]const u8 {
    if (pos.* >= key.len) return null;
    const rest = key[pos.*..];
    if (rest[0] == '"') {
        const close = std.mem.indexOfScalarPos(u8, rest, 1, '"').?;
        pos.* += close + 2;
        return rest[1..close];
    }
    const dot = std.mem.indexOfScalar(u8, rest, '.') orelse rest.len;
    pos.* += dot + 1;
    return rest[0..dot];
}
/// The expression in a `config set` value, without comments around it: a
/// value's trailing comment must not swallow what follows it in the file.
/// Null when it is not one expression.
fn valueExpression(a: std.mem.Allocator, value: []const u8) !?[]const u8 {
    const src = try a.dupeSentinel(u8, value, 0);
    const ast = try std.zig.Ast.parse(a, src, .{ .mode = .zon });
    if (ast.errors.len != 0) return null;
    const node = ast.nodeData(.root).node;
    const last = ast.lastToken(node);
    return value[ast.tokenStart(ast.firstToken(node)) .. ast.tokenStart(last) + ast.tokenSlice(last).len];
}
/// `bytes` with the value at `key` replaced, or its field inserted, and
/// everything else byte for byte: comments and formatting stay. Null when the
/// text has no place for it (`key` runs into a value that is not a table, or
/// the text does not parse). The caller checks the result means what it should.
fn editText(a: std.mem.Allocator, bytes: []const u8, key: []const u8, value: []const u8) !?[]const u8 {
    const src = try a.dupeSentinel(u8, bytes, 0);
    const ast = try std.zig.Ast.parse(a, src, .{ .mode = .zon });
    if (ast.errors.len != 0) return null;
    var node = ast.nodeData(.root).node;
    var pos: usize = 0;
    while (nextSegment(key, &pos)) |part| {
        var buf: [2]std.zig.Ast.Node.Index = undefined;
        const table = ast.fullStructInit(&buf, node) orelse return null;
        const field = for (table.ast.fields) |f| {
            const name = ast.tokenSlice(ast.firstToken(f) - 2);
            const plain = if (std.mem.startsWith(u8, name, "@\"")) std.zig.string_literal.parseAlloc(a, name[1..]) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return null,
            } else name;
            if (std.mem.eql(u8, plain, part)) break f;
        } else {
            // Not there: the field, with any tables still missing above the value.
            var text: std.Io.Writer.Allocating = .init(a);
            var depth: usize = 0;
            var next: ?[]const u8 = part;
            while (next) |p| : (next = nextSegment(key, &pos)) {
                try text.writer.print("{s}.{f} = ", .{ if (depth > 0) ".{ " else "", std.zig.fmtId(p) });
                depth += 1;
            }
            try text.writer.writeAll(value);
            for (1..depth) |_| try text.writer.writeAll(" }");
            return try insertField(a, &ast, table.ast.lbrace, ast.lastToken(node), table.ast.fields.len > 0, text.written());
        };
        node = field;
    }
    const first = ast.firstToken(node);
    const last = ast.lastToken(node);
    const end = ast.tokenStart(last) + ast.tokenSlice(last).len;
    return try std.mem.concat(a, u8, &.{ src[0..ast.tokenStart(first)], value, src[end..] });
}
/// Inserts `.name = value` last in the table between two braces: on a line of
/// its own when its closing brace has one, else on the brace's line.
fn insertField(a: std.mem.Allocator, ast: *const std.zig.Ast, lbrace: std.zig.Ast.TokenIndex, rbrace: std.zig.Ast.TokenIndex, has_fields: bool, field: []const u8) ![]const u8 {
    const src = ast.source;
    const close = ast.tokenStart(rbrace);
    const prev = rbrace - 1;
    const prev_end = ast.tokenStart(prev) + ast.tokenSlice(prev).len;
    const comma: []const u8 = if (has_fields and ast.tokenTag(prev) != .comma) "," else "";
    const line = if (std.mem.lastIndexOfScalar(u8, src[0..close], '\n')) |nl| nl + 1 else 0;
    const indent = src[line..close];
    const own_line = !ast.tokensOnSameLine(lbrace, rbrace) and std.mem.trim(u8, indent, " \t").len == 0;
    if (own_line) return std.mem.concat(a, u8, &.{ src[0..prev_end], comma, src[prev_end..line], indent, "    ", field, ",\n", src[line..] });
    return std.mem.concat(a, u8, &.{ src[0..prev_end], comma, " ", field, " ", src[close..] });
}
/// The file a write to `path` must replace: its symlinks followed, so the
/// link stays and its target changes, even when the target does not exist yet.
fn followLinks(a: std.mem.Allocator, io: std.Io, path: []const u8) ![]const u8 {
    var current = path;
    for (0..40) |_| {
        var buffer: [std.fs.max_path_bytes]u8 = undefined;
        const n = std.Io.Dir.cwd().readLink(io, current, &buffer) catch |err| switch (err) {
            error.NotLink, error.FileNotFound => return current,
            else => return err,
        };
        const target = buffer[0..n];
        current = if (std.fs.path.isAbsolute(target)) try a.dupe(u8, target) else try std.fs.path.join(a, &.{ std.fs.path.dirname(current) orelse ".", target });
    }
    return error.SymLinkLoop;
}
fn checkMaps(comptime V: type, comptime nested: bool) void {
    if (isMap(V)) {
        if (nested) @compileError("cfg: Map keys must be reached through struct fields only");
        return checkMaps(V.cfg_map_value, false);
    }
    switch (@typeInfo(V)) {
        .@"struct" => for (fields(V)) |f| checkMaps(f.type, nested),
        .pointer => |p| if (p.size == .slice and p.child != u8) checkMaps(p.child, true),
        .optional => |o| checkMaps(o.child, true),
        else => {},
    }
}
fn hasMap(comptime V: type) bool {
    if (isMap(V)) return true;
    if (@typeInfo(V) != .@"struct") return false;
    for (fields(V)) |f| if (hasMap(f.type)) return true;
    return false;
}
/// Where an effective value comes from: the product's Zig defaults, the
/// read-only `defaults.zon` layer, the user's `config.zon`, or one of the
/// store's scoped overlay files (`Source.overlay(i)`, see `Overlay`). Layers
/// rank in that order, overlays by index; a higher layer wins per key.
/// Overlay values have no tag name: report them with `Store.sourceName`.
pub const Source = enum(u8) {
    builtin,
    defaults,
    user,
    _,
    pub fn overlay(index: usize) Source {
        std.debug.assert(index < max_overlays);
        return @fromBackingInt(@intCast(3 + index));
    }
    pub fn overlayIndex(self: Source) ?usize {
        const v = @backingInt(self);
        return if (v >= 3) v - 3 else null;
    }
};
/// A scoped config file above the user layer (workspace, then repo). The product resolves the paths; the store merges the overlays
/// in order, the last (narrowest) one winning per key, with the same per-key,
/// `by_name` and Map rules and type checks as the other layers. A missing
/// file is an empty layer. `name` is what `config get` and errors report as
/// the source: 1 to 32 bytes of `a-z`, `0-9`, `-` or `_`, unique, and not
/// `builtin`, `defaults` or `user`.
pub const Overlay = struct { name: []const u8, path: []const u8 };
pub const max_overlays = 16;
fn validOverlayName(name: []const u8) bool {
    if (name.len == 0 or name.len > 32) return false;
    for (name) |c| if (!std.ascii.isLower(c) and !std.ascii.isDigit(c) and c != '-' and c != '_') return false;
    for ([_][]const u8{ "builtin", "defaults", "user" }) |r| if (std.mem.eql(u8, name, r)) return false;
    return true;
}
pub const SourceEntry = struct { key: []const u8, source: Source };
/// `config get`: redacted ZON plus the source of the key and of every leaf
/// value under it (by-name keys count as one leaf).
pub const Lookup = struct { content: []const u8, source: Source, sources: []const SourceEntry };
/// A failed product validation. `code` is reported instead of
/// `invalid_params.config_value`; it must be an `invalid_params.*` code the
/// product declared with `mergeWith` (a static string), otherwise
/// `config_value` is reported. `source` names the failing file in the error
/// data; `validate_layer` failures default to the layer being checked.
pub const Validation = struct {
    key: []const u8,
    code: []const u8 = "invalid_params.config_value",
    source: ?Source = null,
};
pub const Change = struct { changed: bool, restart_required: bool };
/// Fixed-size, content-free diagnostics, safe for config errors and doctor.
/// partial means effects may have occurred, including an unsynced deletion.
/// No paths, terminal text, credentials or raw OS errors cross this boundary.
pub const ActivationFailure = struct {
    reason: enum { io, unsafe_store, limit, other },
    partial: bool = false,
};
/// `secrets.Store` implements this interface: `cfg.SecretStore.init(&store)`.
/// put returns a non-secret stable reference (`secret:<name>`, grammar in
/// `secrets.reference`) owned by the supplied arena.
/// ZON stores references only; products resolve them through their secret store.
/// put must create an immutable entry, never overwrite a live reference. A
/// later config failure may leave an unreferenced entry for backend GC. The
/// encrypted backend is not implemented yet; absence of an adapter rejects plaintext.
pub const SecretStore = struct {
    ptr: *anyopaque,
    vtable: *const VTable,
    pub const VTable = struct { put: *const fn (*anyopaque, std.mem.Allocator, []const u8, []const u8) anyerror![]const u8 };
    pub fn init(impl: anytype) SecretStore {
        const Impl = @typeInfo(@TypeOf(impl)).pointer.child;
        @import("iface").assertImplements(VTable, Impl);
        return .{ .ptr = impl, .vtable = &struct {
            const vt: VTable = .{ .put = put };
            fn put(ptr: *anyopaque, a: std.mem.Allocator, key: []const u8, secret: []const u8) anyerror![]const u8 {
                return @import("iface").cast(Impl, ptr).put(a, key, secret);
            }
        }.vt };
    }
};
pub const Failure = struct {
    code: []const u8 = "invalid_params.config_value",
    storage: [256]u8 = @splat(0),
    length: usize = 0,
    /// The file that failed, when one did (`defaults`, `user` or an overlay).
    source: ?Source = null,
    pub fn key(self: *const Failure) []const u8 {
        return self.storage[0..self.length];
    }
};
pub fn configPath(a: std.mem.Allocator, tool: []const u8, env: std.process.Environ) ![]u8 {
    if (!proto.schema.validToolName(tool)) return error.InvalidTool;
    const base = env.getPosix("XDG_CONFIG_HOME");
    if (base) |b| if (b.len > 0) {
        if (!std.fs.path.isAbsolute(b)) return error.InvalidConfigPath;
        return std.fmt.allocPrint(a, "{s}/{s}/config.zon", .{ b, tool });
    };
    const home = env.getPosix("HOME") orelse return error.InvalidConfigPath;
    if (!std.fs.path.isAbsolute(home)) return error.InvalidConfigPath;
    return std.fmt.allocPrint(a, "{s}/.config/{s}/config.zon", .{ home, tool });
}

/// Candidate read-only defaults files, highest priority first:
/// `<dir>/<tool>/defaults.zon` for each absolute `$XDG_CONFIG_DIRS` entry,
/// `/etc/xdg` when the variable is unset or empty. The store reads the first
/// one that exists. Free with `freePaths`.
pub fn defaultsPaths(a: std.mem.Allocator, tool: []const u8, env: std.process.Environ) ![][]u8 {
    if (!proto.schema.validToolName(tool)) return error.InvalidTool;
    const dirs = env.getPosix("XDG_CONFIG_DIRS") orelse "";
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |item| a.free(item);
        list.deinit(a);
    }
    var it = std.mem.splitScalar(u8, if (dirs.len == 0) "/etc/xdg" else dirs, ':');
    while (it.next()) |dir| {
        if (dir.len == 0 or !std.fs.path.isAbsolute(dir)) continue;
        const trimmed = std.mem.trimEnd(u8, dir, "/");
        try list.ensureUnusedCapacity(a, 1);
        list.appendAssumeCapacity(try std.fmt.allocPrint(a, "{s}/{s}/defaults.zon", .{ trimmed, tool }));
    }
    return list.toOwnedSlice(a);
}
pub fn freePaths(a: std.mem.Allocator, paths: []const []u8) void {
    for (paths) |item| a.free(item);
    a.free(paths);
}

pub fn Store(comptime T: type, comptime policies: []const FieldPolicy) type {
    comptime {
        @setEvalBranchQuota(100_000);
        checkMaps(T, false);
        for (policies, 0..) |p, i| {
            if (p.key.len == 0 or p.key.len > 255) @compileError("cfg: invalid policy key");
            const FT = keyType(T, p.key);
            if (p.secret and FT != []const u8) @compileError("cfg: secret fields must be []const u8 references");
            if (p.by_name) {
                const ok = @typeInfo(FT) == .pointer and @typeInfo(FT).pointer.size == .slice and @typeInfo(@typeInfo(FT).pointer.child) == .@"struct" and @hasField(@typeInfo(FT).pointer.child, "name") and @FieldType(@typeInfo(FT).pointer.child, "name") == []const u8;
                if (!ok) @compileError("cfg: by_name keys must be slices of structs with a `name: []const u8` field");
                if (p.secret) @compileError("cfg: by_name keys cannot be secret");
            }
            checkAnnotations(p, FT);
            for (policies[0..i]) |q| if (std.mem.eql(u8, p.key, q.key)) @compileError("cfg: duplicate field policy");
        }
    }
    return struct {
        const Self = @This();
        const Snapshot = struct {
            arena: std.heap.ArenaAllocator,
            value: T,
            hash: u64 = 0,
            sources: []const SourceEntry = &.{},
            fn deinit(self: *Snapshot) void {
                self.arena.deinit();
            }
        };
        /// Synchronous reactor effect, called once per activation (including an
        /// explicit no-op reload for retry). Not called by init, set or check.
        /// The implementation must bound work/I/O by its product limits and
        /// deadline, and report limit on exhaustion. No background continuation.
        /// All product allocations/validation must precede irreversible effects.
        /// On null, enforcement is complete and durable; activation cannot fail.
        /// On failure, active config stays intact; effects are never rolled back.
        /// impl must outlive the store. Values are borrowed only during apply;
        /// do not retain/mutate them or reenter the store/event log, yield the
        /// reactor, or publish events (a log append is already prepared).
        /// Startup retention is the product's responsibility before readiness.
        pub const PreActivate = struct {
            ptr: *anyopaque,
            vtable: *const VTable,
            pub const VTable = struct { apply: *const fn (*anyopaque, T, T) ?ActivationFailure };
            pub fn init(impl: anytype) PreActivate {
                const Impl = @typeInfo(@TypeOf(impl)).pointer.child;
                @import("iface").assertImplements(VTable, Impl);
                return .{ .ptr = impl, .vtable = &struct {
                    const vt: VTable = .{ .apply = apply };
                    fn apply(ptr: *anyopaque, previous: T, candidate: T) ?ActivationFailure {
                        return @import("iface").cast(Impl, ptr).apply(previous, candidate);
                    }
                }.vt };
            }
        };
        pub const Options = struct {
            io: std.Io,
            /// The user's config.zon; `config set` writes this file unless
            /// `write` names an overlay.
            path: []const u8,
            /// Read-only defaults candidates (see `defaultsPaths`); the first
            /// existing file is the layer below `path`. Copied by init.
            defaults: []const []const u8 = &.{},
            /// Scoped files above `path`, broadest first (see `Overlay`), at
            /// most `max_overlays`. Copied by init.
            overlays: []const Overlay = &.{},
            /// The file the `config.set` verb (and `set`) writes: `.user` or
            /// `Source.overlay(i)`. `setIn` takes it per call instead.
            write: Source = .user,
            /// Checks the effective (merged) value.
            validate: ?*const fn (T) ?Validation = null,
            /// Checks one config file at a time (same-layer
            /// conflicts), with the value that file would give if it were the
            /// only one (over builtin Zig defaults), and its source: defaults
            /// when present, user, then each present overlay. Runs wherever the
            /// layers are merged (init, get, set, check, reload, watch), before
            /// `validate`; for `config set` it sees the candidate file. Every
            /// field of T needs a default unless each file sets it. Values are
            /// borrowed for the call only.
            validate_layer: ?*const fn (T, Source) ?Validation = null,
            pre_activate: ?PreActivate = null,
            secrets: ?SecretStore = null,
            events: ?*proto.events.Log = null,
            max_bytes: usize = 1024 * 1024,

            /// What config errors report for `source`: its tag name, or the
            /// overlay's name. For a failed `initReporting`, where there is no
            /// store to ask.
            pub fn sourceName(self: *const Options, source: Source) []const u8 {
                return switch (source) {
                    .builtin => "builtin",
                    .defaults => "defaults",
                    .user => "user",
                    _ => self.overlays[source.overlayIndex().?].name,
                };
            }
            /// The file of an overlay source; null for the other layers (the
            /// user file is `path`).
            pub fn sourcePath(self: *const Options, source: Source) ?[]const u8 {
                const i = source.overlayIndex() orelse return null;
                return self.overlays[i].path;
            }
        };
        gpa: std.mem.Allocator,
        options: Options,
        path: []u8,
        active: Snapshot,
        failure: Failure = .{},
        /// Last effect failure, retained across set/check/validation failures for
        /// doctor. Cleared only after a successful activation attempt.
        activation_failure: ?ActivationFailure = null,
        observed: u64 = 0,
        next_watch_ms: i64 = 0,
        restart_required: bool = false,

        pub fn init(gpa: std.mem.Allocator, options: Options) !Self {
            var failure: Failure = .{};
            return initReporting(gpa, options, &failure);
        }
        /// `init` that says why it failed: on error.InvalidConfig, `failure`
        /// holds the code, key and failing file (name it with
        /// `Options.sourceName` and `sourcePath`). It is left alone on any
        /// other error. A validator's failure on the merged config, which names
        /// no file by itself, is attributed to the narrowest file that sets the
        /// failing key; it has no source when no file does.
        pub fn initReporting(gpa: std.mem.Allocator, options: Options, failure: *Failure) !Self {
            if (!std.fs.path.isAbsolute(options.path) or options.max_bytes == 0) return error.InvalidConfigPath;
            for (options.defaults) |d| if (!std.fs.path.isAbsolute(d)) return error.InvalidConfigPath;
            if (options.overlays.len > max_overlays) return error.InvalidConfigPath;
            for (options.overlays, 0..) |o, i| {
                if (!std.fs.path.isAbsolute(o.path) or !validOverlayName(o.name)) return error.InvalidConfigPath;
                for (options.overlays[0..i]) |q| if (std.mem.eql(u8, o.name, q.name)) return error.InvalidConfigPath;
            }
            if (!validTarget(options.write, options.overlays.len)) return error.InvalidConfigPath;
            var self: Self = .{ .gpa = gpa, .options = options, .path = try gpa.dupe(u8, options.path), .active = undefined };
            errdefer gpa.free(self.path);
            const overlays = try gpa.alloc(Overlay, options.overlays.len);
            var copied_overlays: usize = 0;
            errdefer {
                for (overlays[0..copied_overlays]) |o| {
                    gpa.free(o.name);
                    gpa.free(o.path);
                }
                gpa.free(overlays);
            }
            for (options.overlays, overlays) |o, *out| {
                const name = try gpa.dupe(u8, o.name);
                errdefer gpa.free(name);
                out.* = .{ .name = name, .path = try gpa.dupe(u8, o.path) };
                copied_overlays += 1;
            }
            self.options.overlays = overlays;
            const defaults = try gpa.alloc([]const u8, options.defaults.len);
            var copied: usize = 0;
            errdefer {
                for (defaults[0..copied]) |d| gpa.free(d);
                gpa.free(defaults);
            }
            for (options.defaults, defaults) |d, *out| {
                out.* = try gpa.dupe(u8, d);
                copied += 1;
            }
            self.options.defaults = defaults;
            self.active = self.loadAttributed() catch |err| {
                if (err == error.InvalidConfig) failure.* = self.failure;
                return err;
            };
            self.observed = self.active.hash;
            return self;
        }
        pub fn deinit(self: *Self) void {
            self.active.deinit();
            self.gpa.free(self.path);
            for (self.options.defaults) |d| self.gpa.free(d);
            self.gpa.free(self.options.defaults);
            for (self.options.overlays) |o| {
                self.gpa.free(o.name);
                self.gpa.free(o.path);
            }
            self.gpa.free(self.options.overlays);
            self.* = undefined;
        }
        fn validTarget(target: Source, overlays: usize) bool {
            if (target == .user) return true;
            const i = target.overlayIndex() orelse return false;
            return i < overlays;
        }
        /// What `config get` and config errors report for `source`: its tag
        /// name, or the overlay's name.
        pub fn sourceName(self: *const Self, source: Source) []const u8 {
            return self.options.sourceName(source);
        }
        /// The file of an overlay source; null for the other layers.
        pub fn sourcePath(self: *const Self, source: Source) ?[]const u8 {
            return self.options.sourcePath(source);
        }
        /// Borrowed until a successful reload, watch or deinit.
        pub fn current(self: *const Self) T {
            return self.active.value;
        }
        fn fail(self: *Self, code: []const u8, key: []const u8) error{InvalidConfig} {
            return self.failIn(code, key, null);
        }
        fn failIn(self: *Self, code: []const u8, key: []const u8, source: ?Source) error{InvalidConfig} {
            self.failure = .{ .code = code, .source = source };
            self.failure.length = @min(key.len, self.failure.storage.len);
            @memcpy(self.failure.storage[0..self.failure.length], key[0..self.failure.length]);
            return error.InvalidConfig;
        }
        /// File bytes of every layer; null when the file does not exist.
        const Raw = struct {
            defaults: ?[]const u8,
            user: []const u8,
            overlays: []const ?[]const u8,
            fn hash(raw: Raw) u64 {
                var h: std.hash.Wyhash = .init(0);
                hashFile(&h, raw.defaults);
                hashFile(&h, raw.user);
                for (raw.overlays) |o| hashFile(&h, o);
                return h.final();
            }
            fn hashFile(h: *std.hash.Wyhash, bytes: ?[]const u8) void {
                if (bytes) |d| {
                    h.update(std.mem.asBytes(&d.len));
                    h.update(d);
                } else h.update("-");
            }
        };
        fn readFile(self: *Self, a: std.mem.Allocator, path: []const u8, source: Source) !?[]const u8 {
            return std.Io.Dir.cwd().readFileAlloc(self.options.io, path, a, .limited(self.options.max_bytes)) catch |err| switch (err) {
                error.FileNotFound => null,
                error.NotDir => if (source == .user) self.failIn("failed.config_io", "", source) else null,
                error.OutOfMemory => return err,
                else => return self.failIn("failed.config_io", "", source),
            };
        }
        fn read(self: *Self, a: std.mem.Allocator) !Raw {
            const user = try self.readFile(a, self.path, .user) orelse ".{}";
            const overlays = try a.alloc(?[]const u8, self.options.overlays.len);
            for (self.options.overlays, overlays, 0..) |o, *out, i| out.* = try self.readFile(a, o.path, .overlay(i));
            for (self.options.defaults) |p| {
                const bytes = try self.readFile(a, p, .defaults) orelse continue;
                return .{ .defaults = bytes, .user = user, .overlays = overlays };
            }
            return .{ .defaults = null, .user = user, .overlays = overlays };
        }
        fn parse(self: *Self, comptime V: type, a: std.mem.Allocator, bytes: []const u8, key: []const u8) !V {
            const src = try a.dupeSentinel(u8, bytes, 0);
            var diagnostics: std.zon.parse.Diagnostics = undefined;
            return std.zon.parse.fromSlice(V, .{ .gpa = self.gpa, .arena = a, .source = src, .diagnostics = &diagnostics }) catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => return self.fail("invalid_params.config_zon", key),
            };
        }
        fn load(self: *Self) !Snapshot {
            var snap = try self.loadParsed();
            errdefer snap.deinit();
            try self.validate(snap.value);
            return snap;
        }
        fn loadAttributed(self: *Self) !Snapshot {
            var snap = try self.loadParsed();
            errdefer snap.deinit();
            self.validate(snap.value) catch |err| {
                if (err == error.InvalidConfig and self.failure.source == null) self.failure.source = narrowestFile(snap.sources, self.failure.key());
                return err;
            };
            return snap;
        }
        fn loadParsed(self: *Self) !Snapshot {
            var snap: Snapshot = .{ .arena = .init(self.gpa), .value = undefined };
            errdefer snap.deinit();
            var scratch: std.heap.ArenaAllocator = .init(self.gpa);
            defer scratch.deinit();
            const raw = try self.read(scratch.allocator());
            snap.hash = raw.hash();
            try self.compose(&snap, scratch.allocator(), raw);
            return snap;
        }
        const max_layers = 2 + max_overlays;
        /// Effective value: builtin Zig defaults < defaults.zon < config.zon
        /// < overlays in order.
        fn compose(self: *Self, snap: *Snapshot, s: std.mem.Allocator, raw: Raw) !void {
            var layers: [max_layers]Layer = undefined;
            var refs: [max_layers]Ref = undefined;
            var n: usize = 0;
            if (raw.defaults) |d| {
                layers[n] = try self.parseLayer(s, .file, .defaults, d);
                n += 1;
            }
            layers[n] = try self.parseLayer(s, .file, .user, raw.user);
            n += 1;
            for (raw.overlays, 0..) |o, i| if (o) |bytes| {
                layers[n] = try self.parseLayer(s, .file, .overlay(i), bytes);
                n += 1;
            };
            for (refs[0..n], layers[0..n]) |*r, *l| r.* = .{ .layer = l, .node = .root };
            var sources: std.ArrayList(SourceEntry) = .empty;
            const text = try self.mergeText(s, refs[0..n], null, &sources, .internal);
            const a = snap.arena.allocator();
            snap.value = try self.parse(T, a, text, "");
            if (self.options.validate_layer) |check_layer| for (layers[0..n], refs[0..n]) |*l, r| {
                const own = try self.mergeText(s, &.{r}, null, null, .internal);
                const value = self.parse(T, s, own, "") catch |err| return if (err == error.InvalidConfig) self.failIn(self.failure.code, "", l.layer) else err;
                if (check_layer(value, l.layer)) |v| return self.failValidation(v, l.layer);
            };
            // Map entry keys are built in the scratch arena; copy them.
            for (sources.items) |*e| e.key = try a.dupe(u8, e.key);
            snap.sources = try a.dupe(SourceEntry, sources.items);
        }

        // Layer merge. Each file is parsed to Zoir and
        // walked against T at comptime: struct fields merge recursively,
        // by_name keys merge per entry name, other values are replaced by the
        // higher layer. Every value of every layer is type-checked, so an
        // invalid defaults file fails like an invalid user file, with the
        // failing key and file. The result is canonical ZON text.
        const Layer = struct {
            /// builtin: a Map field's Zig default entries, the lowest layer;
            /// file: a config file; input: a `config set` value.
            tag: enum { builtin, file, input },
            /// The reported source; for input, the file `config set` writes.
            layer: Source,
            source: [:0]const u8,
            ast: std.zig.Ast,
            zoir: std.zig.Zoir,
            fn reported(self: *const Layer) Source {
                return self.layer;
            }
            fn file(self: *const Layer) ?Source {
                return if (self.tag == .builtin) null else self.layer;
            }
        };
        const Ref = struct {
            layer: *const Layer,
            node: std.zig.Zoir.Node.Index,
            fn get(r: Ref) std.zig.Zoir.Node {
                return r.node.get(&r.layer.zoir);
            }
            fn span(r: Ref) []const u8 {
                const tree = &r.layer.ast;
                const node = r.node.getAstNode(&r.layer.zoir);
                const last = tree.lastToken(node);
                return r.layer.source[tree.tokenStart(tree.firstToken(node)) .. tree.tokenStart(last) + tree.tokenSlice(last).len];
            }
            fn field(r: Ref, name: []const u8) ?Ref {
                return switch (r.get()) {
                    .struct_literal => |lit| for (lit.names, 0..) |n, i| {
                        if (std.mem.eql(u8, n.get(&r.layer.zoir), name)) break .{ .layer = r.layer, .node = lit.vals.at(@intCast(i)) };
                    } else null,
                    else => null,
                };
            }
        };
        /// Layer memory lives in the scratch arena `s`; nothing to free.
        fn parseLayer(self: *Self, s: std.mem.Allocator, tag: @FieldType(Layer, "tag"), layer: Source, bytes: []const u8) !Layer {
            const source: ?Source = if (tag == .file) layer else null;
            const src = try s.dupeSentinel(u8, bytes, 0);
            const ast = try std.zig.Ast.parse(s, src, .{ .mode = .zon });
            if (ast.errors.len != 0) return self.failIn("invalid_params.config_zon", "", source);
            const zoir = try std.zig.ZonGen.generate(s, ast, .{});
            if (zoir.hasCompileErrors()) return self.failIn("invalid_params.config_zon", "", source);
            return .{ .tag = tag, .layer = layer, .source = src, .ast = ast, .zoir = zoir };
        }
        const Merge = struct {
            store: *Self,
            s: std.mem.Allocator,
            w: *std.Io.Writer,
            /// `config set`: at this key only the highest layer counts.
            replace: ?[]const u8,
            /// The `config set` key as given to set, for error data.
            report: ?[]const u8,
            sources: ?*std.ArrayList(SourceEntry),
            /// Off while `config set` rewrites the user file, so set can
            /// repair a plaintext secret; the effective config is checked.
            secrets: bool = true,
            /// file: Map keys as struct literals (the user file); internal:
            /// the `.entries` form `std.zon.parse` reads into `Map(V)`.
            form: Form,
            /// Inside a Map entry, comptime paths use `*` for the entry name;
            /// `from` (`<map>.*`) maps back to the real `<map>."name"`.
            alias: ?struct { from: []const u8, to: []const u8 } = null,
            const Form = enum { file, internal };
            fn realKey(m: *Merge, key: []const u8) []const u8 {
                const alias = m.alias orelse return key;
                if (!std.mem.startsWith(u8, key, alias.from) or (key.len > alias.from.len and key[alias.from.len] != '.')) return key;
                return std.fmt.allocPrint(m.s, "{s}{s}", .{ alias.to, key[alias.from.len..] }) catch key;
            }
            fn failAt(m: *Merge, r: Ref, code: []const u8, key: []const u8) error{InvalidConfig} {
                // Errors in a `config set` value are reported on the set key.
                if (r.layer.tag == .input) return m.store.fail(code, m.report.?);
                return m.store.failIn(code, m.realKey(key), r.layer.file());
            }
            fn record(m: *Merge, key: []const u8, source: Source) !void {
                if (m.sources) |list| try list.append(m.s, .{ .key = key, .source = source });
            }
            fn leaf(m: *Merge, comptime V: type, comptime path: []const u8, r: Ref) !V {
                const src = try m.s.dupeSentinel(u8, r.span(), 0);
                var diagnostics: std.zon.parse.Diagnostics = undefined;
                const v = std.zon.parse.fromSlice(V, .{ .gpa = m.store.gpa, .arena = m.s, .source = src, .diagnostics = &diagnostics }) catch |err| switch (err) {
                    error.OutOfMemory => return err,
                    else => return m.failAt(r, "invalid_params.config_zon", path),
                };
                if (comptime secretPath(path)) if (m.secrets and v.len != 0 and !validReference(v)) return m.failAt(r, "invalid_params.config_secret", path);
                return v;
            }
            fn value(m: *Merge, comptime V: type, comptime path: []const u8, all: []const Ref) anyerror!void {
                var refs = all;
                if (m.replace) |key| if (std.mem.eql(u8, key, path)) {
                    refs = all[all.len - 1 ..];
                };
                if (comptime byName(path)) return m.named(V, path, refs);
                if (comptime isMap(V)) return m.mapped(V, path, all, null);
                if (comptime @typeInfo(V) != .@"struct") {
                    var top: V = undefined;
                    for (refs) |r| top = try m.leaf(V, path, r);
                    try std.zon.stringify.serialize(top, .{ .whitespace = false }, m.w);
                    return m.record(path, refs[refs.len - 1].layer.reported());
                }
                for (refs) |r| switch (r.get()) {
                    .empty_literal => {},
                    .struct_literal => |lit| for (lit.names) |n| {
                        const name = n.get(&r.layer.zoir);
                        inline for (comptime fields(V)) |f| {
                            if (std.mem.eql(u8, name, f.name)) break;
                        } else return m.failAt(r, "invalid_params.config_zon", try std.fmt.allocPrint(m.s, "{s}{s}{s}", .{ path, if (path.len == 0) "" else ".", name }));
                    },
                    else => return m.failAt(r, "invalid_params.config_zon", path),
                };
                try m.w.writeAll(".{");
                inline for (comptime fields(V)) |f| {
                    // builtin (Map entries only) < defaults < user < overlays.
                    var child: [max_layers + 1]Ref = undefined;
                    var n: usize = 0;
                    for (refs) |r| if (r.field(f.name)) |c| {
                        child[n] = c;
                        n += 1;
                    };
                    if (n > 0) {
                        try m.w.print(" .{f} = ", .{std.zig.fmtId(f.name)});
                        if (comptime isMap(f.type)) {
                            const builtin: ?*const f.type = if (f.default_value_ptr) |p| @ptrCast(@alignCast(p)) else null;
                            try m.mapped(f.type, join(path, f.name), child[0..n], builtin);
                        } else try m.value(f.type, join(path, f.name), child[0..n]);
                        try m.w.writeAll(",");
                    }
                }
                try m.w.writeAll(" }");
            }
            /// Per-name merge: a higher layer's entry replaces the same-named
            /// entry in place; new names are appended. Duplicate names within
            /// one file are invalid.
            fn named(m: *Merge, comptime V: type, comptime path: []const u8, refs: []const Ref) !void {
                const E = @typeInfo(V).pointer.child;
                const Entry = struct { value: E, source: Source };
                var entries: std.ArrayList(Entry) = .empty;
                for (refs) |r| {
                    const range = switch (r.get()) {
                        .empty_literal => continue,
                        .array_literal => |x| x,
                        else => return m.failAt(r, "invalid_params.config_zon", path),
                    };
                    const first = entries.items.len;
                    for (0..range.len) |i| {
                        const entry: Entry = .{ .value = try m.leaf(E, path, .{ .layer = r.layer, .node = range.at(@intCast(i)) }), .source = r.layer.reported() };
                        for (entries.items[first..]) |e| if (std.mem.eql(u8, e.value.name, entry.value.name)) return m.failAt(r, "invalid_params.config_value", path);
                        for (entries.items[0..first]) |*e| {
                            if (std.mem.eql(u8, e.value.name, entry.value.name)) {
                                e.* = entry;
                                break;
                            }
                        } else try entries.append(m.s, entry);
                    }
                }
                var source: Source = refs[refs.len - 1].layer.reported();
                if (entries.items.len > 0) {
                    source = .builtin;
                    for (entries.items) |e| if (@backingInt(e.source) > @backingInt(source)) {
                        source = e.source;
                    };
                }
                try m.w.writeAll(".{");
                for (entries.items) |e| {
                    try m.w.writeAll(" ");
                    try std.zon.stringify.serialize(e.value, .{ .whitespace = false }, m.w);
                    try m.w.writeAll(",");
                }
                try m.w.writeAll(" }");
                return m.record(path, source);
            }
            /// Map merge: entries merge per name across layers (builtin Zig
            /// default entries < defaults < user < overlays); within one name the value
            /// merges like any value of its type (struct fields one by one).
            /// New names keep first-seen order.
            fn mapped(m: *Merge, comptime V: type, comptime path: []const u8, all: []const Ref, builtin: ?*const V) !void {
                const E = V.cfg_map_value;
                const entry_path = comptime join(path, "*");
                var refs = all;
                // Builtin entries seed only the effective config, never the user file.
                var seed = if (m.form == .internal) builtin else null;
                if (m.replace) |key| if (std.mem.eql(u8, key, path)) {
                    refs = all[all.len - 1 ..];
                    seed = null;
                };
                var layers: std.ArrayList(Ref) = .empty;
                if (seed) |b| if (b.entries.len > 0) {
                    var text: std.Io.Writer.Allocating = .init(m.s);
                    try writeValue(V, b.*, path, .display, &text.writer);
                    const layer = try m.s.create(Layer);
                    layer.* = try m.store.parseLayer(m.s, .builtin, .builtin, text.written());
                    try layers.append(m.s, .{ .layer = layer, .node = .root });
                };
                try layers.appendSlice(m.s, refs);
                const Slot = struct { name: []const u8, refs: std.ArrayList(Ref) = .empty };
                var slots: std.ArrayList(Slot) = .empty;
                for (layers.items) |r| switch (r.get()) {
                    .empty_literal => {},
                    .struct_literal => |lit| for (lit.names, 0..) |n, i| {
                        const name = n.get(&r.layer.zoir);
                        if (!validName(name)) return m.failAt(r, "invalid_params.config_zon", path);
                        const child: Ref = .{ .layer = r.layer, .node = lit.vals.at(@intCast(i)) };
                        const slot = for (slots.items) |*slot| {
                            if (std.mem.eql(u8, slot.name, name)) break slot;
                        } else blk: {
                            try slots.append(m.s, .{ .name = name });
                            break :blk &slots.items[slots.items.len - 1];
                        };
                        try slot.refs.append(m.s, child);
                    },
                    else => return m.failAt(r, "invalid_params.config_zon", path),
                };
                const saved = .{ .replace = m.replace, .sources = m.sources, .alias = m.alias };
                defer {
                    m.replace = saved.replace;
                    m.sources = saved.sources;
                    m.alias = saved.alias;
                }
                const real_path = m.realKey(path);
                var top: Source = if (refs.len > 0) refs[refs.len - 1].layer.reported() else .builtin;
                if (slots.items.len > 0) top = .builtin;
                try m.w.writeAll(if (m.form == .file) ".{" else ".{ .entries = .{");
                for (slots.items) |slot| {
                    var entry_refs = slot.refs.items;
                    m.replace = null;
                    if (saved.replace) |key| {
                        const ckey = try std.fmt.allocPrint(m.s, "{s}.\"{s}\"", .{ path, slot.name });
                        if (std.mem.eql(u8, key, ckey)) {
                            entry_refs = entry_refs[entry_refs.len - 1 ..];
                        } else if (std.mem.startsWith(u8, key, ckey) and key[ckey.len] == '.') {
                            m.replace = try std.fmt.allocPrint(m.s, "{s}{s}", .{ entry_path, key[ckey.len..] });
                        }
                    }
                    const real = try std.fmt.allocPrint(m.s, "{s}.\"{s}\"", .{ real_path, slot.name });
                    m.alias = .{ .from = entry_path, .to = real };
                    m.sources = null;
                    if (m.form == .file) {
                        try m.w.print(" .{f} = ", .{std.zig.fmtId(slot.name)});
                    } else {
                        try m.w.writeAll(" .{ .name = ");
                        try std.zon.stringify.serialize(slot.name, .{ .whitespace = false }, m.w);
                        try m.w.writeAll(", .value = ");
                    }
                    try m.value(E, entry_path, entry_refs);
                    try m.w.writeAll(if (m.form == .file) "," else " },");
                    m.sources = saved.sources;
                    m.alias = saved.alias;
                    var source: Source = .builtin;
                    for (entry_refs) |r| if (@backingInt(r.layer.reported()) > @backingInt(source)) {
                        source = r.layer.reported();
                    };
                    try m.record(real, source);
                    if (@backingInt(source) > @backingInt(top)) top = source;
                }
                try m.w.writeAll(if (m.form == .file) " }" else " } }");
                return m.record(real_path, top);
            }
        };
        fn mergeText(self: *Self, s: std.mem.Allocator, refs: []const Ref, replace: ?[]const u8, sources: ?*std.ArrayList(SourceEntry), form: Merge.Form) ![]const u8 {
            var out: std.Io.Writer.Allocating = .init(s);
            var m: Merge = .{ .store = self, .s = s, .w = &out.writer, .replace = replace, .report = replace, .sources = sources, .secrets = sources != null, .form = form };
            m.value(T, "", refs) catch |err| return if (err == error.WriteFailed) error.OutOfMemory else err;
            return out.written();
        }
        fn byName(comptime path: []const u8) bool {
            for (policies) |p| if (p.by_name and std.mem.eql(u8, p.key, path)) return true;
            return false;
        }
        /// Leaf value keys of T, as `config get` reports their sources.
        fn leafPaths(comptime V: type, comptime path: []const u8) []const []const u8 {
            comptime {
                @setEvalBranchQuota(100_000);
                if (byName(path) or isMap(V) or @typeInfo(V) != .@"struct") return &.{path};
                var out: []const []const u8 = &.{};
                for (fields(V)) |f| out = out ++ leafPaths(f.type, join(path, f.name));
                return out;
            }
        }
        fn validate(self: *Self, value: T) !void {
            if (!validData(T, value)) return self.fail("invalid_params.config_value", "");
            inline for (policies) |policy| if (comptime policy.secret) {
                const ref = fieldAt(T, value, policy.key);
                if (ref.len != 0 and !validReference(ref)) return self.fail("invalid_params.config_secret", policy.key);
            };
            if (self.options.validate) |f| if (f(value)) |v| return self.failValidation(v, null);
        }
        fn failValidation(self: *Self, v: Validation, layer: ?Source) error{InvalidConfig} {
            const code = if (std.mem.startsWith(u8, v.code, "invalid_params.") and proto.errors.knownCode(v.code)) v.code else "invalid_params.config_value";
            // An overlay index the store does not have is dropped, not reported.
            var source = v.source orelse layer;
            if (source) |src| if (src.overlayIndex()) |i| if (i >= self.options.overlays.len) {
                source = null;
            };
            return self.failIn(code, v.key, source);
        }
        pub fn check(self: *Self) !void {
            var snap = try self.load();
            defer snap.deinit();
        }
        pub fn get(self: *Self, a: std.mem.Allocator, key: []const u8) ![]const u8 {
            return (try self.lookup(a, key)).content;
        }
        /// Effective redacted value of `key` and where each value comes from.
        pub fn lookup(self: *Self, a: std.mem.Allocator, key: []const u8) !Lookup {
            var snap = try self.load();
            defer snap.deinit();
            const canon = try self.canonical(a, snap.value, key);
            const content = self.render(a, snap.value, canon, true) catch |err| return if (err == error.InvalidConfig) self.fail("invalid_params.config_key", key) else err;
            var list: std.ArrayList(SourceEntry) = .empty;
            var top: Source = .builtin;
            inline for (comptime leafPaths(T, "")) |leaf| {
                const map = comptime isMap(keyType(T, leaf));
                if (canon.len == 0 or std.mem.eql(u8, leaf, canon) or (std.mem.startsWith(u8, leaf, canon) and leaf.len > canon.len and leaf[canon.len] == '.')) {
                    const source = for (snap.sources) |e| {
                        if (std.mem.eql(u8, e.key, leaf)) break e.source;
                    } else .builtin;
                    try list.append(a, .{ .key = leaf, .source = source });
                    if (@backingInt(source) > @backingInt(top)) top = source;
                    // Entries of a map, as `<map>."name"`.
                    if (map) for (snap.sources) |e| if (std.mem.startsWith(u8, e.key, leaf ++ ".\"")) {
                        try list.append(a, .{ .key = try a.dupe(u8, e.key), .source = e.source });
                    };
                } else if (map and std.mem.startsWith(u8, canon, leaf ++ ".")) {
                    // A key inside one map entry reports that entry's source.
                    const seg = splitName(canon[leaf.len + 1 ..]).?;
                    const entry = canon[0 .. leaf.len + seg.name.len + 3];
                    const source = for (snap.sources) |e| {
                        if (std.mem.eql(u8, e.key, entry)) break e.source;
                    } else .builtin;
                    try list.append(a, .{ .key = try a.dupe(u8, entry), .source = source });
                    if (@backingInt(source) > @backingInt(top)) top = source;
                }
            }
            return .{ .content = content, .source = top, .sources = try list.toOwnedSlice(a) };
        }
        /// Resolves a user key to its canonical form, where every map entry
        /// name is quoted (`floats.presets."venom.settings".width`). An
        /// unquoted entry name is the longest name present in `value` that
        /// the key continues with a valid field path; otherwise the whole
        /// remainder is a (new) entry name.
        fn canonical(self: *Self, a: std.mem.Allocator, value: ?T, key: []const u8) ![]const u8 {
            if (comptime !hasMap(T)) {
                if (!validKey(T, key)) return self.fail("invalid_params.config_key", key);
                return key;
            }
            var out: std.Io.Writer.Allocating = .init(a);
            const ok = resolveKey(T, value, key, &out.writer) catch return error.OutOfMemory;
            if (!ok) return self.fail("invalid_params.config_key", key);
            return out.written();
        }
        fn render(self: *Self, a: std.mem.Allocator, value: T, key: []const u8, redact: bool) ![]const u8 {
            var out: std.Io.Writer.Allocating = .init(a);
            defer out.deinit();
            const found = renderAt(T, value, key, "", if (redact) .redacted else .internal, &out.writer) catch |err| return if (err == error.WriteFailed) error.OutOfMemory else err;
            if (!found) return self.fail("invalid_params.config_key", key);
            return out.toOwnedSlice();
        }
        fn renderAt(comptime V: type, value: V, key: []const u8, comptime path: []const u8, mode: WriteMode, w: *std.Io.Writer) anyerror!bool {
            if (key.len == 0) {
                try writeValue(V, value, path, mode, w);
                return true;
            }
            if (comptime isMap(V)) {
                const seg = splitName(key) orelse return false;
                for (value.entries) |e| if (std.mem.eql(u8, e.name, seg.name)) return renderAt(V.cfg_map_value, e.value, seg.rest, join(path, "*"), mode, w);
                return false;
            }
            if (comptime @typeInfo(V) == .@"struct") {
                const dot = std.mem.indexOfScalar(u8, key, '.');
                const head = key[0 .. dot orelse key.len];
                inline for (fields(V)) |f| if (std.mem.eql(u8, head, f.name)) {
                    if (dot != null and dot.? + 1 == key.len) return false;
                    return renderAt(f.type, @field(value, f.name), if (dot) |d| key[d + 1 ..] else "", join(path, f.name), mode, w);
                };
            }
            return false;
        }
        /// redacted: `config get` and snapshots; display: the same without
        /// redaction (Map builtin layer); internal: what `std.zon.parse`
        /// reads back into T (Map keys in their `.entries` form).
        const WriteMode = enum { redacted, display, internal };
        fn writeValue(comptime V: type, value: V, comptime path: []const u8, mode: WriteMode, w: *std.Io.Writer) anyerror!void {
            if (mode == .redacted and comptime secretPath(path)) {
                try w.writeAll("\"<redacted>\"");
                return;
            }
            if (comptime isMap(V)) if (mode != .internal) {
                try w.writeAll(".{");
                for (value.entries) |e| {
                    try w.print(" .{f} = ", .{std.zig.fmtId(e.name)});
                    try writeValue(V.cfg_map_value, e.value, join(path, "*"), mode, w);
                    try w.writeAll(",");
                }
                try w.writeAll(" }");
                return;
            };
            switch (@typeInfo(V)) {
                .@"struct" => {
                    try w.writeAll(".{");
                    inline for (comptime fields(V)) |f| {
                        try w.print(" .{f} = ", .{std.zig.fmtId(f.name)});
                        try writeValue(f.type, @field(value, f.name), join(path, f.name), mode, w);
                        try w.writeAll(",");
                    }
                    try w.writeAll(" }");
                },
                else => try std.zon.stringify.serialize(value, .{ .whitespace = false }, w),
            }
        }
        fn hasSecret(comptime path: []const u8) bool {
            for (policies) |p| if (p.secret and (std.mem.eql(u8, p.key, path) or (std.mem.startsWith(u8, p.key, path) and p.key.len > path.len and p.key[path.len] == '.'))) return true;
            return false;
        }
        fn secretPath(comptime path: []const u8) bool {
            for (policies) |p| if (p.secret and std.mem.eql(u8, p.key, path)) return true;
            return false;
        }
        fn assign(self: *Self, comptime V: type, ptr: *V, key: []const u8, bytes: []const u8, a: std.mem.Allocator) anyerror!void {
            if (key.len == 0) {
                ptr.* = try self.parse(V, a, bytes, "");
                return;
            }
            if (comptime @typeInfo(V) == .@"struct") {
                const dot = std.mem.indexOfScalar(u8, key, '.');
                const head = key[0 .. dot orelse key.len];
                inline for (fields(V)) |f| if (std.mem.eql(u8, head, f.name)) {
                    if (dot != null and dot.? + 1 == key.len) return self.fail("invalid_params.config_key", key);
                    return self.assign(f.type, &@field(ptr.*, f.name), if (dot) |d| key[d + 1 ..] else "", bytes, a);
                };
            }
            return self.fail("invalid_params.config_key", key);
        }
        fn pending(self: *Self, a: std.mem.Allocator, persisted: T) !bool {
            inline for (policies) |p| if (comptime p.restart) {
                const desired = try self.render(a, persisted, p.key, false);
                const active = try self.render(a, self.active.value, p.key, false);
                if (!std.mem.eql(u8, desired, active)) return true;
            };
            return false;
        }
        /// `setIn` the file `Options.write` names (the user file by default).
        pub fn set(self: *Self, key: []const u8, bytes: []const u8) !Change {
            return self.setIn(self.options.write, key, bytes);
        }
        /// Writes only the `target` file (`.user` or `Source.overlay(i)`):
        /// its own keys plus `key`. The value at `key` replaces that file's
        /// previous one (by_name lists included); the effective config (every
        /// layer) must validate. A missing overlay file is created.
        pub fn setIn(self: *Self, target: Source, key: []const u8, bytes: []const u8) !Change {
            if (!validTarget(target, self.options.overlays.len)) return error.InvalidConfigPath;
            if (key.len == 0 or (comptime !hasMap(T)) and !validKey(T, key)) return self.fail("invalid_params.config_key", key);
            if (bytes.len > self.options.max_bytes) return self.fail("invalid_params.config_value", key);
            var scratch: std.heap.ArenaAllocator = .init(self.gpa);
            defer scratch.deinit();
            const a = scratch.allocator();
            // Unquoted map entry names resolve against the effective config;
            // when it cannot load, only quoted names address existing entries.
            var known: ?Snapshot = null;
            defer if (known) |*k| k.deinit();
            if (comptime hasMap(T)) known = self.loadParsed() catch |err| switch (err) {
                error.OutOfMemory => return err,
                else => null,
            };
            const canon = try self.canonical(a, if (known) |k| k.value else null, key);
            var input = bytes;
            inline for (policies) |p| if (comptime p.secret) {
                if (std.mem.eql(u8, canon, p.key)) {
                    const raw = try self.parse([]const u8, a, bytes, key);
                    if (raw.len > 0 and !validReference(raw)) {
                        const store = self.options.secrets orelse return self.fail("failed.config_secret_store", key);
                        const ref = store.vtable.put(store.ptr, a, key, raw) catch |err| return if (err == error.OutOfMemory) err else self.fail("failed.config_secret_store", key);
                        if (!validReference(ref)) return self.fail("failed.config_secret_store", key);
                        var encoded: std.Io.Writer.Allocating = .init(a);
                        std.zon.stringify.serialize(ref, .{}, &encoded.writer) catch return error.OutOfMemory;
                        input = encoded.written();
                    }
                }
            };
            // The value must be one ZON expression on its own before it is
            // nested under the key, so it cannot reach other keys.
            _ = self.parseLayer(a, .input, target, input) catch |err| return if (err == error.InvalidConfig) self.fail(self.failure.code, key) else err;
            input = try valueExpression(a, input) orelse return self.fail("invalid_params.config_zon", key);
            var nested: std.Io.Writer.Allocating = .init(a);
            {
                var pos: usize = 0;
                var depth: usize = 0;
                while (nextSegment(canon, &pos)) |part| : (depth += 1) nested.writer.print(".{{ .{f} = ", .{std.zig.fmtId(part)}) catch return error.OutOfMemory;
                nested.writer.print("{s}\n", .{input}) catch return error.OutOfMemory;
                for (0..depth) |_| nested.writer.writeAll(" }") catch return error.OutOfMemory;
            }
            const raw = try self.read(a);
            const index = target.overlayIndex();
            const own_bytes = if (index) |i| raw.overlays[i] orelse ".{}" else raw.user;
            const own = try self.parseLayer(a, .file, target, own_bytes);
            const patch = self.parseLayer(a, .input, target, nested.written()) catch |err| return if (err == error.InvalidConfig) self.fail(self.failure.code, key) else err;
            const own_ref: Ref = .{ .layer = &own, .node = .root };
            const before = try self.mergeText(a, &.{own_ref}, null, null, .file);
            const after = self.mergeText(a, &.{ own_ref, .{ .layer = &patch, .node = .root } }, canon, null, .file) catch |err| {
                // Errors in the set value carry the key as given.
                if (err == error.InvalidConfig and self.failure.source == null and std.mem.eql(u8, self.failure.key(), canon)) return self.fail(self.failure.code, key);
                return err;
            };
            // What goes in the file: the key edited in place, so comments and
            // formatting stay. `set` never rewrites a file: when the edit does
            // not mean exactly `after`, it refuses and the file stays as it is.
            // Only a new file, with nothing in it to lose, is `after` itself.
            const output = if (std.mem.eql(u8, own_bytes, ".{}")) after else edited: {
                const refused = "failed.config_edit";
                const text = try editText(a, own_bytes, canon, input) orelse return self.fail(refused, key);
                const layer = self.parseLayer(a, .file, target, text) catch |err| return if (err == error.InvalidConfig) self.fail(refused, key) else err;
                const meaning = self.mergeText(a, &.{.{ .layer = &layer, .node = .root }}, null, null, .file) catch |err| return if (err == error.InvalidConfig) self.fail(refused, key) else err;
                if (!std.mem.eql(u8, meaning, after)) return self.fail(refused, key);
                break :edited text;
            };
            if (output.len > self.options.max_bytes) return self.fail("invalid_params.config_value", key);
            var next = raw;
            if (index) |i| {
                const overlays = try a.dupe(?[]const u8, raw.overlays);
                overlays[i] = output;
                next.overlays = overlays;
            } else next.user = output;
            var snap: Snapshot = .{ .arena = .init(self.gpa), .value = undefined };
            defer snap.deinit();
            try self.compose(&snap, a, next);
            try self.validate(snap.value);
            const restart = try self.pending(a, snap.value);
            if (std.mem.eql(u8, before, after)) return .{ .changed = false, .restart_required = restart };
            // Replace the real file (a symlink stays one), in its own directory,
            // with its mode; a new file is private.
            const dest = followLinks(a, self.options.io, if (index) |i| self.options.overlays[i].path else self.path) catch |err| return if (err == error.OutOfMemory) err else self.fail("failed.config_io", key);
            const existing: ?std.Io.File.Permissions = if (std.Io.Dir.cwd().statFile(self.options.io, dest, .{})) |st| st.permissions else |err| switch (err) {
                error.FileNotFound => null,
                else => return self.fail("failed.config_io", key),
            };
            // A read-only file was made so on purpose; replacing it would work.
            if (existing) |mode| if (mode.toMode() & 0o222 == 0) return self.fail("failed.config_io", key);
            var file = std.Io.Dir.cwd().createFileAtomic(self.options.io, dest, .{ .make_path = true, .replace = true, .permissions = existing orelse .fromMode(0o600) }) catch return self.fail("failed.config_io", key);
            defer file.deinit(self.options.io);
            // The umask must not narrow an existing file's mode.
            if (existing) |mode| file.file.setPermissions(self.options.io, mode) catch return self.fail("failed.config_io", key);
            var buffer: [4096]u8 = undefined;
            var writer = file.file.writer(self.options.io, &buffer);
            writer.interface.writeAll(output) catch return self.fail("failed.config_io", key);
            writer.interface.flush() catch return self.fail("failed.config_io", key);
            file.file.sync(self.options.io) catch return self.fail("failed.config_io", key);
            const event = if (self.options.events) |log| try log.prepare("config:root", "config.changed", .{ .restart_required = restart }) else null;
            var committed = false;
            defer if (!committed) {
                if (event) |e| e.abort();
            };
            file.replace(self.options.io) catch return self.fail("failed.config_io", key);
            if (event) |e| e.commit();
            committed = true;
            // Own writes are not external watcher changes: set never reloads.
            self.observed = next.hash();
            self.restart_required = restart;
            return .{ .changed = true, .restart_required = restart };
        }
        pub fn reload(self: *Self) !Change {
            var next = try self.load();
            var transferred = false;
            defer if (!transferred) next.deinit();
            const a = next.arena.allocator();
            const restart = try self.pending(a, next.value);
            inline for (policies) |p| if (comptime p.restart) {
                const old = try self.render(a, self.active.value, p.key, false);
                try self.assign(T, &next.value, p.key, old, a);
            };
            // Cross-field validators also apply to the effective hot/restart mix.
            try self.validate(next.value);
            const before = try self.render(a, self.active.value, "", false);
            const after = try self.render(a, next.value, "", false);
            const changed = !std.mem.eql(u8, before, after);
            const activate = changed or restart != self.restart_required;
            const event = if (activate) blk: {
                break :blk if (self.options.events) |log| try log.prepare("config:root", "config.reloaded", .{ .restart_required = restart }) else null;
            } else null;
            var committed = false;
            defer if (!committed) {
                if (event) |e| e.abort();
            };
            // All shared fallible work is complete before product cleanup.
            if (self.options.pre_activate) |hook| {
                if (hook.vtable.apply(hook.ptr, self.active.value, next.value)) |failure| {
                    self.activation_failure = failure;
                    return self.fail("failed.config_activation", "");
                }
            }
            self.activation_failure = null;
            if (activate) {
                self.active.deinit();
                self.active = next;
                transferred = true;
                if (event) |e| e.commit();
            }
            committed = true;
            self.restart_required = restart;
            self.observed = next.hash;
            return .{ .changed = changed, .restart_required = restart };
        }
        /// Polling watcher, at most twice per second. Invalid external edits
        /// return an error once per content hash; the active snapshot survives.
        pub fn watch(self: *Self, now_ms: i64) !void {
            if (now_ms < self.next_watch_ms) return;
            self.next_watch_ms = now_ms +| 500;
            var arena: std.heap.ArenaAllocator = .init(self.gpa);
            defer arena.deinit();
            const hash = (try self.read(arena.allocator())).hash();
            if (hash == self.observed) return;
            self.observed = hash;
            _ = try self.reload();
        }
        pub fn schema(self: *Self, a: std.mem.Allocator) ![]const u8 {
            _ = self;
            const value = try schemaValue(T, a, "");
            return std.json.Stringify.valueAlloc(a, value, .{});
        }
        fn schemaValue(comptime V: type, a: std.mem.Allocator, comptime path: []const u8) anyerror!std.json.Value {
            var value: std.json.Value = .{ .object = .empty };
            const obj = &value.object;
            const info = @typeInfo(V);
            const policy = comptime policyAt(path);
            if (comptime isMap(V)) {
                try obj.put(a, "type", .{ .string = "object" });
                try obj.put(a, "additionalProperties", try schemaValue(V.cfg_map_value, a, join(path, "*")));
            } else switch (info) {
                .@"struct" => {
                    try obj.put(a, "type", .{ .string = "object" });
                    try obj.put(a, "additionalProperties", .{ .bool = false });
                    var properties: std.json.Value = .{ .object = .empty };
                    var required: std.json.Value = .{ .array = .init(a) };
                    inline for (comptime fields(V)) |f| {
                        var property = try schemaValue(f.type, a, join(path, f.name));
                        if (comptime f.default_value_ptr != null and !hasSecret(join(path, f.name))) {
                            const default: *const f.type = @ptrCast(@alignCast(f.default_value_ptr.?));
                            const encoded = try std.json.Stringify.valueAlloc(a, default.*, .{});
                            try property.object.put(a, "default", try std.json.parseFromSliceLeaky(std.json.Value, a, encoded, .{}));
                        }
                        // Beside the default, whatever the type: not inside `anyOf` or `items`.
                        if (comptime policyAt(join(path, f.name))) |p| if (p.description) |text| try property.object.put(a, "description", .{ .string = text });
                        try properties.object.put(a, f.name, property);
                        if (f.default_value_ptr == null) try required.array.append(.{ .string = f.name });
                    }
                    try obj.put(a, "properties", properties);
                    try obj.put(a, "required", required);
                },
                .bool => try obj.put(a, "type", .{ .string = "boolean" }),
                .int => |i| {
                    try obj.put(a, "type", .{ .string = "integer" });
                    try obj.put(a, "minimum", .{ .integer = @max(std.math.minInt(V), -9007199254740991) });
                    try obj.put(a, "maximum", .{ .integer = @min(std.math.maxInt(V), 9007199254740991) });
                    _ = i;
                },
                .float => try obj.put(a, "type", .{ .string = "number" }),
                .@"enum" => |e| {
                    try obj.put(a, "type", .{ .string = "string" });
                    var choices: std.json.Value = .{ .array = .init(a) };
                    inline for (e.field_names) |name| try choices.array.append(.{ .string = name });
                    try obj.put(a, "enum", choices);
                },
                .pointer => |p| {
                    if (p.size != .slice) @compileError("cfg: only slices are supported in config");
                    if (p.child == u8) try obj.put(a, "type", .{ .string = "string" }) else {
                        try obj.put(a, "type", .{ .string = "array" });
                        try obj.put(a, "items", try schemaValue(p.child, a, path));
                    }
                },
                .optional => |o| {
                    var variants: std.json.Value = .{ .array = .init(a) };
                    try variants.array.append(try schemaValue(o.child, a, path));
                    var null_type: std.json.Value = .{ .object = .empty };
                    try null_type.object.put(a, "type", .{ .string = "null" });
                    try variants.array.append(null_type);
                    try obj.put(a, "anyOf", variants);
                },
                else => @compileError("cfg: use structs, bools, JSON-safe numbers, enums, optional values and slices"),
            }
            if (policy) |p| {
                if (comptime p.hasFlags()) {
                    try obj.put(a, "writeOnly", .{ .bool = p.secret });
                    try obj.put(a, "x-venom-secret", .{ .bool = p.secret });
                    try obj.put(a, "x-venom-restart-required", .{ .bool = p.restart });
                }
                // On the schema that holds the type, so inside `anyOf` and
                // `items`; an integer's bounds replace those of its type.
                switch (info) {
                    .int => {
                        if (p.minimum) |bound| try obj.put(a, "minimum", .{ .integer = @intFromFloat(bound) });
                        if (p.maximum) |bound| try obj.put(a, "maximum", .{ .integer = @intFromFloat(bound) });
                    },
                    .float => {
                        if (p.minimum) |bound| try obj.put(a, "minimum", .{ .float = bound });
                        if (p.maximum) |bound| try obj.put(a, "maximum", .{ .float = bound });
                    },
                    .pointer => |s| if (s.child == u8) {
                        if (p.pattern) |text| try obj.put(a, "pattern", .{ .string = text });
                        if (p.format) |text| try obj.put(a, "format", .{ .string = text });
                    },
                    else => {},
                }
            }
            return value;
        }
        fn policyAt(comptime path: []const u8) ?FieldPolicy {
            comptime {
                @setEvalBranchQuota(100_000);
                for (policies) |p| if (std.mem.eql(u8, p.key, path)) return p;
                return null;
            }
        }
        /// Compose this entity with the product's other snapshot providers.
        pub fn capture(self: *Self, a: std.mem.Allocator) anyerror![]const proto.events.Entity {
            const result = try a.alloc(proto.events.Entity, 1);
            var snap = try self.load();
            defer snap.deinit();
            result[0] = .{ .resource = "config:root", .entity_type = "config", .event_types = &.{ "config.changed", "config.reloaded" }, .content = try std.json.Stringify.valueAlloc(a, .{ .content = try self.render(a, snap.value, "", true), .active_content = try self.render(a, self.active.value, "", true), .restart_required = try self.pending(a, snap.value) }, .{}) };
            return result;
        }
        pub fn bindings(self: *Self) [5]proto.Binding {
            var result: [5]proto.Binding = undefined;
            for (verbs, &result) |v, *binding| binding.* = .{ .verb = v.name, .handler = proto.VerbHandler.init(self) };
            return result;
        }
        pub fn call(self: *Self, c: *proto.Call) anyerror!void {
            if (!try c.authorize(if (std.mem.eql(u8, c.verb.name, "config.set") or std.mem.eql(u8, c.verb.name, "config.reload")) .admin else .read, .{ .kind = "config", .id = "root" })) return;
            self.run(c) catch |err| switch (err) {
                error.InvalidConfig => {
                    if (std.mem.eql(u8, self.failure.code, "failed.config_activation")) {
                        const failure = self.activation_failure.?;
                        return c.fail(self.failure.code, "configuration activation failed", .{ .reason = @tagName(failure.reason), .partial = failure.partial });
                    }
                    const param = if (std.mem.eql(u8, c.verb.name, "config.set")) (if (std.mem.eql(u8, self.failure.code, "invalid_params.config_key")) "key" else "value") else if (std.mem.eql(u8, c.verb.name, "config.get")) "key" else "";
                    const message = if (std.mem.eql(u8, self.failure.code, "failed.config_edit")) "cannot edit this key in the file's text; the file is unchanged, edit it by hand" else "configuration operation failed";
                    if (self.failure.source) |source| return c.fail(self.failure.code, message, .{ .param = param, .key = self.failure.key(), .source = self.sourceName(source), .path = self.sourcePath(source) });
                    return c.fail(self.failure.code, message, .{ .param = param, .key = self.failure.key() });
                },
                else => return err,
            };
        }
        fn run(self: *Self, c: *proto.Call) !void {
            const name = c.verb.name;
            const a = c.arena();
            if (std.mem.eql(u8, name, "config.get")) {
                const found = try self.lookup(a, c.params.object.get("key").?.string);
                const Item = struct { key: []const u8, source: []const u8, path: ?[]const u8 };
                const items = try a.alloc(Item, found.sources.len);
                for (found.sources, items) |e, *item| item.* = .{ .key = e.key, .source = self.sourceName(e.source), .path = self.sourcePath(e.source) };
                return c.ok(.{ .content = found.content, .source = self.sourceName(found.source), .path = self.sourcePath(found.source), .sources = items });
            }
            if (std.mem.eql(u8, name, "config.schema")) return c.ok(.{ .content = try self.schema(a) });
            if (std.mem.eql(u8, name, "config.check")) {
                try self.check();
                return c.ok(.{ .valid = true });
            }
            if (std.mem.eql(u8, name, "config.set")) return c.ok(try self.set(c.params.object.get("key").?.string, c.params.object.get("value").?.string));
            return c.ok(try self.reload());
        }
    };
}
/// The highest file layer supplying `key`, a value under it, or a value it is
/// part of (a by-name entry counts as one value).
fn narrowestFile(sources: []const SourceEntry, key: []const u8) ?Source {
    if (key.len == 0) return null;
    var best: ?Source = null;
    for (sources) |e| {
        if (e.source == .builtin or !(underKey(e.key, key) or underKey(key, e.key))) continue;
        if (best == null or @backingInt(e.source) > @backingInt(best.?)) best = e.source;
    }
    return best;
}
fn underKey(key: []const u8, parent: []const u8) bool {
    return std.mem.startsWith(u8, key, parent) and (key.len == parent.len or key[parent.len] == '.');
}
fn validKey(comptime V: type, key: []const u8) bool {
    if (key.len == 0) return true;
    if (comptime isMap(V)) {
        if (key[0] != '"') return validUnquoted(key);
        const seg = splitName(key) orelse return false;
        return validName(seg.name) and validKey(V.cfg_map_value, seg.rest);
    }
    if (comptime @typeInfo(V) != .@"struct") return false;
    const dot = std.mem.indexOfScalar(u8, key, '.');
    const head = key[0 .. dot orelse key.len];
    inline for (comptime fields(V)) |f| if (std.mem.eql(u8, head, f.name)) {
        if (dot != null and dot.? + 1 == key.len) return false;
        return validKey(f.type, if (dot) |d| key[d + 1 ..] else "");
    };
    return false;
}
/// An unquoted entry name (or name plus field path): no empty segments.
fn validUnquoted(key: []const u8) bool {
    return validName(key) and key[0] != '.' and key[key.len - 1] != '.' and std.mem.indexOf(u8, key, "..") == null;
}
/// Writes the canonical form of `key` (map entry names quoted); see
/// `Store.canonical`. `value` supplies the known entry names, when loaded.
fn resolveKey(comptime V: type, value: ?V, key: []const u8, w: *std.Io.Writer) error{WriteFailed}!bool {
    if (key.len == 0) return true;
    if (comptime isMap(V)) {
        const E = V.cfg_map_value;
        var name = key;
        var rest: []const u8 = "";
        var entry: ?E = null;
        if (key[0] == '"') {
            const seg = splitName(key) orelse return false;
            name = seg.name;
            rest = seg.rest;
            if (value) |v| entry = v.get(name);
        } else {
            if (!validUnquoted(key)) return false;
            var best: ?usize = null;
            if (value) |v| for (v.entries, 0..) |e, i| {
                const n = e.name;
                if (!std.mem.startsWith(u8, key, n)) continue;
                if (key.len != n.len and (key[n.len] != '.' or !validKey(E, key[n.len + 1 ..]))) continue;
                if (best == null or n.len > v.entries[best.?].name.len) best = i;
            };
            if (best) |i| {
                const e = value.?.entries[i];
                name = e.name;
                rest = if (key.len == name.len) "" else key[name.len + 1 ..];
                entry = e.value;
            }
        }
        if (!validName(name)) return false;
        try w.print("\"{s}\"", .{name});
        if (rest.len == 0) return true;
        try w.writeAll(".");
        return resolveKey(E, entry, rest, w);
    }
    if (comptime @typeInfo(V) != .@"struct") return false;
    const dot = std.mem.indexOfScalar(u8, key, '.');
    const head = key[0 .. dot orelse key.len];
    inline for (comptime fields(V)) |f| if (std.mem.eql(u8, head, f.name)) {
        if (dot != null and dot.? + 1 == key.len) return false;
        try w.writeAll(head);
        if (dot == null) return true;
        try w.writeAll(".");
        return resolveKey(f.type, if (value) |v| @field(v, f.name) else null, key[dot.? + 1 ..], w);
    };
    return false;
}
fn join(comptime path: []const u8, comptime field: []const u8) []const u8 {
    return if (path.len == 0) field else path ++ "." ++ field;
}
/// What `pattern`, `format` and the bounds apply to: the value of an optional,
/// the element of a list.
fn annotatedType(comptime V: type) type {
    return switch (@typeInfo(V)) {
        .optional => |o| annotatedType(o.child),
        .pointer => |s| if (s.size == .slice and s.child != u8) annotatedType(s.child) else V,
        else => V,
    };
}
fn checkAnnotations(comptime p: FieldPolicy, comptime FT: type) void {
    const V = annotatedType(FT);
    if (p.description) |text| if (text.len == 0) @compileError("cfg: empty description on " ++ p.key);
    if (p.pattern != null or p.format != null) {
        if (V != []const u8) @compileError("cfg: pattern and format need a string key: " ++ p.key);
        // The file holds a `secret:` reference, the caller sends the plaintext.
        if (p.secret) @compileError("cfg: pattern and format do not fit a secret key: " ++ p.key);
        if (p.pattern) |text| if (text.len == 0) @compileError("cfg: empty pattern on " ++ p.key);
        if (p.format) |text| if (text.len == 0) @compileError("cfg: empty format on " ++ p.key);
    }
    if (p.minimum == null and p.maximum == null) return;
    const lowest: f64, const highest: f64 = switch (@typeInfo(V)) {
        .int => .{ @floatFromInt(@max(std.math.minInt(V), -9007199254740991)), @floatFromInt(@min(std.math.maxInt(V), 9007199254740991)) },
        .float => .{ -std.math.floatMax(f64), std.math.floatMax(f64) },
        else => @compileError("cfg: minimum and maximum need a numeric key: " ++ p.key),
    };
    for ([_]?f64{ p.minimum, p.maximum }) |bound| if (bound) |b| {
        if (!std.math.isFinite(b) or b < lowest or b > highest) @compileError("cfg: bound outside the type of " ++ p.key);
        if (@typeInfo(V) == .int and @floor(b) != b) @compileError("cfg: integer key with a fractional bound: " ++ p.key);
    };
    if (p.minimum != null and p.maximum != null and p.minimum.? > p.maximum.?) @compileError("cfg: minimum above maximum on " ++ p.key);
}
fn keyType(comptime T: type, comptime path: []const u8) type {
    if (isMap(T)) @compileError("cfg: policies cannot address Map entries");
    const dot = std.mem.indexOfScalar(u8, path, '.');
    const head = path[0 .. dot orelse path.len];
    for (fields(T)) |f| if (std.mem.eql(u8, head, f.name)) return if (dot) |d| keyType(f.type, path[d + 1 ..]) else f.type;
    @compileError("cfg: policy names an unknown field");
}
fn fieldAt(comptime T: type, value: T, comptime path: []const u8) keyType(T, path) {
    const dot = comptime std.mem.indexOfScalar(u8, path, '.');
    const head = comptime path[0 .. dot orelse path.len];
    return if (comptime dot != null) fieldAt(@TypeOf(@field(value, head)), @field(value, head), path[dot.? + 1 ..]) else @field(value, head);
}
/// The one reference grammar, `secret:<name>`, owned by the secrets module.
const validReference = @import("secrets").reference.valid;
fn validData(comptime T: type, value: T) bool {
    return switch (@typeInfo(T)) {
        .float => std.math.isFinite(value),
        .int => @as(i128, value) >= -9007199254740991 and @as(i128, value) <= 9007199254740991,
        .@"struct" => blk: {
            inline for (comptime fields(T)) |f| if (!validData(f.type, @field(value, f.name))) break :blk false;
            break :blk true;
        },
        .optional => |o| if (value) |v| validData(o.child, v) else true,
        .pointer => |p| if (p.child == u8) std.unicode.utf8ValidateSlice(value) else blk: {
            for (value) |v| if (!validData(p.child, v)) break :blk false;
            break :blk true;
        },
        else => true,
    };
}
test {
    _ = @import("tests.zig");
}

const FieldInfo = struct { name: []const u8, type: type, default_value_ptr: ?*const anyopaque };
fn fields(comptime T: type) [@typeInfo(T).@"struct".field_names.len]FieldInfo {
    const info = @typeInfo(T).@"struct";
    var result: [info.field_names.len]FieldInfo = undefined;
    for (info.field_names, info.field_types, info.field_attrs, 0..) |name, FT, attrs, i| result[i] = .{ .name = name, .type = FT, .default_value_ptr = attrs.default_value_ptr };
    return result;
}
