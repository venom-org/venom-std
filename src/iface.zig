//! iface: the vtable plus comptime-assert interface pattern.
//!
//! An interface is a struct with a type-erased pointer and a pointer to a
//! vtable. Every vtable field is a function pointer whose first parameter is
//! `*anyopaque` (the implementation's `self`):
//!
//! ```zig
//! pub const Greeter = struct {
//!     ptr: *anyopaque,
//!     vtable: *const VTable,
//!
//!     pub const VTable = struct {
//!         greet: *const fn (ptr: *anyopaque, name: []const u8) usize,
//!     };
//!
//!     pub fn init(impl: anytype) Greeter {
//!         const T = @typeInfo(@TypeOf(impl)).pointer.child;
//!         iface.assertImplements(VTable, T);
//!         return .{ .ptr = impl, .vtable = &struct {
//!             const vt: VTable = .{ .greet = greetThunk };
//!             fn greetThunk(ptr: *anyopaque, name: []const u8) usize {
//!                 return iface.cast(T, ptr).greet(name);
//!             }
//!         }.vt };
//!     }
//! };
//! ```
//!
//! `assertImplements` turns a missing or mistyped method into a compile error
//! that names the method and the expected signature, instead of an error deep
//! inside the generated thunk.

const std = @import("std");

/// Fails compilation unless `T` declares, for every field of `VTable`, a `pub`
/// method with the same name whose first parameter is `*T` or `*const T`
/// and whose remaining parameters and return type match the vtable entry.
pub fn assertImplements(comptime VTable: type, comptime T: type) void {
    comptime {
        const info = switch (@typeInfo(VTable)) {
            .@"struct" => |s| s,
            else => @compileError("iface: VTable must be a struct, got " ++ @typeName(VTable)),
        };
        for (info.field_names, info.field_types) |name, FieldType| {
            const want = fnInfo(FieldType) orelse @compileError(std.fmt.comptimePrint(
                "iface: {s}.{s} must be a function pointer, got {s}",
                .{ @typeName(VTable), name, @typeName(FieldType) },
            ));
            if (want.param_types.len == 0 or want.param_types[0] != *anyopaque) @compileError(std.fmt.comptimePrint(
                "iface: {s}.{s} must take `*anyopaque` as its first parameter",
                .{ @typeName(VTable), name },
            ));
            if (!@hasDecl(T, name)) @compileError(std.fmt.comptimePrint(
                "iface: {s} does not implement {s}.{s} ({s})",
                .{ @typeName(T), @typeName(VTable), name, @typeName(FieldType) },
            ));
            const Method = @TypeOf(@field(T, name));
            const got = switch (@typeInfo(Method)) {
                .@"fn" => |f| f,
                else => @compileError(std.fmt.comptimePrint(
                    "iface: {s}.{s} must be a function, got {s}",
                    .{ @typeName(T), name, @typeName(Method) },
                )),
            };
            const mismatch = std.fmt.comptimePrint(
                "iface: {s}.{s} has type {s}, which does not match {s}.{s} ({s}); " ++
                    "the first parameter must be *{s} or *const {s}",
                .{
                    @typeName(T), name,                 @typeName(Method), @typeName(VTable),
                    name,         @typeName(FieldType), @typeName(T),      @typeName(T),
                },
            );
            if (got.param_types.len != want.param_types.len) @compileError(mismatch);
            const Self = got.param_types[0] orelse @compileError(mismatch);
            if (Self != *T and Self != *const T) @compileError(mismatch);
            for (got.param_types[1..], want.param_types[1..]) |g, w| {
                if (g == null or g.? != w.?) @compileError(mismatch);
            }
            if (got.return_type == null or got.return_type.? != want.return_type.?) @compileError(mismatch);
        }
    }
}

/// Recovers the implementation pointer inside a vtable thunk.
pub inline fn cast(comptime T: type, ptr: *anyopaque) *T {
    return @ptrCast(@alignCast(ptr));
}

fn fnInfo(comptime F: type) ?std.lang.Type.Fn {
    return switch (@typeInfo(F)) {
        .pointer => |p| switch (@typeInfo(p.child)) {
            .@"fn" => |f| f,
            else => null,
        },
        else => null,
    };
}

// Example interface used by the tests below; it also documents the pattern.
const Greeter = struct {
    ptr: *anyopaque,
    vtable: *const VTable,

    const VTable = struct {
        greet: *const fn (ptr: *anyopaque, gpa: std.mem.Allocator, name: []const u8) error{OutOfMemory}![]u8,
        count: *const fn (ptr: *anyopaque) usize,
    };

    fn init(impl: anytype) Greeter {
        const T = @typeInfo(@TypeOf(impl)).pointer.child;
        assertImplements(VTable, T);
        return .{ .ptr = impl, .vtable = &struct {
            const vt: VTable = .{ .greet = greetThunk, .count = countThunk };
            fn greetThunk(ptr: *anyopaque, gpa: std.mem.Allocator, name: []const u8) error{OutOfMemory}![]u8 {
                return cast(T, ptr).greet(gpa, name);
            }
            fn countThunk(ptr: *anyopaque) usize {
                return cast(T, ptr).count();
            }
        }.vt };
    }

    fn greet(self: Greeter, gpa: std.mem.Allocator, name: []const u8) error{OutOfMemory}![]u8 {
        return self.vtable.greet(self.ptr, gpa, name);
    }

    fn count(self: Greeter) usize {
        return self.vtable.count(self.ptr);
    }
};

const English = struct {
    calls: usize = 0,

    pub fn greet(self: *English, gpa: std.mem.Allocator, name: []const u8) error{OutOfMemory}![]u8 {
        self.calls += 1;
        return std.fmt.allocPrint(gpa, "hello, {s}", .{name});
    }

    pub fn count(self: *const English) usize {
        return self.calls;
    }
};

test "iface: dispatch through the vtable reaches the implementation" {
    var impl: English = .{};
    const g = Greeter.init(&impl);

    const msg = try g.greet(std.testing.allocator, "venom");
    defer std.testing.allocator.free(msg);

    try std.testing.expectEqualStrings("hello, venom", msg);
    try std.testing.expectEqual(@as(usize, 1), g.count());
    try std.testing.expectEqual(@as(usize, 1), impl.calls);
}

test "iface: assertImplements accepts *T and *const T receivers" {
    comptime assertImplements(Greeter.VTable, English);
}
