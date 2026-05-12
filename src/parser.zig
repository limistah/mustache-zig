const std = @import("std");
const ast = @import("ast.zig");

pub const ParseError = error{
    UnclosedTag,
    EmptyTag,
    UnclosedSection,
    UnexpectedClose,
    MismatchedClose,
} || std.mem.Allocator.Error;

pub fn parse(allocator: std.mem.Allocator, source: []const u8) ParseError!ast.Template {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aalloc = arena.allocator();

    const owned = try aalloc.dupe(u8, source);

    var cursor: usize = 0;
    const nodes = try parseSegment(aalloc, owned, &cursor, null);

    return .{ .nodes = nodes, .arena = arena };
}

fn buildPath(aalloc: std.mem.Allocator, raw: []const u8) ParseError![]const []const u8 {
    if (raw.len == 1 and raw[0] == '.') {
        const out = try aalloc.alloc([]const u8, 1);
        out[0] = raw;
        return out;
    }
    var list: std.ArrayListUnmanaged([]const u8) = .{};
    var it = std.mem.splitScalar(u8, raw, '.');
    while (it.next()) |seg| {
        if (seg.len == 0) return error.EmptyTag;
        try list.append(aalloc, seg);
    }
    return try list.toOwnedSlice(aalloc);
}

fn parseSegment(
    aalloc: std.mem.Allocator,
    source: []const u8,
    cursor: *usize,
    end_section: ?[]const u8,
) ParseError![]ast.Node {
    var nodes: std.ArrayListUnmanaged(ast.Node) = .{};
    var text_start = cursor.*;

    while (cursor.* < source.len) {
        const i = cursor.*;
        if (i + 1 < source.len and source[i] == '{' and source[i + 1] == '{') {
            if (i > text_start) {
                try nodes.append(aalloc, .{ .text = source[text_start..i] });
            }

            const after_open = i + 2;
            const triple = after_open < source.len and source[after_open] == '{';
            const tag_start = if (triple) after_open + 1 else after_open;
            const close_seq: []const u8 = if (triple) "}}}" else "}}";

            const close_idx = std.mem.indexOfPos(u8, source, tag_start, close_seq) orelse
                return error.UnclosedTag;

            const inner = std.mem.trim(u8, source[tag_start..close_idx], " \t");
            if (inner.len == 0) return error.EmptyTag;

            cursor.* = close_idx + close_seq.len;
            text_start = cursor.*;

            const sigil = inner[0];
            switch (sigil) {
                '!' => {
                    // comment: discard
                },
                '#', '^' => {
                    const raw = std.mem.trim(u8, inner[1..], " \t");
                    if (raw.len == 0) return error.EmptyTag;
                    const path = try buildPath(aalloc, raw);
                    const body = try parseSegment(aalloc, source, cursor, raw);
                    const section = ast.Node.Section{ .path = path, .body = body };
                    try nodes.append(aalloc, if (sigil == '#')
                        .{ .section = section }
                    else
                        .{ .inverted = section });
                    text_start = cursor.*;
                },
                '/' => {
                    const name = std.mem.trim(u8, inner[1..], " \t");
                    if (end_section == null) return error.UnexpectedClose;
                    if (!std.mem.eql(u8, name, end_section.?)) return error.MismatchedClose;
                    return try nodes.toOwnedSlice(aalloc);
                },
                '&' => {
                    if (triple) return error.EmptyTag;
                    const raw = std.mem.trim(u8, inner[1..], " \t");
                    if (raw.len == 0) return error.EmptyTag;
                    const path = try buildPath(aalloc, raw);
                    try nodes.append(aalloc, .{ .variable = .{ .path = path, .escape = false } });
                },
                else => {
                    const path = try buildPath(aalloc, inner);
                    try nodes.append(aalloc, .{ .variable = .{ .path = path, .escape = !triple } });
                },
            }
        } else {
            cursor.* += 1;
        }
    }
    if (end_section != null) return error.UnclosedSection;
    if (text_start < source.len) {
        try nodes.append(aalloc, .{ .text = source[text_start..] });
    }
    return try nodes.toOwnedSlice(aalloc);
}

