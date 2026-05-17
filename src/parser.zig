const std = @import("std");
const ast = @import("ast.zig");

pub const ParseError = error{
    UnclosedTag,
    EmptyTag,
    UnclosedSection,
    UnexpectedClose,
    MismatchedClose,
    InvalidDelimiterTag,
} || std.mem.Allocator.Error;

const State = struct {
    source: []const u8,
    cursor: usize,
    line_start: usize,
    open: []const u8,
    close: []const u8,

    fn defaultDelims(self: *const State) bool {
        return std.mem.eql(u8, self.open, "{{") and std.mem.eql(u8, self.close, "}}");
    }
};

pub fn parse(allocator: std.mem.Allocator, source: []const u8) ParseError!ast.Template {
    var arena = std.heap.ArenaAllocator.init(allocator);
    errdefer arena.deinit();
    const aalloc = arena.allocator();

    const owned = try aalloc.dupe(u8, source);
    var state = State{
        .source = owned,
        .cursor = 0,
        .line_start = 0,
        .open = "{{",
        .close = "}}",
    };
    const nodes = try parseSegment(aalloc, &state, null);

    return .{ .nodes = nodes, .arena = arena };
}

fn buildPath(aalloc: std.mem.Allocator, raw: []const u8) ParseError![]const []const u8 {
    if (raw.len == 1 and raw[0] == '.') {
        const out = try aalloc.alloc([]const u8, 1);
        out[0] = raw;
        return out;
    }
    var list: std.ArrayList([]const u8) = .empty;
    var it = std.mem.splitScalar(u8, raw, '.');
    while (it.next()) |seg| {
        if (seg.len == 0) return error.EmptyTag;
        try list.append(aalloc, seg);
    }
    return try list.toOwnedSlice(aalloc);
}

fn consumeStandaloneTail(state: *State, standalone: bool, rhs_end: usize) void {
    if (!standalone) return;
    state.cursor = rhs_end;
    if (state.cursor < state.source.len and state.source[state.cursor] == '\r' and
        state.cursor + 1 < state.source.len and state.source[state.cursor + 1] == '\n')
    {
        state.cursor += 2;
    } else if (state.cursor < state.source.len and state.source[state.cursor] == '\n') {
        state.cursor += 1;
    }
    state.line_start = state.cursor;
}

