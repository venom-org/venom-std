//! Leak canary. `zig build test-leak-canary` expects this test to FAIL:
//! it allocates from `std.testing.allocator` and never frees.

const std = @import("std");

test "leak canary: this test leaks on purpose" {
    _ = try std.testing.allocator.alloc(u8, 8);
}
