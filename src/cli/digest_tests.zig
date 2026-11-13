//! Canonical JSON and complete-schema digest fixtures, and doctor skew
//! reporting.
const std = @import("std");
const cli = @import("root.zig");
const digest = cli.digest;
const t = std.testing;

fn canonicalText(a: std.mem.Allocator, json: []const u8) ![]const u8 {
    const value = try std.json.parseFromSliceLeaky(std.json.Value, a, json, .{});
    var out: std.Io.Writer.Allocating = .init(a);
    try digest.writeCanonical(a, &out.writer, value);
    return out.written();
}
fn number(a: std.mem.Allocator, x: f64) ![]const u8 {
    var out: std.Io.Writer.Allocating = .init(a);
    try digest.writeNumber(&out.writer, x);
    return out.written();
}

test "digest: string escapes only quotes, backslashes and C0 controls" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var out: std.Io.Writer.Allocating = .init(arena.allocator());
    try digest.writeString(&out.writer, "q\"b\\s/\n\t\x00\x1f\x7f é ☃ </tag>");
    try t.expectEqualStrings("\"q\\\"b\\\\s/\\u000a\\u0009\\u0000\\u001f\x7f é ☃ </tag>\"", out.written());
}

test "digest: number formatting" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Case = struct { f64, []const u8 };
    for ([_]Case{
        .{ 0.0, "0" },                                         .{ -0.0, "0" },
        .{ 1.0, "1" },                                         .{ -1.5, "-1.5" },
        .{ 0.1, "0.1" },                                       .{ 100.0, "100" },
        .{ 4294967295.0, "4294967295" },                       .{ 9007199254740991.0, "9007199254740991" },
        .{ 123456789012345680000.0, "123456789012345680000" }, .{ 1e21, "1e21" },
        .{ 1.5e300, "1.5e300" },                               .{ 0.000001, "0.000001" },
        .{ 1.5e-7, "1.5e-7" },                                 .{ -2.5e-10, "-2.5e-10" },
        .{ 5e-324, "5e-324" },                                 .{ 1.7976931348623157e308, "1.7976931348623157e308" },
        .{ 12.375, "12.375" },                                 .{ 0.3333333333333333, "0.3333333333333333" },
    }) |c| try t.expectEqualStrings(c[1], try number(a, c[0]));
    try t.expectError(error.InvalidNumber, number(a, std.math.inf(f64)));
    try t.expectError(error.InvalidNumber, number(a, std.math.nan(f64)));
}

test "digest: canonical JSON sorts keys by bytes, keeps arrays, drops whitespace" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try t.expectEqualStrings(
        "{\"B\":1,\"a\":[3,1,2],\"aa\":{\"y\":null,\"z\":true},\"b\":-0.5,\"é\":\"x\"}",
        try canonicalText(a, " { \"é\" : \"x\", \"b\": -5e-1, \"aa\": {\"z\": true, \"y\": null}, \"a\": [3, 1, 2], \"B\": 1.0 } \n"),
    );
    try t.expectEqualStrings("[0,0,1e21,0.000001,1e-7]", try canonicalText(a, "[-0.0,0,1E+21,1e-6,0.0000001]"));
    try t.expectEqualStrings("\"\\u000a\"", try canonicalText(a, "\"\\n\""));
}

// Declared out of order; field, choice and example order must survive.
const fixture = .{
    .format = 1,
    .tool = "dig",
    .summary = "Digest \"fixture\"",
    .verbs = .{
        .{ .name = "zeta", .summary = "Last", .result = .{ .kind = .null }, .grant = .none },
        .{
            .name = "alpha",
            .summary = "First verb",
            .params = .{
                .{ .name = "text", .summary = "Text", .type = .{ .kind = .string }, .required = true },
                .{ .name = "mode", .summary = "Mode", .type = .{ .kind = .string, .choices = .{ "b", "a" } }, .default = "b" },
                .{ .name = "ratio", .summary = "Ratio", .type = .{ .kind = .number, .min = -0.5, .max = 1e21 }, .default = 0.25 },
                .{ .name = "count", .summary = "Count", .type = .{ .kind = .integer, .min = 0, .max = 9007199254740991 } },
            },
            .result = .{ .kind = .object, .fields = .{.{ .name = "out", .summary = "Out", .type = .{ .kind = .string }, .required = true }} },
            .grant = .read,
            .examples = .{
                .{ .params = .{ .text = "q\"\\" }, .result = .{ .out = "x" } },
                .{ .params = .{ .text = "2", .mode = "a", .count = 3 }, .result = .{ .out = "y" } },
            },
        },
    },
};
const reordered = .{
    .format = 1,
    .tool = fixture.tool,
    .summary = fixture.summary,
    .verbs = .{ fixture.verbs[1], fixture.verbs[0] },
};
const F = cli.Generator(fixture);

