const std = @import("std");
const ast = @import("ast.zig");
const escape = @import("escape.zig");
const Value = @import("value.zig").Value;
const parser = @import("parser.zig");
const Writer = std.Io.Writer;

// Combined error set. Rendering may fail on write errors, allocation
// errors during lambda re-parsing, or parse errors when a lambda's return
// value isn't well-formed Mustache.
pub const RenderError = Writer.Error || std.mem.Allocator.Error || parser.ParseError;

/// Pre-parsed partials, keyed by name. Caller owns the templates.
pub const Partials = std.StringHashMap(ast.Template);

/// Renderer options. `allocator` is required if templates may invoke
/// lambdas (the renderer needs to allocate for the lambda's return value
/// and the parsed sub-template). If absent, lambdas render as empty.
pub const RenderOptions = struct {
    partials: ?*const Partials = null,
    allocator: ?std.mem.Allocator = null,
};

const Frame = struct {
    value: Value,
    parent: ?*const Frame,
};

pub fn render(template: ast.Template, writer: *Writer, value: Value) RenderError!void {
    return renderEx(template, writer, value, .{});
}

pub fn renderWithPartials(
    template: ast.Template,
    writer: *Writer,
    value: Value,
    partials: *const Partials,
) RenderError!void {
    return renderEx(template, writer, value, .{ .partials = partials });
}

pub fn renderEx(
    template: ast.Template,
    writer: *Writer,
    value: Value,
    opts: RenderOptions,
) RenderError!void {
    const top = Frame{ .value = value, .parent = null };
    var state: IndentState = .{};
    return renderNodes(template.nodes, writer, &top, opts.partials, &state, null, opts.allocator);
}

// Line-aware rendering state, always present (so even at the top level we
// know whether the next output begins a line). Partials and blocks push a
// new state by saving/restoring fields around their render.
//
//   indent: prepended after every \n inside structural text.
//   strip:  common leading whitespace to remove from override-body lines
//           before the indent is added (the block-reindentation rule —
//           "Block indentation is removed at the site of definition and
//           added at the site of expansion").
//   at_line_start: true if the next char would start a line. Updated by
//                  text writes only; variable/section expansions are opaque
//                  per the Mustache standalone-indent rule.
const IndentState = struct {
    indent: []const u8 = "",
    strip: []const u8 = "",
    at_line_start: bool = true,
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
    ind: *IndentState,
    overrides: ?*const OverrideFrame,
    lambda_alloc: ?std.mem.Allocator,
) RenderError!void {
    for (nodes) |node| {
        switch (node) {
            .text => |t| try writeTextIndented(w, t, ind),
            .variable => |v| {
                try writeIndentIfStart(w, ind);
                try writeVariable(w, top, v.path, v.escape, partials, ind, overrides, lambda_alloc);
                ind.at_line_start = false;
            },
            .section => |s| {
                try writeIndentIfStart(w, ind);
                try renderSection(w, top, s, false, partials, ind, overrides, lambda_alloc);
            },
            .inverted => |s| {
                try writeIndentIfStart(w, ind);
                try renderSection(w, top, s, true, partials, ind, overrides, lambda_alloc);
            },
            .partial => |p| {
                try writeIndentIfStart(w, ind);
                try renderPartial(w, top, p, partials, ind, overrides, lambda_alloc);
            },
            .block => |b| try renderBlock(w, top, b, partials, ind, overrides, lambda_alloc),
            .parent => |pi| {
                try writeIndentIfStart(w, ind);
                try renderParentInvocation(w, top, pi, partials, ind, overrides, lambda_alloc);
            },
        }
    }
}

fn writeIndentIfStart(w: *Writer, ind: *IndentState) RenderError!void {
    if (ind.at_line_start and ind.indent.len > 0) {
        try w.writeAll(ind.indent);
        ind.at_line_start = false;
    }
}

