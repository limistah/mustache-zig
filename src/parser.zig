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
                    const name = std.mem.trim(u8, inner[1..], " \t");
                    if (name.len == 0) return error.EmptyTag;
                    const body = try parseSegment(aalloc, source, cursor, name);
                    const section = ast.Node.Section{ .name = name, .body = body };
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
                    const name = std.mem.trim(u8, inner[1..], " \t");
                    if (name.len == 0) return error.EmptyTag;
                    try nodes.append(aalloc, .{ .variable = .{ .name = name, .escape = false } });
                },
                else => {
                    try nodes.append(aalloc, .{ .variable = .{ .name = inner, .escape = !triple } });
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

test "parses plain text" {
    var t = try parse(std.testing.allocator, "hello world");
    defer t.deinit();
    try std.testing.expectEqual(@as(usize, 1), t.nodes.len);
    try std.testing.expectEqualStrings("hello world", t.nodes[0].text);
}

test "parses a simple variable" {
    var t = try parse(std.testing.allocator, "Hi {{name}}!");
    defer t.deinit();
    try std.testing.expectEqual(@as(usize, 3), t.nodes.len);
    try std.testing.expectEqualStrings("name", t.nodes[1].variable.name);
    try std.testing.expectEqual(true, t.nodes[1].variable.escape);
}

test "parses triple-stache as unescaped" {
    var t = try parse(std.testing.allocator, "{{{raw}}}");
    defer t.deinit();
    try std.testing.expectEqualStrings("raw", t.nodes[0].variable.name);
    try std.testing.expectEqual(false, t.nodes[0].variable.escape);
}

test "parses ampersand as unescaped" {
    var t = try parse(std.testing.allocator, "{{& raw }}");
    defer t.deinit();
    try std.testing.expectEqualStrings("raw", t.nodes[0].variable.name);
    try std.testing.expectEqual(false, t.nodes[0].variable.escape);
}

test "parses a section" {
    var t = try parse(std.testing.allocator, "before{{#items}}body{{/items}}after");
    defer t.deinit();
    try std.testing.expectEqual(@as(usize, 3), t.nodes.len);
    try std.testing.expectEqualStrings("before", t.nodes[0].text);
    try std.testing.expectEqualStrings("items", t.nodes[1].section.name);
    try std.testing.expectEqual(@as(usize, 1), t.nodes[1].section.body.len);
    try std.testing.expectEqualStrings("body", t.nodes[1].section.body[0].text);
    try std.testing.expectEqualStrings("after", t.nodes[2].text);
}

test "parses an inverted section" {
    var t = try parse(std.testing.allocator, "{{^empty}}nothing{{/empty}}");
    defer t.deinit();
    try std.testing.expectEqualStrings("empty", t.nodes[0].inverted.name);
}

test "parses nested sections" {
    var t = try parse(std.testing.allocator, "{{#a}}{{#b}}x{{/b}}{{/a}}");
    defer t.deinit();
    try std.testing.expectEqualStrings("a", t.nodes[0].section.name);
    try std.testing.expectEqualStrings("b", t.nodes[0].section.body[0].section.name);
}

test "comments are dropped" {
    var t = try parse(std.testing.allocator, "hi {{! a comment }}there");
    defer t.deinit();
    try std.testing.expectEqual(@as(usize, 2), t.nodes.len);
    try std.testing.expectEqualStrings("hi ", t.nodes[0].text);
    try std.testing.expectEqualStrings("there", t.nodes[1].text);
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
