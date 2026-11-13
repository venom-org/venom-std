//! Bash, zsh and fish completions. Each script embeds
//! the same generated tables (command tree, flags per command, enum
//! choices) and a small engine that walks the words already typed. They
//! never contact the daemon, run handlers or complete plain string values;
//! only the global `--socket` completes file names.
const std = @import("std");
const proto = @import("proto");
const docs = @import("docs.zig");
const s = proto.schema;
const W = *std.Io.Writer;
const Allocator = std.mem.Allocator;

pub const Shell = enum { bash, zsh, fish };

/// Flag kinds understood by the engines.
fn kind(t: s.Type) []const u8 {
    return switch (t.kind) {
        .boolean => "bool",
        .string => if (t.choices != null) "enum" else "value",
        else => "value",
    };
}
const globals = "'json switch' 'socket path' 'help switch'";

const Tree = struct {
    /// Every command-tree node by canonical path ("" is the root), with its
    /// child tokens in first-seen (wire-name) order.
    nodes: std.ArrayList(struct { path: []const u8, children: std.ArrayList([]const u8) }) = .empty,

    fn node(self: *Tree, a: Allocator, path: []const u8) !*std.ArrayList([]const u8) {
        for (self.nodes.items) |*n| if (std.mem.eql(u8, n.path, path)) return &n.children;
        try self.nodes.append(a, .{ .path = path, .children = .empty });
        return &self.nodes.items[self.nodes.items.len - 1].children;
    }
    fn child(self: *Tree, a: Allocator, path: []const u8, token: []const u8) !void {
        const children = try self.node(a, path);
        for (children.items) |c| if (std.mem.eql(u8, c, token)) return;
        try children.append(a, token);
    }
    fn build(a: Allocator, verbs: []const s.Verb) !Tree {
        var tree: Tree = .{};
        _ = try tree.node(a, "");
        for (verbs) |v| {
            var buf: std.Io.Writer.Allocating = .init(a);
            try docs.canonical(&buf.writer, v.name);
            const path = buf.written();
            var start: usize = 0;
            while (true) {
                const end = std.mem.indexOfScalarPos(u8, path, start, ' ') orelse path.len;
                try tree.child(a, path[0..if (start == 0) 0 else start - 1], path[start..end]);
                _ = try tree.node(a, path[0..end]);
                if (end == path.len) break;
                start = end + 1;
            }
        }
        // Exact dotted wire spellings are accepted as one root token.
        for (verbs) |v| if (std.mem.indexOfAny(u8, v.name, "._") != null) try tree.child(a, "", v.name);
        return tree;
    }
};

/// Single-quoted word for POSIX sh (`posix`) or fish.
fn quote(w: W, text: []const u8, posix: bool) !void {
    try w.writeByte('\'');
    for (text) |ch| switch (ch) {
        '\'' => try w.writeAll(if (posix) "'\\''" else "\\'"),
        '\\' => try w.writeAll(if (posix) "\\" else "\\\\"),
        else => try w.writeByte(ch),
    };
    try w.writeByte('\'');
}

