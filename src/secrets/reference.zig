//! The one convention for referring to a secret: the string `secret:<name>`.
//! Config files hold these references, never plaintext (`cfg` secret fields);
//! `Store.resolve` turns one into its value. `cfg` imports this grammar, so
//! the two cannot drift apart. No imports beyond `std`.
const std = @import("std");

pub const prefix = "secret:";
pub const max_name = 64;

/// A secret name: `[A-Za-z0-9][A-Za-z0-9._-]{0,63}`.
pub fn validName(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name or !std.ascii.isAlphanumeric(name[0])) return false;
    for (name) |ch| if (!(std.ascii.isAlphanumeric(ch) or ch == '.' or ch == '_' or ch == '-')) return false;
    return true;
}

/// The name in a `secret:<name>` reference, or null if `ref` is not one.
pub fn parse(ref: []const u8) ?[]const u8 {
    if (!std.mem.startsWith(u8, ref, prefix)) return null;
    const name = ref[prefix.len..];
    return if (validName(name)) name else null;
}

pub fn valid(ref: []const u8) bool {
    return parse(ref) != null;
}

test "reference grammar" {
    try std.testing.expectEqualStrings("anthropic", parse("secret:anthropic").?);
    try std.testing.expectEqualStrings("api.key_2-b", parse("secret:api.key_2-b").?);
    for ([_][]const u8{ "", "anthropic", "secret:", "secret:-x", "secret:a/b", "secret:a b", "Secret:a", "secret:" ++ &@as([65]u8, @splat('x')) }) |bad|
        try std.testing.expect(!valid(bad));
}
