//! Docs, man, completions, skill and doctor generation.
const std = @import("std");
const proto = @import("proto");
const cli = @import("root.zig");
const t = std.testing;

const G = cli.Generator(.{
    .format = 1,
    .tool = "gen-test",
    .summary = "Gen \"test\" | tool",
    .verbs = .{
        .{ .name = "pane.set_title", .summary = "Set a *title*", .params = .{
            .{ .name = "title", .summary = "New title", .type = .{ .kind = .string }, .required = true },
            .{ .name = "mode", .summary = "Mode", .type = .{ .kind = .string, .choices = .{ "it's", "a|b" } }, .default = "it's" },
            .{ .name = "sticky", .summary = "Keep it", .type = .{ .kind = .boolean } },
        }, .result = .{ .kind = .null }, .grant = .write, .errors = .{
            .{ .code = "conflict.pane_busy", .summary = "Pane is busy" },
        }, .examples = .{
            .{ .params = .{ .title = "it's -here", .sticky = true }, .result = null },
            .{ .params = .{ .title = "-dash" }, .result = null },
        } },
        .{ .name = "count", .summary = "Count up", .streams = true, .item = .{ .kind = .integer }, .result = .{ .kind = .null }, .grant = .read },
    },
});

fn escape(f: *const fn (*std.Io.Writer, []const u8) anyerror!void, in: []const u8) ![]u8 {
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    errdefer out.deinit();
    try f(&out.writer, in);
    return out.toOwnedSlice();
}
fn markdownDocs() ![]u8 {
    var out: std.Io.Writer.Allocating = .init(t.allocator);
    errdefer out.deinit();
    try cli.docs.writeMarkdown(G, &out.writer);
    return out.toOwnedSlice();
}
fn contains(haystack: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, haystack, needle) == null) {
        std.debug.print("missing: {s}\n", .{needle});
        return error.TestExpectedEqual;
    }
}

test "gen: escaping for shell, YAML, roff and Markdown" {
    const cases = [_]struct { f: *const fn (*std.Io.Writer, []const u8) anyerror!void, in: []const u8, out: []const u8 }{
        .{ .f = cli.docs.shell, .in = "hi", .out = "hi" },
        .{ .f = cli.docs.shell, .in = "it's $x", .out = "'it'\\''s $x'" },
        .{ .f = cli.docs.shell, .in = "", .out = "''" },
        .{ .f = cli.docs.yaml, .in = "a \"b\" \\c", .out = "\"a \\\"b\\\" \\\\c\"" },
        .{ .f = cli.docs.roff, .in = ".TH -x \\", .out = "\\&.TH \\-x \\e" },
        .{ .f = cli.docs.markdown, .in = "a|*b*_<c>", .out = "a\\|\\*b\\*\\_\\<c\\>" },
    };
    for (cases) |c| {
        const got = try escape(c.f, c.in);
        defer t.allocator.free(got);
        try t.expectEqualStrings(c.out, got);
    }
}

test "gen: examples keep declaration order and quote values" {
    try t.expectEqual(@as(usize, 2), G.examples.len);
    try t.expectEqualStrings("pane.set_title", G.examples[0].verb);
    try t.expectEqualStrings("title", G.examples[0].args[0].flag);
    try t.expectEqualStrings("it's -here", G.examples[0].args[0].value);
    try t.expectEqualStrings("true", G.examples[0].args[1].value);
    try t.expectEqualStrings("null", G.examples[0].result);
}

test "gen: Markdown docs cover every verb deterministically" {
    const md = try markdownDocs();
    defer t.allocator.free(md);
    const again = try markdownDocs();
    defer t.allocator.free(again);
    try t.expectEqualStrings(md, again);
    inline for (G.verbs) |v| try contains(md, "- Wire name: `" ++ v.name ++ "`");
    try contains(md, "### `gen-test pane set-title`");
    try contains(md, "- MCP tool: `pane_dset__title`");
    try contains(md, "- MCP tool: none (local command)");
    try contains(md, "| `--mode` | string (one of: it's, a\\|b) | no | \"it's\" | Mode |");
    try contains(md, "| `conflict.pane_busy` | 5 | Pane is busy |");
    try contains(md, "gen-test pane set-title --title 'it'\\''s -here' --sticky=true --json\n# => null");
    try contains(md, "gen-test pane set-title --title=-dash --json");
    try contains(md, "- Streams:");
    try contains(md, "Exit status: on success, `result.status`");
    // Verbs in wire-name order.
    try t.expect(std.mem.indexOf(u8, md, "### `gen-test count`").? < std.mem.indexOf(u8, md, "### `gen-test pane set-title`").?);
}