/// The three table functions, in sh syntax (bash and zsh) or fish syntax.
fn tables(comptime G: type, a: Allocator, w: W, prefix: []const u8, posix: bool) !void {
    const tree = try Tree.build(a, &G.verbs);
    const open_case: []const u8 = if (posix) "    case $1 in\n" else "    switch $argv[1]\n";
    const close_case: []const u8 = if (posix) "    esac\n" else "    end\n";
    const end_fn: []const u8 = if (posix) "}\n" else "end\n";
    const end_arm: []const u8 = if (posix) ";;\n" else "\n";

    try w.print("{s}{s}_children{s}", .{ if (posix) "" else "function ", prefix, if (posix) "() {\n" else "\n" });
    try w.writeAll(open_case);
    for (tree.nodes.items) |n| {
        if (n.children.items.len == 0) continue;
        try w.writeAll(if (posix) "        " else "        case ");
        try quote(w, n.path, posix);
        try w.writeAll(if (posix) ") printf '%s\\n'" else "; printf '%s\\n'");
        for (n.children.items) |c| {
            try w.writeByte(' ');
            try quote(w, c, posix);
        }
        try w.writeAll(end_arm);
    }
    try w.writeAll(close_case);
    try w.writeAll(end_fn);

    try w.print("{s}{s}_flags{s}", .{ if (posix) "" else "function ", prefix, if (posix) "() {\n" else "\n" });
    try w.writeAll(open_case);
    for (G.verbs) |v| {
        if (v.params.len == 0) continue;
        var path: std.Io.Writer.Allocating = .init(a);
        try docs.canonical(&path.writer, v.name);
        try w.writeAll(if (posix) "        " else "        case ");
        try quote(w, path.written(), posix);
        try w.writeAll(if (posix) ") printf '%s\\n'" else "; printf '%s\\n'");
        for (v.params) |p| {
            var entry: std.Io.Writer.Allocating = .init(a);
            try docs.flag(&entry.writer, p.name);
            try entry.writer.print(" {s}", .{kind(p.type)});
            try w.writeByte(' ');
            try quote(w, entry.written(), posix);
        }
        try w.writeAll(end_arm);
    }
    try w.writeAll(close_case);
    try w.print("    printf '%s\\n' {s}\n", .{globals});
    try w.writeAll(end_fn);

    try w.print("{s}{s}_choices{s}", .{ if (posix) "" else "function ", prefix, if (posix) "() {\n    case $1/$2 in\n" else "\n    switch \"$argv[1]/$argv[2]\"\n" });
    for (G.verbs) |v| for (v.params) |p| if (p.type.choices) |choices| {
        var key: std.Io.Writer.Allocating = .init(a);
        try docs.canonical(&key.writer, v.name);
        try key.writer.writeByte('/');
        try docs.flag(&key.writer, p.name);
        try w.writeAll(if (posix) "        " else "        case ");
        try quote(w, key.written(), posix);
        try w.writeAll(if (posix) ") printf '%s\\n'" else "; printf '%s\\n'");
        for (choices) |c| {
            try w.writeByte(' ');
            try quote(w, c, posix);
        }
        try w.writeAll(end_arm);
    };
    try w.writeAll(close_case);
    try w.writeAll(end_fn);
}

/// Shared sh engine pieces: kind lookup and the word walk. `$words_expr`
/// is the shell's array of completed words after the command name.
fn posixWalk(w: W, prefix: []const u8, words_expr: []const u8) !void {
    try w.print(
        \\    local node= expect= used=' ' word name k
        \\    for word in {1s}; do
        \\        if [[ -n $expect ]]; then expect=; continue; fi
        \\        case $word in
        \\            --) return 0 ;;
        \\            --*=*) used+="${{word%%=*}} " ;;
        \\            --*)
        \\                used+="$word "
        \\                k=$({0s}_kind "$node" "${{word#--}}")
        \\                [[ $k == value || $k == enum || $k == path ]] && expect=${{word#--}} ;;
        \\            -*) return 0 ;;
        \\            *) word=${{word//./ }}; word=${{word//_/-}}; node=${{node:+$node }}$word ;;
        \\        esac
        \\    done
        \\
    , .{ prefix, words_expr });
}
fn posixKind(w: W, prefix: []const u8) !void {
    try w.print(
        \\{0s}_kind() {{
        \\    local n k
        \\    while read -r n k; do [[ $n == "$2" ]] && {{ printf '%s\n' "$k"; return; }}; done < <({0s}_flags "$1")
        \\}}
        \\
    , .{prefix});
}

