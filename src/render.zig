const std = @import("std");
const ast = @import("ast.zig");
const escape = @import("escape.zig");

// Context stack representation:
//   empty stack:        .{}
//   one-frame stack:    .{ ctx, .{} }
//   two-frame stack:    .{ inner, .{ outer, .{} } }
//
// Variable / section names are pre-split into path segments. The FIRST
// segment uses stack-walking lookup (innermost -> outermost). Once a frame
// containing the first segment is found, we COMMIT to that resolution path:
// subsequent segments only descend into the resolved object, no stack
// fallback. This matches the Mustache spec's dotted-name semantics.

pub fn render(template: ast.Template, writer: anytype, context: anytype) !void {
    return renderNodes(template.nodes, writer, .{ context, .{} });
}

fn renderNodes(nodes: []const ast.Node, writer: anytype, stack: anytype) !void {
    for (nodes) |node| {
        switch (node) {
            .text => |t| try writer.writeAll(t),
            .variable => |v| try lookupAndWrite(writer, stack, v.path, v.escape),
            .section => |s| try renderSection(writer, stack, s, false),
            .inverted => |s| try renderSection(writer, stack, s, true),
        }
    }
}

fn isImplicitDot(seg: []const u8) bool {
    return seg.len == 1 and seg[0] == '.';
}

// ----- variable lookup -----

fn lookupAndWrite(writer: anytype, stack: anytype, path: []const []const u8, do_escape: bool) !void {
    // implicit iterator: path == ["."]  -> write current scope
    if (path.len == 1 and isImplicitDot(path[0])) {
        if (@typeInfo(@TypeOf(stack)).@"struct".fields.len == 0) return;
        try writeValue(writer, stack[0], do_escape);
        return;
    }
    _ = try walkStackForWrite(writer, stack, path, do_escape);
}

fn walkStackForWrite(writer: anytype, stack: anytype, path: []const []const u8, do_escape: bool) !bool {
    if (@typeInfo(@TypeOf(stack)).@"struct".fields.len == 0) return false;
    if (try tryCommitFromHead(writer, stack[0], path, do_escape)) return true;
    return walkStackForWrite(writer, stack[1], path, do_escape);
}

fn tryCommitFromHead(writer: anytype, head: anytype, path: []const []const u8, do_escape: bool) !bool {
    const T = @TypeOf(head);
    const info = @typeInfo(T);
    if (info == .pointer and info.pointer.size == .one) {
        return tryCommitFromHead(writer, head.*, path, do_escape);
    }
    if (info == .optional) {
        if (head) |h| return tryCommitFromHead(writer, h, path, do_escape);
        return false;
    }
    if (info != .@"struct" or info.@"struct".is_tuple) return false;
    inline for (info.@"struct".fields) |f| {
        if (std.mem.eql(u8, f.name, path[0])) {
            // commit: descent succeeds or fails here, but no fallback to other frames
            _ = try descendStrictAndWrite(writer, @field(head, f.name), path[1..], do_escape);
            return true;
        }
    }
    return false;
}

fn descendStrictAndWrite(writer: anytype, value: anytype, rest: []const []const u8, do_escape: bool) !bool {
    if (rest.len == 0) {
        try writeValue(writer, value, do_escape);
        return true;
    }
    const T = @TypeOf(value);
    const info = @typeInfo(T);
    if (info == .pointer and info.pointer.size == .one) {
        return descendStrictAndWrite(writer, value.*, rest, do_escape);
    }
    if (info == .optional) {
        if (value) |v| return descendStrictAndWrite(writer, v, rest, do_escape);
        return false;
    }
    if (info != .@"struct" or info.@"struct".is_tuple) return false;
    inline for (info.@"struct".fields) |f| {
        if (std.mem.eql(u8, f.name, rest[0])) {
            return descendStrictAndWrite(writer, @field(value, f.name), rest[1..], do_escape);
        }
    }
    return false;
}

// ----- section lookup + dispatch -----

fn renderSection(writer: anytype, stack: anytype, section: ast.Node.Section, inverted: bool) !void {
    if (try walkStackForSection(writer, stack, stack, section, inverted)) return;
    // never found in any frame -> falsy
    if (inverted) try renderNodes(section.body, writer, stack);
}

fn walkStackForSection(
    writer: anytype,
    original: anytype,
    search: anytype,
    section: ast.Node.Section,
    inverted: bool,
) !bool {
    if (@typeInfo(@TypeOf(search)).@"struct".fields.len == 0) return false;
    if (try trySectionCommitFromHead(writer, original, search[0], section, inverted)) return true;
    return walkStackForSection(writer, original, search[1], section, inverted);
}