// Write `text` while honoring the indent state. After a newline (and at the
// start of `text` if at_line_start was true), optionally strip a common-ws
// prefix and then emit the indent.
fn writeTextIndented(w: *Writer, text: []const u8, ind: *IndentState) RenderError!void {
    var i: usize = 0;
    while (i < text.len) {
        if (ind.at_line_start) {
            // Strip body's common leading ws if present at this line start.
            if (ind.strip.len > 0 and text.len - i >= ind.strip.len and
                std.mem.startsWith(u8, text[i..], ind.strip))
            {
                i += ind.strip.len;
            }
            if (i >= text.len) {
                // line was just the strip prefix — nothing else, nothing to emit.
                return;
            }
            if (text[i] != '\n') {
                if (ind.indent.len > 0) try w.writeAll(ind.indent);
            }
            ind.at_line_start = false;
        }
        // emit a run up to and including the next \n, or the rest.
        const start = i;
        while (i < text.len and text[i] != '\n') : (i += 1) {}
        if (i < text.len) {
            // include the \n
            i += 1;
            try w.writeAll(text[start..i]);
            ind.at_line_start = true;
        } else {
            try w.writeAll(text[start..i]);
        }
    }
}

fn isImplicitDot(path: []const []const u8) bool {
    return path.len == 1 and path[0].len == 1 and path[0][0] == '.';
}

// ----- variable -----

fn writeVariable(
    w: *Writer,
    top: *const Frame,
    path: []const []const u8,
    do_escape: bool,
    partials: ?*const Partials,
    ind: *IndentState,
    overrides: ?*const OverrideFrame,
    lambda_alloc: ?std.mem.Allocator,
) RenderError!void {
    if (isImplicitDot(path)) return writeValue(w, top.value, do_escape, top, partials, ind, overrides, lambda_alloc);
    if (lookupPath(top, path)) |resolved| {
        try writeValue(w, resolved, do_escape, top, partials, ind, overrides, lambda_alloc);
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
    ind: *IndentState,
    overrides: ?*const OverrideFrame,
    lambda_alloc: ?std.mem.Allocator,
) RenderError!void {
    const resolved: ?Value = if (isImplicitDot(section.path)) top.value else lookupPath(top, section.path);

    if (inverted) {
        const v: Value = resolved orelse .null;
        // Spec: lambdas in inverted sections are always treated as truthy,
        // so the body is skipped (isFalsy(.lambda) returns false).
        if (isFalsy(v)) try renderNodes(section.body, w, top, partials, ind, overrides, lambda_alloc);
        return;
    }

    if (resolved) |v| try dispatchSection(w, top, v, section, partials, ind, overrides, lambda_alloc);
}

fn dispatchSection(
    w: *Writer,
    top: *const Frame,
    value: Value,
    section: ast.Node.Section,
    partials: ?*const Partials,
    ind: *IndentState,
    overrides: ?*const OverrideFrame,
    lambda_alloc: ?std.mem.Allocator,
) RenderError!void {
    const body = section.body;
    switch (value) {
        .null => {},
        .bool => |b| if (b) try renderNodes(body, w, top, partials, ind, overrides, lambda_alloc),
        .int => |i| if (i != 0) {
            const f = Frame{ .value = value, .parent = top };
            try renderNodes(body, w, &f, partials, ind, overrides, lambda_alloc);
        },
        .float => |fv| if (fv != 0) {
            const f = Frame{ .value = value, .parent = top };
            try renderNodes(body, w, &f, partials, ind, overrides, lambda_alloc);
        },
        .string => |s| if (s.len > 0) {
            const f = Frame{ .value = value, .parent = top };
            try renderNodes(body, w, &f, partials, ind, overrides, lambda_alloc);
        },
        .list => |xs| {
            for (xs) |item| {
                const f = Frame{ .value = item, .parent = top };
                try renderNodes(body, w, &f, partials, ind, overrides, lambda_alloc);
            }
        },
        .object => {
            const f = Frame{ .value = value, .parent = top };
            try renderNodes(body, w, &f, partials, ind, overrides, lambda_alloc);
        },
        .lambda => |l| try callSectionLambda(l, section, w, top, partials, ind, overrides, lambda_alloc),
    }
}

fn callSectionLambda(
    l: Value.Lambda,
    section: ast.Node.Section,
    w: *Writer,
    top: *const Frame,
    partials: ?*const Partials,
    ind: *IndentState,
    overrides: ?*const OverrideFrame,
    lambda_alloc: ?std.mem.Allocator,
) RenderError!void {
    const alloc = lambda_alloc orelse return;
    const out = try l.call(alloc, section.raw_body);
    defer alloc.free(out);

    var sub_tmpl = try parser.parseEx(alloc, out, section.delim_open, section.delim_close);
    defer sub_tmpl.deinit();

    try renderNodes(sub_tmpl.nodes, w, top, partials, ind, overrides, lambda_alloc);
}

fn callVariableLambda(
    l: Value.Lambda,
    w: *Writer,
    do_escape: bool,
    top: *const Frame,
    partials: ?*const Partials,
    ind: *IndentState,
    overrides: ?*const OverrideFrame,
    lambda_alloc: ?std.mem.Allocator,
) RenderError!void {
    const alloc = lambda_alloc orelse return;
    const out = try l.call(alloc, null);
    defer alloc.free(out);

    // Variable-lambda return values are parsed with the default delimiters
    // regardless of the surrounding template's delimiter state.
    var sub_tmpl = try parser.parseEx(alloc, out, "{{", "}}");
    defer sub_tmpl.deinit();

    if (!do_escape) {
        try renderNodes(sub_tmpl.nodes, w, top, partials, ind, overrides, lambda_alloc);
        return;
    }

    // Escaped variable: render to a buffer, then HTML-escape the output.
    var aw: std.Io.Writer.Allocating = .init(alloc);
    defer aw.deinit();
    var sub_state: IndentState = .{};
    try renderNodes(sub_tmpl.nodes, &aw.writer, top, partials, &sub_state, overrides, lambda_alloc);
    try escape.html(w, aw.writer.buffered());
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
        // Per Mustache spec: lambdas in inverted sections are always treated
        // as truthy, so the inverted body is skipped.
        .lambda => false,
    };
}