test "digest: normalized verb record expands defaults and keeps examples" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const m = try digest.manifest(F, a);
    const verbs = m.object.get("verbs").?.array.items;
    // Sorted by wire name; generated surface includes shared and local verbs.
    for (verbs[1..], 0..) |v, i| try t.expect(std.mem.lessThan(u8, verbs[i].object.get("name").?.string, v.object.get("name").?.string));
    var out: std.Io.Writer.Allocating = .init(a);
    try digest.writeCanonical(a, &out.writer, verbs[0]);
    try t.expectEqualStrings(
        "{\"errors\":[],\"examples\":[" ++
            "{\"params\":{\"mode\":\"b\",\"ratio\":0.25,\"text\":\"q\\\"\\\\\"},\"result\":{\"out\":\"x\"}}," ++
            "{\"params\":{\"count\":3,\"mode\":\"a\",\"ratio\":0.25,\"text\":\"2\"},\"result\":{\"out\":\"y\"}}]," ++
            "\"exit\":{\"kind\":\"standard\"},\"grant\":\"read\",\"name\":\"alpha\",\"params\":[" ++
            "{\"name\":\"text\",\"required\":true,\"summary\":\"Text\",\"type\":{\"kind\":\"string\"}}," ++
            "{\"default\":\"b\",\"name\":\"mode\",\"required\":false,\"summary\":\"Mode\",\"type\":{\"choices\":[\"b\",\"a\"],\"kind\":\"string\"}}," ++
            "{\"default\":0.25,\"name\":\"ratio\",\"required\":false,\"summary\":\"Ratio\",\"type\":{\"kind\":\"number\",\"max\":1e21,\"min\":-0.5}}," ++
            "{\"name\":\"count\",\"required\":false,\"summary\":\"Count\",\"type\":{\"kind\":\"integer\",\"max\":9007199254740991,\"min\":0}}]," ++
            "\"result\":{\"fields\":[{\"name\":\"out\",\"required\":true,\"summary\":\"Out\",\"type\":{\"kind\":\"string\"}}],\"kind\":\"object\"}," ++
            "\"streams\":false,\"summary\":\"First verb\"}",
        out.written(),
    );
    const doctor = for (verbs) |v| {
        if (std.mem.eql(u8, v.object.get("name").?.string, "doctor")) break v;
    } else unreachable;
    out.clearRetainingCapacity();
    try digest.writeCanonical(a, &out.writer, doctor.object.get("bundle").?);
    try t.expectEqualStrings("{\"dispatch\":\"remote\",\"name\":\"agent-contract\",\"version\":1}", out.written());
    const serve = for (verbs) |v| {
        if (std.mem.eql(u8, v.object.get("name").?.string, "serve")) break v;
    } else unreachable;
    try t.expectEqualStrings("local", serve.object.get("bundle").?.object.get("dispatch").?.string);
    for (verbs) |v| if (std.mem.eql(u8, v.object.get("name").?.string, "whoami"))
        try t.expectEqualStrings("grants", v.object.get("bundle").?.object.get("name").?.string);
    try t.expect(verbs[verbs.len - 1].object.get("bundle") == null); // zeta
    out.clearRetainingCapacity();
    try digest.writeCanonical(a, &out.writer, m.object.get("protocol").?);
    try t.expectEqualStrings("{\"transport\":[\"cancel\",\"hello\"],\"version\":1}", out.written());
}

test "digest: stable format, independent of declaration order, sensitive to docs and examples" {
    const d = try F.digest(t.allocator);
    try t.expect(std.mem.startsWith(u8, &d, "sha256:"));
    for (d[7..]) |ch| try t.expect(std.ascii.isDigit(ch) or (ch >= 'a' and ch <= 'f'));
    const text = try digest.canonical(F, t.allocator);
    defer t.allocator.free(text);
    try t.expectEqualStrings(&digest.ofCanonical(text), &d);
    try t.expect(std.mem.indexOfScalar(u8, text, '\n') == null and std.mem.indexOf(u8, text, "\": ") == null);
    try t.expect(text[text.len - 1] == '}');
    // Golden value: update deliberately when the normalized model changes.
    try t.expectEqualStrings("sha256:" ++ golden, &d);

    try t.expectEqualStrings(&d, &try cli.Generator(reordered).digest(t.allocator));
    const docs_changed = .{ .format = 1, .tool = "dig", .summary = "Digest fixture", .verbs = fixture.verbs };
    try t.expect(!std.mem.eql(u8, &d, &try cli.Generator(docs_changed).digest(t.allocator)));
    const example_changed = .{ .format = 1, .tool = "dig", .summary = fixture.summary, .verbs = .{ fixture.verbs[0], .{
        .name = "alpha",
        .summary = fixture.verbs[1].summary,
        .params = fixture.verbs[1].params,
        .result = fixture.verbs[1].result,
        .grant = .read,
        .examples = .{fixture.verbs[1].examples[1]},
    } } };
    try t.expect(!std.mem.eql(u8, &d, &try cli.Generator(example_changed).digest(t.allocator)));
    // FromSchema (no manifest examples) is a different surface.
    try t.expect(!std.mem.eql(u8, &d, &try cli.FromSchema(comptime cli.manifest.normalize(fixture)).digest(t.allocator)));
}
const golden = "f86c9a90d60c69c2d3a550d46e63bda0b2df35b828f8f591f84e57e2c28f96ad";

test "digest: doctor reports skew as a warning and absence as ok" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const daemon = "sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const Case = struct { client: ?[]const u8, server: ?[]const u8, status: cli.doctor.Status };
    for ([_]Case{
        .{ .client = daemon, .server = daemon, .status = .ok },
        .{ .client = "sha256:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb", .server = daemon, .status = .warn },
        .{ .client = null, .server = daemon, .status = .ok },
        .{ .client = daemon, .server = null, .status = .ok },
        .{ .client = null, .server = null, .status = .ok },
    }) |c| {
        var report: cli.doctor.Report = .{ .arena = arena.allocator(), .tool = "dig", .client_schema = c.client };
        try cli.doctor.schemaCheck(&report, c.server);
        try t.expectEqual(@as(usize, 1), report.results.items.len);
        const r = report.results.items[0];
        try t.expectEqualStrings("schema.digest", r.id);
        try t.expectEqual(c.status, r.status);
        try t.expectEqualStrings("dig doctor --json", r.fix);
        // A skew warning never makes doctor fail.
        try t.expectEqual(@as(u8, 0), report.status());
    }
}
