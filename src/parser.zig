const std = @import("std");
const ast = @import("ast.zig");

pub const ParseError = error{
    UnclosedTag,
    EmptyTag,
} || std.mem.Allocator.Error;

pub fn parse(allocator: std.mem.Allocator, source: []const u8) ParseError!ast.Template {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aalloc = arena.allocator();

    const owned = try aalloc.dupe(u8, source);

    var nodes: std.ArrayListUnmanaged(ast.Node) = .{};

    var i: usize = 0;
    var text_start: usize = 0;

    while (i < owned.len) {
        if (i + 1 < owned.len and owned[i] == '{' and owned[i + 1] == '{') {
            if (i > text_start) {
                try nodes.append(aalloc, .{ .text = owned[text_start..i] });
            }

            const after_open = i + 2;
            const triple = after_open < owned.len and owned[after_open] == '{';
            const tag_start = if (triple) after_open + 1 else after_open;
            const close_seq: []const u8 = if (triple) "}}}" else "}}";

            const close_idx = std.mem.indexOfPos(u8, owned, tag_start, close_seq) orelse
                return error.UnclosedTag;

            const raw = std.mem.trim(u8, owned[tag_start..close_idx], " \t");
            if (raw.len == 0) return error.EmptyTag;

            var name = raw;
            var escape = !triple;
            if (!triple and name[0] == '&') {
                name = std.mem.trim(u8, name[1..], " \t");
                escape = false;
                if (name.len == 0) return error.EmptyTag;
            }

            try nodes.append(aalloc, .{ .variable = .{ .name = name, .escape = escape } });
            i = close_idx + close_seq.len;
            text_start = i;
        } else {
            i += 1;
        }
    }
    if (text_start < owned.len) {
        try nodes.append(aalloc, .{ .text = owned[text_start..] });
    }

    return .{
        .nodes = try nodes.toOwnedSlice(aalloc),
        .arena = arena,
    };
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
    try std.testing.expectEqualStrings("Hi ", t.nodes[0].text);
    try std.testing.expectEqualStrings("name", t.nodes[1].variable.name);
    try std.testing.expectEqual(true, t.nodes[1].variable.escape);
    try std.testing.expectEqualStrings("!", t.nodes[2].text);
}

test "parses triple-stache as unescaped" {
    var t = try parse(std.testing.allocator, "{{{raw}}}");
    defer t.deinit();
    try std.testing.expectEqual(@as(usize, 1), t.nodes.len);
    try std.testing.expectEqualStrings("raw", t.nodes[0].variable.name);
    try std.testing.expectEqual(false, t.nodes[0].variable.escape);
}

test "parses ampersand as unescaped" {
    var t = try parse(std.testing.allocator, "{{& raw }}");
    defer t.deinit();
    try std.testing.expectEqualStrings("raw", t.nodes[0].variable.name);
    try std.testing.expectEqual(false, t.nodes[0].variable.escape);
}

test "trims whitespace inside tags" {
    var t = try parse(std.testing.allocator, "{{  name  }}");
    defer t.deinit();
    try std.testing.expectEqualStrings("name", t.nodes[0].variable.name);
}

test "unclosed tag is an error" {
    try std.testing.expectError(error.UnclosedTag, parse(std.testing.allocator, "{{oops"));
}

test "empty tag is an error" {
    try std.testing.expectError(error.EmptyTag, parse(std.testing.allocator, "{{ }}"));
}