test "parses a simple variable" {
    var t = try parse(std.testing.allocator, "Hi {{name}}!");
    defer t.deinit();
    try std.testing.expectEqual(@as(usize, 3), t.nodes.len);
    try std.testing.expectEqualStrings("name", t.nodes[1].variable.path[0]);
    try std.testing.expectEqual(@as(usize, 1), t.nodes[1].variable.path.len);
    try std.testing.expectEqual(true, t.nodes[1].variable.escape);
}

test "parses a dotted variable into path segments" {
    var t = try parse(std.testing.allocator, "{{user.address.city}}");
    defer t.deinit();
    const p = t.nodes[0].variable.path;
    try std.testing.expectEqual(@as(usize, 3), p.len);
    try std.testing.expectEqualStrings("user", p[0]);
    try std.testing.expectEqualStrings("address", p[1]);
    try std.testing.expectEqualStrings("city", p[2]);
}

test "implicit dot is a single-segment path" {
    var t = try parse(std.testing.allocator, "{{.}}");
    defer t.deinit();
    const p = t.nodes[0].variable.path;
    try std.testing.expectEqual(@as(usize, 1), p.len);
    try std.testing.expectEqualStrings(".", p[0]);
}

test "empty segment in dotted path is an error" {
    try std.testing.expectError(error.EmptyTag, parse(std.testing.allocator, "{{a..b}}"));
}

test "parses triple-stache as unescaped" {
    var t = try parse(std.testing.allocator, "{{{raw}}}");
    defer t.deinit();
    try std.testing.expectEqualStrings("raw", t.nodes[0].variable.path[0]);
    try std.testing.expectEqual(false, t.nodes[0].variable.escape);
}

test "parses ampersand as unescaped" {
    var t = try parse(std.testing.allocator, "{{& raw }}");
    defer t.deinit();
    try std.testing.expectEqualStrings("raw", t.nodes[0].variable.path[0]);
    try std.testing.expectEqual(false, t.nodes[0].variable.escape);
}

test "parses a section" {
    var t = try parse(std.testing.allocator, "{{#items}}body{{/items}}");
    defer t.deinit();
    try std.testing.expectEqualStrings("items", t.nodes[0].section.path[0]);
    try std.testing.expectEqualStrings("body", t.nodes[0].section.body[0].text);
}

test "parses a dotted section" {
    var t = try parse(std.testing.allocator, "{{#user.address}}x{{/user.address}}");
    defer t.deinit();
    const p = t.nodes[0].section.path;
    try std.testing.expectEqual(@as(usize, 2), p.len);
    try std.testing.expectEqualStrings("user", p[0]);
    try std.testing.expectEqualStrings("address", p[1]);
}

test "parses an inverted section" {
    var t = try parse(std.testing.allocator, "{{^empty}}nothing{{/empty}}");
    defer t.deinit();
    try std.testing.expectEqualStrings("empty", t.nodes[0].inverted.path[0]);
}

test "parses nested sections" {
    var t = try parse(std.testing.allocator, "{{#a}}{{#b}}x{{/b}}{{/a}}");
    defer t.deinit();
    try std.testing.expectEqualStrings("a", t.nodes[0].section.path[0]);
    try std.testing.expectEqualStrings("b", t.nodes[0].section.body[0].section.path[0]);
}

test "comments are dropped" {
    var t = try parse(std.testing.allocator, "hi {{! a comment }}there");
    defer t.deinit();
    try std.testing.expectEqual(@as(usize, 2), t.nodes.len);
}

test "unclosed tag is an error" {
    try std.testing.expectError(error.UnclosedTag, parse(std.testing.allocator, "{{oops"));
}

test "unclosed section is an error" {
    try std.testing.expectError(error.UnclosedSection, parse(std.testing.allocator, "{{#x}}body"));
}

test "unexpected close is an error" {
    try std.testing.expectError(error.UnexpectedClose, parse(std.testing.allocator, "{{/x}}"));
}

test "mismatched close is an error" {
    try std.testing.expectError(error.MismatchedClose, parse(std.testing.allocator, "{{#a}}{{/b}}"));
}
