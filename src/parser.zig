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
    // Set by the '/' close handler before it returns; lets the open's branch
    // (typically `<` or `$`) decide compound-standalone retroactively.
    last_close_standalone: bool = false,
    // Whether the chars after the just-closed tag (skipping h/v whitespace)
    // were a newline or EOF. Parent-invocation compound-standalone uses this
    // to decide whether to absorb the trailing newline, even when the close's
    // lhs has other content (per spec, parent bodies are "ignored" so other
    // tags on the close's line don't disqualify standaloneness).
    last_close_rhs_at_newline: bool = false,
    // Position right after the rhs whitespace, ready to consume an EOL.
    last_close_rhs_end: usize = 0,

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
    return parseSegmentEx(aalloc, state, end_section, false);
}

// `preserve_close_tail`: when true, the matching close tag does NOT consume
// its trailing newline even if standalone. Used by `$` block bodies so the
// newline after {{/block}} stays in the partial text — needed for the block
// to emit a trailing newline at the expansion site.
fn parseSegmentEx(
    aalloc: std.mem.Allocator,
    state: *State,
    end_section: ?[]const u8,
    preserve_close_tail: bool,
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
            (sigil == '#' or sigil == '^' or sigil == '/' or sigil == '!' or sigil == '=' or sigil == '>' or
                sigil == '$' or sigil == '<');

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
                state.last_close_standalone = standalone;
                state.last_close_rhs_at_newline = rhs_at_newline;
                state.last_close_rhs_end = rhs_end;
                if (!preserve_close_tail) consumeStandaloneTail(state, standalone, rhs_end);
                return try nodes.toOwnedSlice(aalloc);
            },
            '&' => {
                if (triple) return error.EmptyTag;
                const raw = std.mem.trim(u8, inner[1..], " \t");
                if (raw.len == 0) return error.EmptyTag;
                const path = try buildPath(aalloc, raw);
                try nodes.append(aalloc, .{ .variable = .{ .path = path, .escape = false } });
            },
            '$' => {
                const raw = std.mem.trim(u8, inner[1..], " \t");
                if (raw.len == 0) return error.EmptyTag;
                const intrinsic_indent: []const u8 = if (lhs_is_ws) src[state.line_start..i] else "";
                consumeStandaloneTail(state, standalone, rhs_end);
                const saved_line_start = state.line_start;
                state.line_start = state.cursor;
                // Preserve the close's trailing newline only when the open
                // wasn't itself standalone: then both tags sat on the same
                // line, and we need to keep the line's newline as a text
                // node after the block so the expansion produces it.
                // When the open is standalone (block spans multiple source
                // lines), the body's own newlines already provide structure.
                const body = try parseSegmentEx(aalloc, state, raw, !standalone);
                state.line_start = saved_line_start;
                try nodes.append(aalloc, .{ .block = .{
                    .name = raw,
                    .body = body,
                    .indent = intrinsic_indent,
                } });
            },
            '<' => {
                const raw = std.mem.trim(u8, inner[1..], " \t");
                if (raw.len == 0) return error.EmptyTag;
                // Tentative indent: leading whitespace of the open's line if
                // the open is preceded only by whitespace. Used iff the close
                // turns out to round out a compound-standalone construct.
                const tentative_indent: []const u8 = if (lhs_is_ws) src[state.line_start..i] else "";
                state.last_close_standalone = false;
                state.last_close_rhs_at_newline = false;
                consumeStandaloneTail(state, standalone, rhs_end);
                // Fresh line context inside the parent body.
                const saved_line_start = state.line_start;
                state.line_start = state.cursor;
                const all_body = try parseSegment(aalloc, state, raw);
                state.line_start = saved_line_start;

                // Compound-standalone for `{{<x}}...{{/x}}`: per spec, the
                // parent body's content is "ignored" for output, so the WHOLE
                // construct is standalone-eligible if the open's lhs is
                // whitespace and the close's rhs is whitespace+newline —
                // regardless of what's between them. We don't require the
                // close's lhs to be ws (other tags or text inside the body
                // shouldn't block this).
                const compound = lhs_is_ws and state.last_close_rhs_at_newline;
                var indent: []const u8 = "";
                if (compound) {
                    // Strip the leading whitespace of the open's line from
                    // the most-recently-emitted text node, if it ended with
                    // that exact whitespace.
                    if (tentative_indent.len > 0 and
                        nodes.items.len > 0 and
                        nodes.items[nodes.items.len - 1] == .text)
                    {
                        const t = &nodes.items[nodes.items.len - 1].text;
                        if (t.len >= tentative_indent.len and
                            std.mem.endsWith(u8, t.*, tentative_indent))
                        {
                            t.* = t.*[0 .. t.len - tentative_indent.len];
                        }
                    }
                    indent = tentative_indent;
                    // Consume the trailing newline if the close handler
                    // didn't already (which it only does when the close was
                    // independently standalone).
                    if (!state.last_close_standalone) {
                        state.cursor = state.last_close_rhs_end;
                        if (state.cursor < state.source.len) {
                            if (state.source[state.cursor] == '\r' and
                                state.cursor + 1 < state.source.len and
                                state.source[state.cursor + 1] == '\n')
                            {
                                state.cursor += 2;
                            } else if (state.source[state.cursor] == '\n') {
                                state.cursor += 1;
                            }
                            state.line_start = state.cursor;
                        }
                    }
                }

                var blocks: std.ArrayList(ast.Node.Block) = .empty;
                for (all_body) |n| {
                    if (n == .block) try blocks.append(aalloc, n.block);
                }
                try nodes.append(aalloc, .{ .parent = .{
                    .name = raw,
                    .indent = indent,
                    .overrides = try blocks.toOwnedSlice(aalloc),
                } });
            },
            '>' => {
                var raw = std.mem.trim(u8, inner[1..], " \t");
                var dynamic = false;
                if (raw.len > 0 and raw[0] == '*') {
                    dynamic = true;
                    raw = std.mem.trim(u8, raw[1..], " \t");
                }
                if (raw.len == 0) return error.EmptyTag;
                const indent: []const u8 = if (standalone) src[state.line_start..i] else "";
                consumeStandaloneTail(state, standalone, rhs_end);
                const path: []const []const u8 = if (dynamic)
                    try buildPath(aalloc, raw)
                else
                    &.{};
                try nodes.append(aalloc, .{ .partial = .{
                    .name = raw,
                    .path = path,
                    .indent = indent,
                    .dynamic = dynamic,
                } });
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