test "gen: man pages, one per verb plus the overview" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const pages = try cli.docs.manPages(G, arena.allocator());
    try t.expectEqual(G.verbs.len + 1, pages.len);
    try t.expectEqualStrings("gen-test.1", pages[0].name);
    var found = false;
    for (pages) |p| {
        try t.expect(std.mem.startsWith(u8, p.content, ".TH \""));
        // No line may start with a raw control character from user text.
        var lines = std.mem.splitScalar(u8, p.content, '\n');
        while (lines.next()) |line| if (line.len > 0 and line[0] == '\'') return error.TestUnexpectedResult;
        if (std.mem.eql(u8, p.name, "gen-test-pane-set-title.1")) {
            found = true;
            try contains(p.content, ".TH \"GEN-TEST-PANE-SET-TITLE\" \"1\"");
            try contains(p.content, ".B \\-\\-\\&title");
            try contains(p.content, "Error \\&conflict.pane_busy (exit 5)");
        }
    }
    try t.expect(found);
}

test "gen: completions derive the command tree, flags and choices" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    for ([_]cli.completions.Shell{ .bash, .zsh, .fish }) |shell| {
        var out: std.Io.Writer.Allocating = .init(a);
        try cli.completions.write(G, a, &out.writer, shell);
        const script = out.written();
        try contains(script, "'pane.set_title'");
        try contains(script, "'set-title'");
        try contains(script, "'title value' 'mode enum' 'sticky bool'");
        try contains(script, "'json switch' 'socket path' 'help switch'");
        try contains(script, if (shell == .fish) "'it\\'s' 'a|b'" else "'it'\\''s' 'a|b'");
        // Nothing contacts the daemon: no command other than the generated
        // functions and shell builtins is invoked.
        try t.expect(std.mem.indexOf(u8, script, "gen-test ") == null or std.mem.indexOf(u8, script, "gen-test completions") != null);
    }
}

test "gen: SKILL.md front matter, read-only default and notes" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const md = try cli.skill.render(G, arena.allocator(), "Hand-written note.");
    try t.expect(std.mem.startsWith(u8, md, "---\nname: gen-test\ndescription: \"Gen \\\"test\\\" | tool\"\n---\n"));
    try contains(md, "**Read-only by default.**");
    try contains(md, "| `gen-test pane set-title` | `write` | Set a \\*title\\* |");
    try contains(md, "1024 items and 1 MiB");
    try t.expect(std.mem.endsWith(u8, md, "## Notes\n\nHand-written note.\n"));
}

test "gen: skill install writes, no-ops, conflicts, replaces and refuses symlinks" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var tmp = t.tmpDir(.{});
    defer tmp.cleanup();
    var cwd_buf: [4096]u8 = undefined;
    _ = std.c.getcwd(&cwd_buf, cwd_buf.len).?;
    const cwd = std.mem.sliceTo(&cwd_buf, 0);
    const root = try std.fs.path.join(a, &.{ cwd, ".zig-cache/tmp", &tmp.sub_path, "skills" });
    const dir = try std.fs.path.join(a, &.{ root, "gen-test" });
    try t.expect(try cli.skill.install(a, dir, "one", false));
    try t.expect(!try cli.skill.install(a, dir, "one", false));
    try t.expectError(error.Exists, cli.skill.install(a, dir, "two", false));
    try t.expectError(error.Exists, cli.skill.install(a, dir, "on", false));
    try t.expect(try cli.skill.install(a, dir, "two", true));
    const file = try std.fs.path.join(a, &.{ dir, "SKILL.md" });
    const fd = std.c.open(try a.dupeSentinel(u8, file, 0), .{ .ACCMODE = .RDONLY });
    try t.expect(fd >= 0);
    defer _ = std.c.close(fd);
    var buf: [8]u8 = undefined;
    try t.expectEqual(@as(isize, 3), std.c.read(fd, &buf, buf.len));
    try t.expectEqualStrings("two", buf[0..3]);
    // A symlink below the resolved root is refused, not followed.
    const link = try std.fs.path.join(a, &.{ root, "linked" });
    try t.expectEqual(@as(c_int, 0), std.c.symlink(try a.dupeSentinel(u8, dir, 0), try a.dupeSentinel(u8, link, 0)));
    try t.expectError(error.Symlink, cli.skill.install(a, link, "three", true));
}

