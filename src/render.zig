const std = @import("std");
const ast = @import("ast.zig");
const escape = @import("escape.zig");
const Value = @import("value.zig").Value;
const Writer = std.Io.Writer;

pub const RenderError = Writer.Error;

/// Pre-parsed partials, keyed by name. Caller owns the templates.
pub const Partials = std.StringHashMap(ast.Template);

const Frame = struct {
    value: Value,
    parent: ?*const Frame,
};

pub fn render(template: ast.Template, writer: *Writer, value: Value) RenderError!void {
    return renderImpl(template, writer, value, null);
}

pub fn renderWithPartials(
    template: ast.Template,
    writer: *Writer,
    value: Value,
    partials: *const Partials,
) RenderError!void {
    return renderImpl(template, writer, value, partials);
}

fn renderImpl(
    template: ast.Template,
    writer: *Writer,
    value: Value,
    partials: ?*const Partials,
) RenderError!void {
    const top = Frame{ .value = value, .parent = null };
    return renderNodes(template.nodes, writer, &top, partials, null, null);
}

// When `indent` is non-null, the renderer is inside a partial that needs its
// indent string prepended at the start of every structural line. The spec
// requires that indent applies only to the partial source's *text*; multi-
// line expansions from variables/sections are not re-indented per line.
const IndentState = struct {
    indent: []const u8,
    at_line_start: bool,
};

// Stack of block-override frames for inheritance (Mustache 1.4). Each
// {{<parent}}...{{/parent}} invocation pushes a new frame holding the
// {{$name}} blocks collected from its body. Lookup walks the chain
// OUTERMOST first — the original caller's overrides take precedence over
// any added by intermediate parent templates ("Multi-level inheritance"
// test in the spec).
const OverrideFrame = struct {
    blocks: []const ast.Node.Block,
    parent: ?*const OverrideFrame,

    fn lookup(self: ?*const OverrideFrame, name: []const u8) ?[]const ast.Node {
        var result: ?[]const ast.Node = null;
        var cur: ?*const OverrideFrame = self;
        while (cur) |f| : (cur = f.parent) {
            for (f.blocks) |b| {
                if (std.mem.eql(u8, b.name, name)) {
                    result = b.body;
                    break;
                }
            }
        }
        return result;
    }
};

fn renderNodes(
    nodes: []const ast.Node,
    w: *Writer,
    top: *const Frame,
    partials: ?*const Partials,
    ind: ?*IndentState,
    overrides: ?*const OverrideFrame,
) RenderError!void {
    for (nodes) |node| {
        switch (node) {
            .text => |t| try writeTextMaybeIndented(w, t, ind),
            .variable => |v| {
                try writeIndentIfStart(w, ind);
                try writeVariable(w, top, v.path, v.escape);
            },
            .section => |s| {
                try writeIndentIfStart(w, ind);
                try renderSection(w, top, s, false, partials, ind, overrides);
            },
            .inverted => |s| {
                try writeIndentIfStart(w, ind);
                try renderSection(w, top, s, true, partials, ind, overrides);
            },
            .partial => |p| {
                try writeIndentIfStart(w, ind);
                try renderPartial(w, top, p, partials, overrides);
            },
            .block => |b| {
                // Bare {{$name}} default-or-overridden render. Indent is
                // applied at the start (writeIndentIfStart) but the body
                // itself is rendered without inherited indent (default or
                // override content is treated as a fresh scope per spec).
                try writeIndentIfStart(w, ind);
                const body = OverrideFrame.lookup(overrides, b.name) orelse b.body;
                try renderNodes(body, w, top, partials, ind, overrides);
            },
            .parent => |pi| {
                try writeIndentIfStart(w, ind);
                try renderParentInvocation(w, top, pi, partials, overrides);
            },
        }
    }
}

fn writeIndentIfStart(w: *Writer, ind: ?*IndentState) RenderError!void {
    if (ind) |s| {
        if (s.at_line_start) {
            try w.writeAll(s.indent);
            s.at_line_start = false;
        }
    }
}