// ----- partial -----

fn renderPartial(
    w: *Writer,
    top: *const Frame,
    p: ast.Node.Partial,
    partials: ?*const Partials,
    ind: *IndentState,
    overrides: ?*const OverrideFrame,
    lambda_alloc: ?std.mem.Allocator,
) RenderError!void {
    const map = partials orelse return;

    const name: []const u8 = if (p.dynamic) blk: {
        const resolved = lookupPath(top, p.path) orelse return;
        if (resolved != .string) return;
        break :blk resolved.string;
    } else p.name;

    const tmpl = map.get(name) orelse return;

    if (p.indent.len == 0) {
        return renderNodes(tmpl.nodes, w, top, partials, ind, overrides, lambda_alloc);
    }
    var nested: IndentState = .{ .indent = p.indent, .at_line_start = true };
    try renderNodes(tmpl.nodes, w, top, partials, &nested, overrides, lambda_alloc);
    ind.at_line_start = nested.at_line_start;
}

fn renderParentInvocation(
    w: *Writer,
    top: *const Frame,
    pi: ast.Node.ParentInvocation,
    partials: ?*const Partials,
    ind: *IndentState,
    overrides: ?*const OverrideFrame,
    lambda_alloc: ?std.mem.Allocator,
) RenderError!void {
    const map = partials orelse return;
    const tmpl = map.get(pi.name) orelse return;

    const frame = OverrideFrame{ .blocks = pi.overrides, .parent = overrides };

    if (pi.indent.len == 0) {
        return renderNodes(tmpl.nodes, w, top, partials, ind, &frame, lambda_alloc);
    }
    var nested: IndentState = .{ .indent = pi.indent, .at_line_start = true };
    try renderNodes(tmpl.nodes, w, top, partials, &nested, &frame, lambda_alloc);
    ind.at_line_start = nested.at_line_start;
}