fn trySectionCommitFromHead(
    writer: anytype,
    stack: anytype,
    head: anytype,
    section: ast.Node.Section,
    inverted: bool,
) !bool {
    const T = @TypeOf(head);
    const info = @typeInfo(T);
    if (info == .pointer and info.pointer.size == .one) {
        return trySectionCommitFromHead(writer, stack, head.*, section, inverted);
    }
    if (info == .optional) {
        if (head) |h| return trySectionCommitFromHead(writer, stack, h, section, inverted);
        return false;
    }
    if (info != .@"struct" or info.@"struct".is_tuple) return false;
    inline for (info.@"struct".fields) |f| {
        if (std.mem.eql(u8, f.name, section.path[0])) {
            try descendStrictForSection(writer, stack, @field(head, f.name), section.path[1..], section, inverted);
            return true;
        }
    }
    return false;
}

fn descendStrictForSection(
    writer: anytype,
    stack: anytype,
    value: anytype,
    rest: []const []const u8,
    section: ast.Node.Section,
    inverted: bool,
) !void {
    if (rest.len == 0) {
        try dispatchSection(writer, stack, value, section, inverted);
        return;
    }
    const T = @TypeOf(value);
    const info = @typeInfo(T);
    if (info == .pointer and info.pointer.size == .one) {
        return descendStrictForSection(writer, stack, value.*, rest, section, inverted);
    }
    if (info == .optional) {
        if (value) |v| return descendStrictForSection(writer, stack, v, rest, section, inverted);
        if (inverted) try renderNodes(section.body, writer, stack);
        return;
    }
    if (info != .@"struct" or info.@"struct".is_tuple) {
        if (inverted) try renderNodes(section.body, writer, stack);
        return;
    }
    inline for (info.@"struct".fields) |f| {
        if (std.mem.eql(u8, f.name, rest[0])) {
            return descendStrictForSection(writer, stack, @field(value, f.name), rest[1..], section, inverted);
        }
    }
    if (inverted) try renderNodes(section.body, writer, stack);
}

fn dispatchSection(
    writer: anytype,
    stack: anytype,
    value: anytype,
    section: ast.Node.Section,
    inverted: bool,
) !void {
    if (inverted) {
        if (isFalsy(value)) try renderNodes(section.body, writer, stack);
        return;
    }

    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .bool => {
            if (value) try renderNodes(section.body, writer, stack);
        },
        .optional => {
            if (value) |v| try dispatchSection(writer, stack, v, section, false);
        },
        .int, .comptime_int, .float, .comptime_float => {
            if (value != 0) try renderNodes(section.body, writer, .{ value, stack });
        },
        .pointer => |p| {
            if (p.size == .slice) {
                if (p.child == u8) {
                    if (value.len > 0) try renderNodes(section.body, writer, .{ value, stack });
                } else {
                    for (value) |item| {
                        try renderNodes(section.body, writer, .{ item, stack });
                    }
                }
            } else if (p.size == .one) {
                try dispatchSection(writer, stack, value.*, section, false);
            } else {
                @compileError("unsupported section pointer kind: " ++ @typeName(T));
            }
        },
        .array => |a| {
            if (a.child == u8) {
                const slice: []const u8 = value[0..];
                if (slice.len > 0) try renderNodes(section.body, writer, .{ slice, stack });
            } else {
                for (value) |item| {
                    try renderNodes(section.body, writer, .{ item, stack });
                }
            }
        },
        .@"struct" => {
            try renderNodes(section.body, writer, .{ value, stack });
        },
        else => @compileError("unsupported section value type: " ++ @typeName(T)),
    }
}

fn isFalsy(value: anytype) bool {
    const T = @TypeOf(value);
    return switch (@typeInfo(T)) {
        .bool => !value,
        .optional => if (value) |v| isFalsy(v) else true,
        .int, .comptime_int, .float, .comptime_float => value == 0,
        .pointer => |p| if (p.size == .slice) value.len == 0 else false,
        .array => |a| a.len == 0,
        .@"struct" => false,
        else => false,
    };
}

// ----- value writer -----

