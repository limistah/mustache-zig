const std = @import("std");
const ast = @import("ast.zig");
const escape = @import("escape.zig");
const Value = @import("value.zig").Value;
const Writer = std.Io.Writer;

// The renderer operates only on Value. The earlier comptime/struct path was
// removed because it caused combinatorial monomorphization on every distinct
// context type, making compile time and memory unbounded. Convert structs to
// Value via Value adapters before rendering.

pub const RenderError = Writer.Error;

// Lexical context stack as a singly-linked list of frames living on the
// renderer's call stack. No heap allocations during render; nesting depth is
// bounded by the host's stack size.
const Frame = struct {
    value: Value,
    parent: ?*const Frame,
};

pub fn render(template: ast.Template, writer: *Writer, value: Value) RenderError!void {
    const top = Frame{ .value = value, .parent = null };
    return renderNodes(template.nodes, writer, &top);
}

fn renderNodes(nodes: []const ast.Node, w: *Writer, top: *const Frame) RenderError!void {
    for (nodes) |node| {
        switch (node) {
            .text => |t| try w.writeAll(t),
            .variable => |v| try writeVariable(w, top, v.path, v.escape),
            .section => |s| try renderSection(w, top, s, false),
            .inverted => |s| try renderSection(w, top, s, true),
        }
    }
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
    // missing -> emit nothing (spec)
}

// Walk frames innermost -> outermost looking for `path[0]`. Once a frame
// containing it is found, commit to that resolution path: subsequent
// segments only descend into the resolved object, no stack fallback.
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

fn renderSection(w: *Writer, top: *const Frame, section: ast.Node.Section, inverted: bool) RenderError!void {
    const resolved: ?Value = if (isImplicitDot(section.path)) top.value else lookupPath(top, section.path);

    if (inverted) {
        const v: Value = resolved orelse .null;
        if (isFalsy(v)) try renderNodes(section.body, w, top);
        return;
    }

    if (resolved) |v| try dispatchSection(w, top, v, section.body);
}

fn dispatchSection(w: *Writer, top: *const Frame, value: Value, body: []const ast.Node) RenderError!void {
    switch (value) {
        .null => {},
        .bool => |b| if (b) try renderNodes(body, w, top),
        .int => |i| if (i != 0) {
            const f = Frame{ .value = value, .parent = top };
            try renderNodes(body, w, &f);
        },
        .float => |fv| if (fv != 0) {
            const f = Frame{ .value = value, .parent = top };
            try renderNodes(body, w, &f);
        },
        .string => |s| if (s.len > 0) {
            const f = Frame{ .value = value, .parent = top };
            try renderNodes(body, w, &f);
        },
        .list => |xs| {
            for (xs) |item| {
                const f = Frame{ .value = item, .parent = top };
                try renderNodes(body, w, &f);
            }
        },
        .object => {
            const f = Frame{ .value = value, .parent = top };
            try renderNodes(body, w, &f);
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

// ----- value writer -----

fn writeValue(w: *Writer, value: Value, do_escape: bool) RenderError!void {
    switch (value) {
        .null => {},
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .int => |i| try w.print("{d}", .{i}),
        .float => |f| try w.print("{d}", .{f}),
        .string => |s| if (do_escape) try escape.html(w, s) else try w.writeAll(s),
        // Writing list/object as a leaf is unspecified; emit nothing.
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