fn renderBlock(
    w: *Writer,
    top: *const Frame,
    b: ast.Node.Block,
    partials: ?*const Partials,
    ind: *IndentState,
    overrides: ?*const OverrideFrame,
    lambda_alloc: ?std.mem.Allocator,
) RenderError!void {
    const overridden = OverrideFrame.lookup(overrides, b.name);
    const body = overridden orelse b.body;

    var effective_indent = b.indent;
    if (effective_indent.len == 0) {
        effective_indent = computeCommonIndent(b.body);
    }
    const common_strip = computeCommonIndent(body);

    if (effective_indent.len == 0 and common_strip.len == 0) {
        try writeIndentIfStart(w, ind);
        return renderNodes(body, w, top, partials, ind, overrides, lambda_alloc);
    }

    var nested: IndentState = .{
        .indent = effective_indent,
        .strip = common_strip,
        .at_line_start = ind.at_line_start,
    };
    try renderNodes(body, w, top, partials, &nested, overrides, lambda_alloc);
    ind.at_line_start = nested.at_line_start;
}

// Compute the longest common leading-whitespace prefix across non-empty
// lines in a node tree. Lines that start with text contribute their leading
// run of spaces/tabs. Lines that start with a $block contribute the block's
// intrinsic indent (which is the leading ws of the block tag's source line).
// Other non-text nodes at line start (variables, sections, parent
// invocations) are treated as "0 leading ws" — which collapses common to
// empty for that line.
fn computeCommonIndent(nodes: []const ast.Node) []const u8 {
    var common: ?[]const u8 = null;
    var at_line_start = true;
    const apply = struct {
        fn f(c: *?[]const u8, line: []const u8) bool {
            if (c.*) |existing| {
                c.* = longestCommonPrefix(existing, line);
                if (c.*.?.len == 0) return false; // exhausted
            } else {
                c.* = line;
            }
            return true;
        }
    }.f;
    for (nodes) |n| {
        switch (n) {
            .text => |t| {
                var i: usize = 0;
                while (i < t.len) {
                    if (at_line_start) {
                        const start = i;
                        while (i < t.len and (t[i] == ' ' or t[i] == '\t')) : (i += 1) {}
                        // Empty lines (just \n) don't constrain.
                        if (i < t.len and t[i] != '\n') {
                            if (!apply(&common, t[start..i])) return "";
                        }
                        at_line_start = false;
                    }
                    if (i < t.len and t[i] == '\n') at_line_start = true;
                    i += 1;
                }
            },
            .block => |b| {
                if (at_line_start) {
                    if (!apply(&common, b.indent)) return "";
                    at_line_start = false;
                }
            },
            else => {
                if (at_line_start) return "";
            },
        }
    }
    return common orelse "";
}

fn longestCommonPrefix(a: []const u8, b: []const u8) []const u8 {
    const n = @min(a.len, b.len);
    var i: usize = 0;
    while (i < n and a[i] == b[i]) : (i += 1) {}
    return a[0..i];
}

// ----- value writer -----

fn writeValue(
    w: *Writer,
    value: Value,
    do_escape: bool,
    top: *const Frame,
    partials: ?*const Partials,
    ind: *IndentState,
    overrides: ?*const OverrideFrame,
    lambda_alloc: ?std.mem.Allocator,
) RenderError!void {
    switch (value) {
        .null => {},
        .bool => |b| try w.writeAll(if (b) "true" else "false"),
        .int => |i| try w.print("{d}", .{i}),
        .float => |f| try w.print("{d}", .{f}),
        .string => |s| if (do_escape) try escape.html(w, s) else try w.writeAll(s),
        .list, .object => {},
        .lambda => |l| try callVariableLambda(l, w, do_escape, top, partials, ind, overrides, lambda_alloc),
    }
}

// ----- tests -----

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