fn writeBash(comptime G: type, a: Allocator, w: W, prefix: []const u8) !void {
    try w.print("# bash completion for {s}; generated from its verb schema.\n# Load with: source <({s} completions --shell bash)\n", .{ G.schema.tool, G.schema.tool });
    try tables(G, a, w, prefix, true);
    try posixKind(w, prefix);
    try w.print(
        \\{0s}() {{
        \\    local line=${{COMP_LINE:0:COMP_POINT}} cur= c v
        \\    local -a words cands=()
        \\    read -ra words <<< "$line"
        \\    if [[ -n $line && $line != *[[:space:]] ]]; then cur=${{words[-1]}}; unset 'words[-1]'; fi
        \\
    , .{prefix});
    try posixWalk(w, prefix, "\"${words[@]:1}\"");
    try w.print(
        \\    COMPREPLY=()
        \\    if [[ -n $expect ]]; then
        \\        k=$({0s}_kind "$node" "$expect")
        \\        [[ $k == path ]] && {{ COMPREPLY=($(compgen -f -- "$cur")); return 0; }}
        \\        [[ $k == enum ]] && mapfile -t cands < <({0s}_choices "$node" "$expect")
        \\    elif [[ $cur == --*=* ]]; then
        \\        name=${{cur%%=*}}; name=${{name#--}}; v=${{cur#*=}}
        \\        k=$({0s}_kind "$node" "$name")
        \\        [[ $k == path ]] && {{ COMPREPLY=($(compgen -f -- "$v")); return 0; }}
        \\        [[ $k == enum ]] && mapfile -t cands < <({0s}_choices "$node" "$name")
        \\        [[ $k == bool ]] && cands=(true false)
        \\        # Bash splits words at '=' by default; complete only the value then.
        \\        if [[ $COMP_WORDBREAKS != *=* ]]; then for c in "${{!cands[@]}}"; do cands[c]="--$name=${{cands[c]}}"; done; else cur=$v; fi
        \\    elif [[ $cur == -* ]]; then
        \\        while read -r name k; do
        \\            [[ $used == *" --$name "* ]] && continue
        \\            if [[ $k == bool ]]; then cands+=("--$name=true" "--$name=false"); else cands+=("--$name"); fi
        \\        done < <({0s}_flags "$node")
        \\    else
        \\        mapfile -t cands < <({0s}_children "$node")
        \\    fi
        \\    for c in "${{cands[@]}}"; do [[ $c == "$cur"* ]] && COMPREPLY+=("$c"); done
        \\    return 0
        \\}}
        \\complete -F {0s} {1s}
        \\
    , .{ prefix, G.schema.tool });
}

fn writeZsh(comptime G: type, a: Allocator, w: W, prefix: []const u8) !void {
    try w.print("#compdef {s}\n# zsh completion for {s}; generated from its verb schema.\n# Load with: source <({s} completions --shell zsh), or save as _{s} in $fpath.\n", .{ G.schema.tool, G.schema.tool, G.schema.tool, G.schema.tool });
    try tables(G, a, w, prefix, true);
    try posixKind(w, prefix);
    try w.print(
        \\{0s}() {{
        \\    local cur=${{words[CURRENT]}} v
        \\    local -a cands
        \\
    , .{prefix});
    try posixWalk(w, prefix, "\"${(@)words[2,CURRENT-1]}\"");
    try w.print(
        \\    if [[ -n $expect ]]; then
        \\        k=$({0s}_kind "$node" "$expect")
        \\        [[ $k == path ]] && {{ _files; return; }}
        \\        [[ $k == enum ]] && cands=("${{(@f)$({0s}_choices "$node" "$expect")}}") && compadd -Q -a cands
        \\    elif [[ $cur == --*=* ]]; then
        \\        name=${{cur%%=*}}; name=${{name#--}}
        \\        k=$({0s}_kind "$node" "$name")
        \\        compset -P '*='
        \\        [[ $k == path ]] && {{ _files; return; }}
        \\        [[ $k == enum ]] && cands=("${{(@f)$({0s}_choices "$node" "$name")}}")
        \\        [[ $k == bool ]] && cands=(true false)
        \\        (( $#cands )) && compadd -Q -a cands
        \\    elif [[ $cur == -* ]]; then
        \\        while read -r name k; do
        \\            [[ $used == *" --$name "* ]] && continue
        \\            if [[ $k == bool ]]; then cands+=("--$name=true" "--$name=false"); else cands+=("--$name"); fi
        \\        done < <({0s}_flags "$node")
        \\        compadd -Q -a cands
        \\    else
        \\        cands=("${{(@f)$({0s}_children "$node")}}")
        \\        (( $#cands )) && [[ -n ${{cands[1]}} ]] && compadd -Q -a cands
        \\    fi
        \\}}
        \\if [[ ${{funcstack[1]}} == {0s} ]]; then {0s} "$@"; else compdef {0s} {1s}; fi
        \\
    , .{ prefix, G.schema.tool });
}

fn writeFish(comptime G: type, a: Allocator, w: W, prefix: []const u8) !void {
    try w.print("# fish completion for {s}; generated from its verb schema.\n# Load with: {s} completions --shell fish | source\n", .{ G.schema.tool, G.schema.tool });
    try tables(G, a, w, prefix, false);
    try w.print(
        \\function {0s}_kind
        \\    for line in ({0s}_flags $argv[1])
        \\        set -l parts (string split ' ' -- $line)
        \\        if test "$parts[1]" = "$argv[2]"
        \\            echo $parts[2]
        \\            return
        \\        end
        \\    end
        \\end
        \\function {0s}_complete
        \\    set -l tokens (commandline -opc)
        \\    set -l cur (commandline -ct)
        \\    set -l node ''
        \\    set -l expect ''
        \\    set -l used
        \\    for word in $tokens[2..-1]
        \\        if test -n "$expect"
        \\            set expect ''
        \\            continue
        \\        end
        \\        switch $word
        \\            case --
        \\                return
        \\            case '--*=*'
        \\                set -a used (string split -m1 = -- $word)[1]
        \\            case '--*'
        \\                set -a used $word
        \\                set -l k ({0s}_kind "$node" (string sub -s 3 -- $word))
        \\                if contains -- "$k" value enum path
        \\                    set expect (string sub -s 3 -- $word)
        \\                end
        \\            case '-*'
        \\                return
        \\            case '*'
        \\                set word (string replace -a . ' ' -- $word | string replace -a _ -)
        \\                if test -z "$node"
        \\                    set node $word
        \\                else
        \\                    set node "$node $word"
        \\                end
        \\        end
        \\    end
        \\    if test -n "$expect"
        \\        switch ({0s}_kind "$node" "$expect")
        \\            case path
        \\                __fish_complete_path $cur
        \\            case enum
        \\                {0s}_choices "$node" "$expect"
        \\        end
        \\    else if string match -q -- '--*=*' $cur
        \\        set -l name (string split -m1 = -- $cur)[1]
        \\        set -l value (string split -m1 = -- $cur)[2]
        \\        switch ({0s}_kind "$node" (string sub -s 3 -- $name))
        \\            case path
        \\                for p in (__fish_complete_path $value)
        \\                    echo "$name=$p"
        \\                end
        \\            case enum
        \\                for c in ({0s}_choices "$node" (string sub -s 3 -- $name))
        \\                    echo "$name=$c"
        \\                end
        \\            case bool
        \\                echo "$name=true"
        \\                echo "$name=false"
        \\        end
        \\    else if string match -q -- '-*' $cur
        \\        for line in ({0s}_flags "$node")
        \\            set -l parts (string split ' ' -- $line)
        \\            contains -- "--$parts[1]" $used; and continue
        \\            if test "$parts[2]" = bool
        \\                echo "--$parts[1]=true"
        \\                echo "--$parts[1]=false"
        \\            else
        \\                echo "--$parts[1]"
        \\            end
        \\        end
        \\    else
        \\        {0s}_children "$node"
        \\    end
        \\end
        \\complete -c {1s} -f -a '({0s}_complete)'
        \\
    , .{ prefix, G.schema.tool });
}

/// The completion script for `shell`. Allocations belong to `a` (an arena).
pub fn write(comptime G: type, a: Allocator, w: W, shell: Shell) !void {
    var buf: [48]u8 = undefined;
    const prefix = blk: {
        var fixed = std.Io.Writer.fixed(&buf);
        try fixed.writeAll(if (shell == .fish) "__" else "_");
        for (G.schema.tool) |ch| try fixed.writeByte(if (ch == '-') '_' else ch);
        break :blk fixed.buffered();
    };
    switch (shell) {
        .bash => try writeBash(G, a, w, prefix),
        .zsh => try writeZsh(G, a, w, prefix),
        .fish => try writeFish(G, a, w, prefix),
    }
}