fn parseSegment(
    aalloc: std.mem.Allocator,
    state: *State,
    end_section: ?[]const u8,
) ParseError![]ast.Node {
    var nodes: std.ArrayList(ast.Node) = .empty;
    var text_start = state.cursor;

    while (state.cursor < state.source.len) {
        const src = state.source;
        const i = state.cursor;
        const c = src[i];

        if (c == '\n') {
            state.cursor += 1;
            state.line_start = state.cursor;
            continue;
        }
        if (c == '\r' and i + 1 < src.len and src[i + 1] == '\n') {
            state.cursor += 2;
            state.line_start = state.cursor;
            continue;
        }

        if (!startsWithAt(src, i, state.open)) {
            state.cursor += 1;
            continue;
        }

        const after_open = i + state.open.len;

        // triple-stache only when delimiters are the default {{ / }}
        const triple = state.defaultDelims() and after_open < src.len and src[after_open] == '{';
        const tag_start = if (triple) after_open + 1 else after_open;
        const close_seq: []const u8 = if (triple) "}}}" else state.close;

        const close_idx = std.mem.indexOfPos(u8, src, tag_start, close_seq) orelse
            return error.UnclosedTag;

        const inner = std.mem.trim(u8, src[tag_start..close_idx], " \t");
        if (inner.len == 0) return error.EmptyTag;

        const sigil = inner[0];
        const is_block = !triple and
            (sigil == '#' or sigil == '^' or sigil == '/' or sigil == '!' or sigil == '=' or sigil == '>');

        const after_close = close_idx + close_seq.len;

        // standalone-line detection
        var lhs_is_ws = true;
        {
            var j = state.line_start;
            while (j < i) : (j += 1) {
                const ch = src[j];
                if (ch != ' ' and ch != '\t') {
                    lhs_is_ws = false;
                    break;
                }
            }
        }
        var rhs_end = after_close;
        while (rhs_end < src.len and (src[rhs_end] == ' ' or src[rhs_end] == '\t')) : (rhs_end += 1) {}
        const rhs_at_newline = rhs_end >= src.len or src[rhs_end] == '\n' or
            (src[rhs_end] == '\r' and rhs_end + 1 < src.len and src[rhs_end + 1] == '\n');

        const standalone = is_block and lhs_is_ws and rhs_at_newline;

        const text_end = if (standalone) state.line_start else i;
        if (text_end > text_start) {
            try nodes.append(aalloc, .{ .text = src[text_start..text_end] });
        }

        state.cursor = after_close;

        switch (sigil) {
            '!' => consumeStandaloneTail(state, standalone, rhs_end),
            '#', '^' => {
                const raw = std.mem.trim(u8, inner[1..], " \t");
                if (raw.len == 0) return error.EmptyTag;
                const path = try buildPath(aalloc, raw);
                consumeStandaloneTail(state, standalone, rhs_end);
                const body = try parseSegment(aalloc, state, raw);
                const section = ast.Node.Section{ .path = path, .body = body };
                try nodes.append(aalloc, if (sigil == '#')
                    .{ .section = section }
                else
                    .{ .inverted = section });
            },
            '/' => {
                const name = std.mem.trim(u8, inner[1..], " \t");
                if (end_section == null) return error.UnexpectedClose;
                if (!std.mem.eql(u8, name, end_section.?)) return error.MismatchedClose;
                consumeStandaloneTail(state, standalone, rhs_end);
                return try nodes.toOwnedSlice(aalloc);
            },
            '&' => {
                if (triple) return error.EmptyTag;
                const raw = std.mem.trim(u8, inner[1..], " \t");
                if (raw.len == 0) return error.EmptyTag;
                const path = try buildPath(aalloc, raw);
                try nodes.append(aalloc, .{ .variable = .{ .path = path, .escape = false } });
            },
            '>' => {
                const raw = std.mem.trim(u8, inner[1..], " \t");
                if (raw.len == 0) return error.EmptyTag;
                // Capture leading whitespace for the standalone-indent rule.
                // src is the snapshot taken at the top of the loop iteration;
                // line_start hasn't moved since (we haven't seen \n yet).
                const indent: []const u8 = if (standalone) src[state.line_start..i] else "";
                consumeStandaloneTail(state, standalone, rhs_end);
                try nodes.append(aalloc, .{ .partial = .{ .name = raw, .indent = indent } });
            },
            '=' => {
                // {{=NEW_OPEN NEW_CLOSE=}}  (with current open/close)
                if (inner.len < 3 or inner[inner.len - 1] != '=') return error.InvalidDelimiterTag;
                const middle = std.mem.trim(u8, inner[1 .. inner.len - 1], " \t");
                const ws = std.mem.indexOfAny(u8, middle, " \t") orelse return error.InvalidDelimiterTag;
                const new_open = middle[0..ws];
                const new_close = std.mem.trimStart(u8, middle[ws..], " \t");
                if (new_open.len == 0 or new_close.len == 0) return error.InvalidDelimiterTag;
                if (std.mem.indexOfAny(u8, new_open, " \t") != null) return error.InvalidDelimiterTag;
                if (std.mem.indexOfAny(u8, new_close, " \t") != null) return error.InvalidDelimiterTag;
                state.open = new_open;
                state.close = new_close;
                consumeStandaloneTail(state, standalone, rhs_end);
            },
            else => {
                const path = try buildPath(aalloc, inner);
                try nodes.append(aalloc, .{ .variable = .{ .path = path, .escape = !triple } });
            },
        }

        text_start = state.cursor;
    }

    if (end_section != null) return error.UnclosedSection;
    if (text_start < state.source.len) {
        try nodes.append(aalloc, .{ .text = state.source[text_start..] });
    }
    return try nodes.toOwnedSlice(aalloc);
}

fn startsWithAt(src: []const u8, i: usize, needle: []const u8) bool {
    if (needle.len == 0 or i + needle.len > src.len) return false;
    return std.mem.eql(u8, src[i .. i + needle.len], needle);
}

// ----- tests -----

test "parses a simple variable" {
    var t = try parse(std.testing.allocator, "Hi {{name}}!");
    defer t.deinit();
    try std.testing.expectEqual(@as(usize, 3), t.nodes.len);
    try std.testing.expectEqualStrings("name", t.nodes[1].variable.path[0]);
    try std.testing.expectEqual(true, t.nodes[1].variable.escape);
}

test "parses a dotted variable into path segments" {
    var t = try parse(std.testing.allocator, "{{user.address.city}}");
    defer t.deinit();
    const p = t.nodes[0].variable.path;
    try std.testing.expectEqual(@as(usize, 3), p.len);
    try std.testing.expectEqualStrings("user", p[0]);
    try std.testing.expectEqualStrings("city", p[2]);
}

test "implicit dot is a single-segment path" {
    var t = try parse(std.testing.allocator, "{{.}}");
    defer t.deinit();
    try std.testing.expectEqualStrings(".", t.nodes[0].variable.path[0]);
}