const Fixed = struct {
    status: cli.doctor.Status,
    pub fn run(self: *Fixed, r: *cli.doctor.Report) anyerror!void {
        try r.add("fixed.check", self.status, "fixed", try r.command("ls -ld -- {s}", "/tmp/a dir"));
    }
};
const Broken = struct {
    pub fn run(_: *Broken, _: *cli.doctor.Report) anyerror!void {
        return error.Boom;
    }
};

test "gen: doctor status, quoted fixes and failing checks" {
    var arena = std.heap.ArenaAllocator.init(t.allocator);
    defer arena.deinit();
    var report: cli.doctor.Report = .{ .arena = arena.allocator(), .tool = "gen-test" };
    var warn: Fixed = .{ .status = .warn };
    var broken: Broken = .{};
    const checks = [_]cli.doctor.Check{ .init("warn", &warn), .init("broken", &broken) };
    try checks[0].vtable.run(checks[0].ptr, &report);
    try t.expectEqual(@as(u8, 0), report.status()); // warnings alone pass
    try t.expectEqualStrings("ls -ld -- '/tmp/a dir'", report.results.items[0].fix);
    var fail: Fixed = .{ .status = .fail };
    try cli.doctor.Check.init("fail", &fail).vtable.run(&fail, &report);
    try t.expectEqual(@as(u8, 1), report.status());
    try t.expectError(error.Boom, checks[1].vtable.run(checks[1].ptr, &report));
}

test "gen: doctor lists process principals only to those who see the whole tree" {
    const g = proto.grants;
    var arena: std.heap.ArenaAllocator = .init(t.allocator);
    defer arena.deinit();
    var reg = try g.Registry.init(t.allocator, "gen-test", .{});
    defer reg.deinit();
    const now = g.nowSeconds();
    const human: g.Identity = .{ .principal = g.owner };
    const bound = try reg.issueChild(human, .{ .kind = .process, .root = (try proto.process.stat(std.c.getpid())).ref, .grants = &.{.{ .right = .read, .scope = "*" }}, .label = "secret-label" }, now);
    defer t.allocator.free(bound.token);
    const narrow = try reg.issueChild(human, .{ .grants = &.{.{ .right = .read, .scope = "agent:nonexistent" }} }, now);
    defer t.allocator.free(narrow.token);
    const wide = try reg.issueChild(human, .{ .grants = &.{.{ .right = .read, .scope = "*" }} }, now);
    defer t.allocator.free(wide.token);
    const admin = try reg.issueChild(human, .{ .grants = &.{.{ .right = .admin, .scope = "*" }} }, now);
    defer t.allocator.free(admin.token);
    for ([_]struct { who: g.Identity, listed: bool }{
        .{ .who = .{}, .listed = false },
        .{ .who = .{ .principal = narrow.principal }, .listed = false },
        .{ .who = .{ .principal = wide.principal }, .listed = false },
        .{ .who = .{ .principal = bound.principal }, .listed = false },
        .{ .who = human, .listed = true },
        .{ .who = .{ .principal = admin.principal }, .listed = true },
    }) |case| {
        var report: cli.doctor.Report = .{ .arena = arena.allocator(), .tool = "gen-test" };
        try cli.doctor.processPrincipals(&report, &reg, case.who, "gen-test");
        try t.expectEqual(case.listed, report.results.items.len == 1);
        if (case.listed) try t.expect(std.mem.indexOf(u8, report.results.items[0].message, "secret-label") != null);
    }
}