fn writeTextMaybeIndented(w: *Writer, text: []const u8, ind: ?*IndentState) RenderError!void {
    const s = ind orelse return w.writeAll(text);
    var start: usize = 0;
    for (text, 0..) |b, i| {
        if (s.at_line_start) {
            if (b != '\n') try w.writeAll(s.indent);
            s.at_line_start = false;
        }
        if (b == '\n') {
            try w.writeAll(text[start .. i + 1]);
            start = i + 1;
            s.at_line_start = true;
        }
    }
    if (start < text.len) try w.writeAll(text[start..]);
}

fn isImplicitDot(path: []const []const u8) bool {
    return path.len == 1 and path[0].len == 1 and path[0][0] == '.';
}

// ----- variable -----

fn writeVariable(w: *Writer, top: *const Frame, path: []const []const u8, do_escape: bool) RenderError!void {
    if (isImplicitDot(path)) return writeValue(w, top.value, do_escape);
    if (lookupPath(top, path)) |resolved| {
        try writeValue(w, resolved, do_escape);
    }
}

fn lookupPath(top: *const Frame, path: []const []const u8) ?Value {
    var cur: ?*const Frame = top;
    while (cur) |frame| : (cur = frame.parent) {
        if (frame.value == .object) {
            for (frame.value.object) |f| {
                if (std.mem.eql(u8, f.key, path[0])) {
                    return descend(f.value, path[1..]);
                }
            }
        }
    }
    return null;
}

fn descend(value: Value, rest: []const []const u8) ?Value {
    if (rest.len == 0) return value;
    if (value != .object) return null;
    for (value.object) |f| {
        if (std.mem.eql(u8, f.key, rest[0])) {
            return descend(f.value, rest[1..]);
        }
    }
    return null;
}

// ----- section -----

fn renderSection(
    w: *Writer,
    top: *const Frame,
    section: ast.Node.Section,
    inverted: bool,
    partials: ?*const Partials,
    ind: ?*IndentState,
    overrides: ?*const OverrideFrame,
) RenderError!void {
    const resolved: ?Value = if (isImplicitDot(section.path)) top.value else lookupPath(top, section.path);

    if (inverted) {
        const v: Value = resolved orelse .null;
        if (isFalsy(v)) try renderNodes(section.body, w, top, partials, ind, overrides);
        return;
    }

    if (resolved) |v| try dispatchSection(w, top, v, section.body, partials, ind, overrides);
}

fn dispatchSection(
    w: *Writer,
    top: *const Frame,
    value: Value,
    body: []const ast.Node,
    partials: ?*const Partials,
    ind: ?*IndentState,
    overrides: ?*const OverrideFrame,
) RenderError!void {
    switch (value) {
        .null => {},
        .bool => |b| if (b) try renderNodes(body, w, top, partials, ind, overrides),
        .int => |i| if (i != 0) {
            const f = Frame{ .value = value, .parent = top };
            try renderNodes(body, w, &f, partials, ind, overrides);
        },
        .float => |fv| if (fv != 0) {
            const f = Frame{ .value = value, .parent = top };
            try renderNodes(body, w, &f, partials, ind, overrides);
        },
        .string => |s| if (s.len > 0) {
            const f = Frame{ .value = value, .parent = top };
            try renderNodes(body, w, &f, partials, ind, overrides);
        },
        .list => |xs| {
            for (xs) |item| {
                const f = Frame{ .value = item, .parent = top };
                try renderNodes(body, w, &f, partials, ind, overrides);
            }
        },
        .object => {
            const f = Frame{ .value = value, .parent = top };
            try renderNodes(body, w, &f, partials, ind, overrides);
        },
    }
}

fn isFalsy(v: Value) bool {
    return switch (v) {
        .null => true,
        .bool => |b| !b,
        .int => |i| i == 0,
        .float => |f| f == 0,
        .string => |s| s.len == 0,
        .list => |xs| xs.len == 0,
        .object => false,
    };
}

// ----- partial -----

fn renderPartial(
    w: *Writer,
    top: *const Frame,
    p: ast.Node.Partial,
    partials: ?*const Partials,
    overrides: ?*const OverrideFrame,
) RenderError!void {
    const map = partials orelse return;

    const name: []const u8 = if (p.dynamic) blk: {
        const resolved = lookupPath(top, p.path) orelse return;
        if (resolved != .string) return;
        break :blk resolved.string;
    } else p.name;

    const tmpl = map.get(name) orelse return;

    if (p.indent.len == 0) {
        return renderNodes(tmpl.nodes, w, top, partials, null, overrides);
    }

    var state = IndentState{ .indent = p.indent, .at_line_start = true };
    return renderNodes(tmpl.nodes, w, top, partials, &state, overrides);
}