test "empty segment in dotted path is an error" {
    try std.testing.expectError(error.EmptyTag, parse(std.testing.allocator, "{{a..b}}"));
}

test "parses triple-stache as unescaped" {
    var t = try parse(std.testing.allocator, "{{{raw}}}");
    defer t.deinit();
    try std.testing.expectEqual(false, t.nodes[0].variable.escape);
}

test "parses ampersand as unescaped" {
    var t = try parse(std.testing.allocator, "{{& raw }}");
    defer t.deinit();
    try std.testing.expectEqualStrings("raw", t.nodes[0].variable.path[0]);
    try std.testing.expectEqual(false, t.nodes[0].variable.escape);
}

test "parses a dotted section" {
    var t = try parse(std.testing.allocator, "{{#user.address}}x{{/user.address}}");
    defer t.deinit();
    try std.testing.expectEqual(@as(usize, 2), t.nodes[0].section.path.len);
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

// ----- standalone-line behavior -----

test "comment alone on a line strips the line" {
    var t = try parse(std.testing.allocator, "a\n{{! c }}\nb");
    defer t.deinit();
    try std.testing.expectEqual(@as(usize, 2), t.nodes.len);
    try std.testing.expectEqualStrings("a\n", t.nodes[0].text);
    try std.testing.expectEqualStrings("b", t.nodes[1].text);
}

test "comment at start of input is standalone" {
    var t = try parse(std.testing.allocator, "{{! c }}\nrest");
    defer t.deinit();
    try std.testing.expectEqual(@as(usize, 1), t.nodes.len);
    try std.testing.expectEqualStrings("rest", t.nodes[0].text);
}

test "comment with leading whitespace on its line is standalone" {
    var t = try parse(std.testing.allocator, "  {{! c }}  \nrest");
    defer t.deinit();
    try std.testing.expectEqual(@as(usize, 1), t.nodes.len);
    try std.testing.expectEqualStrings("rest", t.nodes[0].text);
}

test "comment in mid-line is not standalone" {
    var t = try parse(std.testing.allocator, "x{{!c}}\ny");
    defer t.deinit();
    try std.testing.expectEqual(@as(usize, 2), t.nodes.len);
    try std.testing.expectEqualStrings("x", t.nodes[0].text);
    try std.testing.expectEqualStrings("\ny", t.nodes[1].text);
}

test "section open and close on their own lines strip surrounding newlines" {
    var t = try parse(std.testing.allocator, "{{#x}}\nbody\n{{/x}}\n");
    defer t.deinit();
    try std.testing.expectEqual(@as(usize, 1), t.nodes.len);
    const sec = t.nodes[0].section;
    try std.testing.expectEqual(@as(usize, 1), sec.body.len);
    try std.testing.expectEqualStrings("body\n", sec.body[0].text);
}

test "variable tag does not trigger standalone" {
    var t = try parse(std.testing.allocator, "{{name}}\n");
    defer t.deinit();
    try std.testing.expectEqual(@as(usize, 2), t.nodes.len);
    try std.testing.expectEqualStrings("\n", t.nodes[1].text);
}

// ----- set-delimiter -----

test "set-delimiter changes the current delimiters" {
    var t = try parse(std.testing.allocator, "{{=<% %>=}}<% name %>");
    defer t.deinit();
    // The set-delim tag itself produces no node; the remaining is one variable.
    try std.testing.expectEqual(@as(usize, 1), t.nodes.len);
    try std.testing.expectEqualStrings("name", t.nodes[0].variable.path[0]);
}

test "set-delimiter affects section close" {
    var t = try parse(std.testing.allocator, "{{=<% %>=}}<%#x%>body<%/x%>");
    defer t.deinit();
    try std.testing.expectEqual(@as(usize, 1), t.nodes.len);
    try std.testing.expectEqualStrings("x", t.nodes[0].section.path[0]);
    try std.testing.expectEqualStrings("body", t.nodes[0].section.body[0].text);
}

test "set-delimiter alone on a line is standalone" {
    var t = try parse(std.testing.allocator, "before\n{{=<% %>=}}\n<%name%>");
    defer t.deinit();
    try std.testing.expectEqual(@as(usize, 2), t.nodes.len);
    try std.testing.expectEqualStrings("before\n", t.nodes[0].text);
    try std.testing.expectEqualStrings("name", t.nodes[1].variable.path[0]);
}

test "set-delimiter with invalid format is an error" {
    try std.testing.expectError(error.InvalidDelimiterTag, parse(std.testing.allocator, "{{= bad =}}"));
    try std.testing.expectError(error.InvalidDelimiterTag, parse(std.testing.allocator, "{{=<% %> }}"));
}
