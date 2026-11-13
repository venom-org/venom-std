//! Handlers for the `secrets.set|get|list|rm` verbs in `verbs.zon`. Every
//! verb requires the `admin` grant, which the Dispatcher checks before a
//! handler runs.
const std = @import("std");
const proto = @import("proto");
const Store = @import("store.zig").Store;

pub const NameParams = struct { name: []const u8 };
pub const SetParams = struct { name: []const u8, value: []const u8 };

const Set = struct {
    store: *Store,
    pub fn call(self: *Set, c: *proto.Call, p: SetParams) anyerror!void {
        const created = self.store.set(p.name, p.value) catch |err| return switch (err) {
            error.InvalidName => badName(c),
            error.ValueTooLarge => c.fail("invalid_params.secret_too_large", "secret value exceeds 64 KiB", .{ .param = "value" }),
            error.TooManySecrets => c.fail("conflict.secrets_full", "secret store is full", null),
            else => err,
        };
        return c.ok(.{ .name = p.name, .created = created });
    }
};

const Get = struct {
    store: *Store,
    pub fn call(self: *Get, c: *proto.Call, p: NameParams) anyerror!void {
        const value = self.store.get(p.name) orelse return notFound(c);
        return c.ok(.{ .name = p.name, .value = value });
    }
};

const List = struct {
    store: *Store,
    pub fn call(self: *List, c: *proto.Call) anyerror!void {
        const entries = self.store.list();
        const names = try c.arena().alloc([]const u8, entries.len);
        for (entries, names) |e, *n| n.* = e.name;
        return c.ok(.{ .names = names });
    }
};

const Rm = struct {
    store: *Store,
    pub fn call(self: *Rm, c: *proto.Call, p: NameParams) anyerror!void {
        return c.ok(.{ .name = p.name, .removed = try self.store.remove(p.name) });
    }
};

fn badName(c: *proto.Call) !void {
    return c.fail("invalid_params.secret_name", "invalid secret name", .{ .param = "name" });
}

fn notFound(c: *proto.Call) !void {
    return c.fail("not_found.secret", "no secret by that name", null);
}

/// Handlers bound to one store. Keep it at a stable address while the
/// Dispatcher uses its bindings.
pub const Handlers = struct {
    set: Set,
    get: Get,
    list: List,
    rm: Rm,

    pub fn init(store: *Store) Handlers {
        return .{ .set = .{ .store = store }, .get = .{ .store = store }, .list = .{ .store = store }, .rm = .{ .store = store } };
    }

    pub fn bindings(self: *Handlers) [4]proto.Binding {
        return .{
            .{ .verb = "secrets.set", .handler = proto.VerbHandler.typed(SetParams, &self.set) },
            .{ .verb = "secrets.get", .handler = proto.VerbHandler.typed(NameParams, &self.get) },
            .{ .verb = "secrets.list", .handler = proto.VerbHandler.init(&self.list) },
            .{ .verb = "secrets.rm", .handler = proto.VerbHandler.typed(NameParams, &self.rm) },
        };
    }
};