fn renderParentInvocation(
    w: *Writer,
    top: *const Frame,
    pi: ast.Node.ParentInvocation,
    partials: ?*const Partials,
    overrides: ?*const OverrideFrame,
) RenderError!void {
    const map = partials orelse return;
    const tmpl = map.get(pi.name) orelse return;

    const frame = OverrideFrame{ .blocks = pi.overrides, .parent = overrides };

    if (pi.indent.len == 0) {
        return renderNodes(tmpl.nodes, w, top, partials, null, &frame);
    }

    var state = IndentState{ .indent = pi.indent, .at_line_start = true };
    return renderNodes(tmpl.nodes, w, top, partials, &state, &frame);
}

// ----- value writer -----

fn writeValue(w: *Writer, value: Value, do_escape: bool) RenderError!void {
    switch (value) {
        .null => {},
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .int => |i| try w.print("{d}", .{i}),
        .float => |f| try w.print("{d}", .{f}),
        .string => |s| if (do_escape) try escape.html(w, s) else try w.writeAll(s),
        .list, .object => {},
    }
}

// ----- tests -----

const parser = @import("parser.zig");
const testing = std.testing;

fn renderToBuf(comptime cap: usize, source: []const u8, value: Value) ![]u8 {
    var buf: [cap]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    var t = try parser.parse(testing.allocator, source);
    defer t.deinit();
    try render(t, &w, value);
    return testing.allocator.dupe(u8, w.buffered());
}

test "variable: writes a string" {
    const fs = [_]Value.Field{.{ .key = "name", .value = .{ .string = "Aleem" } }};
    const got = try renderToBuf(64, "Hello, {{name}}!", .{ .object = &fs });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("Hello, Aleem!", got);
}

test "variable: escapes HTML by default; triple is raw" {
    const fs = [_]Value.Field{.{ .key = "x", .value = .{ .string = "<&>" } }};
    const got = try renderToBuf(64, "{{x}} {{{x}}}", .{ .object = &fs });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("&lt;&amp;&gt; <&>", got);
}

test "variable: missing renders empty" {
    const fs = [_]Value.Field{.{ .key = "other", .value = .{ .string = "x" } }};
    const got = try renderToBuf(64, "[{{nope}}]", .{ .object = &fs });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("[]", got);
}

test "variable: dotted path through nested objects" {
    const inner = [_]Value.Field{.{ .key = "city", .value = .{ .string = "Lagos" } }};
    const middle = [_]Value.Field{.{ .key = "address", .value = .{ .object = &inner } }};
    const outer = [_]Value.Field{.{ .key = "user", .value = .{ .object = &middle } }};
    const got = try renderToBuf(64, "{{user.address.city}}", .{ .object = &outer });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("Lagos", got);
}

test "variable: int and bool" {
    const fields = [_]Value.Field{
        .{ .key = "n", .value = .{ .int = 42 } },
        .{ .key = "b", .value = .{ .bool = true } },
    };
    const got = try renderToBuf(64, "{{n}}/{{b}}", .{ .object = &fields });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("42/true", got);
}

test "section: bool true renders body" {
    const fs = [_]Value.Field{.{ .key = "ok", .value = .{ .bool = true } }};
    const got = try renderToBuf(64, "{{#ok}}yes{{/ok}}", .{ .object = &fs });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("yes", got);
}

test "section: bool false skips" {
    const fs = [_]Value.Field{.{ .key = "ok", .value = .{ .bool = false } }};
    const got = try renderToBuf(64, "[{{#ok}}yes{{/ok}}]", .{ .object = &fs });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("[]", got);
}

test "inverted: false renders body" {
    const fs = [_]Value.Field{.{ .key = "ok", .value = .{ .bool = false } }};
    const got = try renderToBuf(64, "{{^ok}}no{{/ok}}", .{ .object = &fs });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("no", got);
}

test "inverted: missing name renders body" {
    const fs = [_]Value.Field{.{ .key = "other", .value = .{ .bool = true } }};
    const got = try renderToBuf(64, "{{^absent}}none{{/absent}}", .{ .object = &fs });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("none", got);
}