fn writeValue(writer: anytype, value: anytype, do_escape: bool) !void {
    const T = @TypeOf(value);
    switch (@typeInfo(T)) {
        .int, .comptime_int => try writer.print("{d}", .{value}),
        .float, .comptime_float => try writer.print("{d}", .{value}),
        .bool => try writer.writeAll(if (value) "true" else "false"),
        .optional => {
            if (value) |v| try writeValue(writer, v, do_escape);
        },
        .pointer => |p| {
            if (p.size == .slice and p.child == u8) {
                if (do_escape) try escape.html(writer, value) else try writer.writeAll(value);
            } else if (p.size == .one) {
                try writeValue(writer, value.*, do_escape);
            } else {
                @compileError("unrenderable pointer type: " ++ @typeName(T));
            }
        },
        .array => |a| {
            if (a.child == u8) {
                const slice: []const u8 = value[0..];
                if (do_escape) try escape.html(writer, slice) else try writer.writeAll(slice);
            } else {
                @compileError("unrenderable array type: " ++ @typeName(T));
            }
        },
        else => @compileError("unrenderable value type: " ++ @typeName(T)),
    }
}

// ----- tests -----

const parser = @import("parser.zig");

fn renderToBuf(comptime cap: usize, source: []const u8, ctx: anytype) ![]const u8 {
    var buf: [cap]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var t = try parser.parse(std.testing.allocator, source);
    defer t.deinit();
    try render(t, fbs.writer(), ctx);
    return std.testing.allocator.dupe(u8, fbs.getWritten());
}

test "renders against a struct via comptime reflection" {
    const got = try renderToBuf(256, "Hello, {{name}}! You are {{age}}.", .{
        .name = @as([]const u8, "Aleem"),
        .age = @as(u32, 30),
    });
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("Hello, Aleem! You are 30.", got);
}

test "escapes by default and unescapes with triple" {
    const got = try renderToBuf(256, "esc:{{x}} raw:{{{x}}}", .{
        .x = @as([]const u8, "<b>&</b>"),
    });
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("esc:&lt;b&gt;&amp;&lt;/b&gt; raw:<b>&</b>", got);
}

test "missing variable renders as empty" {
    const got = try renderToBuf(64, "[{{nope}}]", .{ .name = @as([]const u8, "x") });
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("[]", got);
}

test "section over bool true renders once" {
    const got = try renderToBuf(64, "{{#ok}}yes{{/ok}}", .{ .ok = true });
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("yes", got);
}

test "inverted section over bool false renders" {
    const got = try renderToBuf(64, "{{^ok}}no{{/ok}}", .{ .ok = false });
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("no", got);
}

test "inverted section over missing name renders" {
    const got = try renderToBuf(64, "{{^absent}}none{{/absent}}", .{ .other = true });
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("none", got);
}

test "section iterates over a slice with implicit ." {
    const items = [_][]const u8{ "a", "b", "c" };
    const got = try renderToBuf(64, "{{#xs}}[{{.}}]{{/xs}}", .{ .xs = @as([]const []const u8, &items) });
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("[a][b][c]", got);
}

test "section over list of structs with parent-scope fallback" {
    const Item = struct { label: []const u8 };
    const items = [_]Item{ .{ .label = "x" }, .{ .label = "y" } };
    const got = try renderToBuf(
        256,
        "{{#items}}{{prefix}}-{{label}};{{/items}}",
        .{ .prefix = @as([]const u8, "p"), .items = @as([]const Item, &items) },
    );
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("p-x;p-y;", got);
}

test "dotted path resolves on a struct field" {
    const got = try renderToBuf(128, "{{user.name}}", .{
        .user = .{ .name = @as([]const u8, "Aleem") },
    });
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("Aleem", got);
}

test "deep dotted path" {
    const got = try renderToBuf(128, "{{user.address.city}}", .{
        .user = .{ .address = .{ .city = @as([]const u8, "Lagos") } },
    });
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("Lagos", got);
}

test "dotted path with missing tail renders empty" {
    const got = try renderToBuf(64, "[{{user.nope}}]", .{
        .user = .{ .name = @as([]const u8, "Aleem") },
    });
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("[]", got);
}

test "dotted section descends and pushes" {
    const got = try renderToBuf(128, "{{#user.address}}{{city}}{{/user.address}}", .{
        .user = .{ .address = .{ .city = @as([]const u8, "Lagos") } },
    });
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("Lagos", got);
}

test "empty list is falsy" {
    const empty: []const []const u8 = &.{};
    const got = try renderToBuf(64, "{{#xs}}skip{{/xs}}{{^xs}}empty{{/xs}}", .{ .xs = empty });
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("empty", got);
}