test "section: list iterates with implicit ." {
    const items = [_]Value{ .{ .string = "a" }, .{ .string = "b" }, .{ .string = "c" } };
    const fs = [_]Value.Field{.{ .key = "xs", .value = .{ .list = &items } }};
    const got = try renderToBuf(64, "{{#xs}}[{{.}}]{{/xs}}", .{ .object = &fs });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("[a][b][c]", got);
}

test "section: list of objects with parent-scope fallback" {
    const item1 = [_]Value.Field{.{ .key = "label", .value = .{ .string = "x" } }};
    const item2 = [_]Value.Field{.{ .key = "label", .value = .{ .string = "y" } }};
    const items = [_]Value{ .{ .object = &item1 }, .{ .object = &item2 } };
    const root = [_]Value.Field{
        .{ .key = "prefix", .value = .{ .string = "p" } },
        .{ .key = "items", .value = .{ .list = &items } },
    };
    const got = try renderToBuf(128, "{{#items}}{{prefix}}-{{label}};{{/items}}", .{ .object = &root });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("p-x;p-y;", got);
}

test "section: empty list is falsy" {
    const empty = [_]Value{};
    const root = [_]Value.Field{.{ .key = "xs", .value = .{ .list = &empty } }};
    const got = try renderToBuf(64, "{{#xs}}skip{{/xs}}{{^xs}}empty{{/xs}}", .{ .object = &root });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("empty", got);
}

test "section: object pushes scope" {
    const user = [_]Value.Field{.{ .key = "name", .value = .{ .string = "Aleem" } }};
    const root = [_]Value.Field{.{ .key = "user", .value = .{ .object = &user } }};
    const got = try renderToBuf(64, "{{#user}}{{name}}{{/user}}", .{ .object = &root });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("Aleem", got);
}

test "standalone tags don't leak newlines" {
    const fs = [_]Value.Field{.{ .key = "ok", .value = .{ .bool = true } }};
    const got = try renderToBuf(64, "{{#ok}}\nhi\n{{/ok}}\n", .{ .object = &fs });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("hi\n", got);
}

test "deeply nested sections" {
    const c = [_]Value.Field{.{ .key = "c", .value = .{ .string = "found" } }};
    const b = [_]Value.Field{.{ .key = "b", .value = .{ .object = &c } }};
    const a = [_]Value.Field{.{ .key = "a", .value = .{ .object = &b } }};
    const got = try renderToBuf(64, "{{#a}}{{#b}}{{c}}{{/b}}{{/a}}", .{ .object = &a });
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("found", got);
}

// ----- partials -----

test "partial: inlines named partial content" {
    var ptmpl = try parser.parse(testing.allocator, "[{{name}}]");
    defer ptmpl.deinit();

    var partials = Partials.init(testing.allocator);
    defer partials.deinit();
    try partials.put("greeting", ptmpl);

    const fs = [_]Value.Field{.{ .key = "name", .value = .{ .string = "Aleem" } }};
    var t = try parser.parse(testing.allocator, "Hi {{>greeting}}!");
    defer t.deinit();

    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try renderWithPartials(t, &w, .{ .object = &fs }, &partials);
    try testing.expectEqualStrings("Hi [Aleem]!", w.buffered());
}

test "partial: missing partial renders nothing" {
    var partials = Partials.init(testing.allocator);
    defer partials.deinit();

    var t = try parser.parse(testing.allocator, "a{{>nope}}b");
    defer t.deinit();

    var buf: [64]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try renderWithPartials(t, &w, .null, &partials);
    try testing.expectEqualStrings("ab", w.buffered());
}

test "partial: standalone indent is prepended to every partial line" {
    var ptmpl = try parser.parse(testing.allocator, "line1\nline2");
    defer ptmpl.deinit();

    var partials = Partials.init(testing.allocator);
    defer partials.deinit();
    try partials.put("p", ptmpl);

    var t = try parser.parse(testing.allocator, "  {{>p}}\n");
    defer t.deinit();

    var buf: [128]u8 = undefined;
    var w = std.Io.Writer.fixed(&buf);
    try renderWithPartials(t, &w, .null, &partials);
    try testing.expectEqualStrings("  line1\n  line2", w.buffered());
}
