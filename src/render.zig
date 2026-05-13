const std = @import("std");
const ast = @import("ast.zig");
const escape = @import("escape.zig");
const Value = @import("value.zig").Value;

// Context stack representation:
//   empty stack:        .{}
//   one-frame stack:    .{ ctx, .{} }
//   two-frame stack:    .{ inner, .{ outer, .{} } }
//
// Frames can be user structs (resolved at comptime via @typeInfo) or a Value
// (resolved at runtime by union-tag dispatch). Both shapes can be mixed in
// the same stack.

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
    if (T == Value) return tryCommitFromValueHead(writer, head, path, do_escape);
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
            _ = try descendStrictAndWrite(writer, @field(head, f.name), path[1..], do_escape);
            return true;
        }
    }
    return false;
}

fn tryCommitFromValueHead(writer: anytype, head: Value, path: []const []const u8, do_escape: bool) !bool {
    if (head != .object) return false;
    for (head.object) |f| {
        if (std.mem.eql(u8, f.key, path[0])) {
            _ = try descendStrictAndWriteValue(writer, f.value, path[1..], do_escape);
            return true;
        }
    }
    return false;
}

fn descendStrictAndWrite(writer: anytype, value: anytype, rest: []const []const u8, do_escape: bool) !bool {
    const T = @TypeOf(value);
    if (T == Value) return descendStrictAndWriteValue(writer, value, rest, do_escape);
    if (rest.len == 0) {
        try writeValue(writer, value, do_escape);
        return true;
    }
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

fn descendStrictAndWriteValue(writer: anytype, value: Value, rest: []const []const u8, do_escape: bool) !bool {
    if (rest.len == 0) {
        try writeValueDynamic(writer, value, do_escape);
        return true;
    }
    if (value != .object) return false;
    for (value.object) |f| {
        if (std.mem.eql(u8, f.key, rest[0])) {
            return descendStrictAndWriteValue(writer, f.value, rest[1..], do_escape);
        }
    }
    return false;
}

// ----- section lookup + dispatch -----

fn renderSection(writer: anytype, stack: anytype, section: ast.Node.Section, inverted: bool) !void {
    if (try walkStackForSection(writer, stack, stack, section, inverted)) return;
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
    if (T == Value) return trySectionCommitFromValueHead(writer, stack, head, section, inverted);
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

fn trySectionCommitFromValueHead(
    writer: anytype,
    stack: anytype,
    head: Value,
    section: ast.Node.Section,
    inverted: bool,
) !bool {
    if (head != .object) return false;
    for (head.object) |f| {
        if (std.mem.eql(u8, f.key, section.path[0])) {
            try descendStrictForSectionValue(writer, stack, f.value, section.path[1..], section, inverted);
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
    const T = @TypeOf(value);
    if (T == Value) return descendStrictForSectionValue(writer, stack, value, rest, section, inverted);
    if (rest.len == 0) {
        try dispatchSection(writer, stack, value, section, inverted);
        return;
    }
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

fn descendStrictForSectionValue(
    writer: anytype,
    stack: anytype,
    value: Value,
    rest: []const []const u8,
    section: ast.Node.Section,
    inverted: bool,
) !void {
    if (rest.len == 0) {
        try dispatchSectionValue(writer, stack, value, section, inverted);
        return;
    }
    if (value != .object) {
        if (inverted) try renderNodes(section.body, writer, stack);
        return;
    }
    for (value.object) |f| {
        if (std.mem.eql(u8, f.key, rest[0])) {
            return descendStrictForSectionValue(writer, stack, f.value, rest[1..], section, inverted);
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
    const T = @TypeOf(value);
    if (T == Value) return dispatchSectionValue(writer, stack, value, section, inverted);

    if (inverted) {
        if (isFalsy(value)) try renderNodes(section.body, writer, stack);
        return;
    }

    switch (@typeInfo(T)) {
        .bool => if (value) try renderNodes(section.body, writer, stack),
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
                    for (value) |item| try renderNodes(section.body, writer, .{ item, stack });
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
                for (value) |item| try renderNodes(section.body, writer, .{ item, stack });
            }
        },
        .@"struct" => try renderNodes(section.body, writer, .{ value, stack }),
        else => @compileError("unsupported section value type: " ++ @typeName(T)),
    }
}

fn dispatchSectionValue(
    writer: anytype,
    stack: anytype,
    value: Value,
    section: ast.Node.Section,
    inverted: bool,
) !void {
    if (inverted) {
        if (isFalsyValue(value)) try renderNodes(section.body, writer, stack);
        return;
    }
    switch (value) {
        .null => {},
        .bool => |b| if (b) try renderNodes(section.body, writer, stack),
        .int => |i| if (i != 0) try renderNodes(section.body, writer, .{ value, stack }),
        .float => |f| if (f != 0) try renderNodes(section.body, writer, .{ value, stack }),
        .string => |s| if (s.len > 0) try renderNodes(section.body, writer, .{ value, stack }),
        .list => |xs| for (xs) |item| try renderNodes(section.body, writer, .{ item, stack }),
        .object => try renderNodes(section.body, writer, .{ value, stack }),
    }
}

fn isFalsy(value: anytype) bool {
    const T = @TypeOf(value);
    if (T == Value) return isFalsyValue(value);
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

fn isFalsyValue(v: Value) bool {
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

fn writeValue(writer: anytype, value: anytype, do_escape: bool) !void {
    const T = @TypeOf(value);
    if (T == Value) return writeValueDynamic(writer, value, do_escape);
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

fn writeValueDynamic(writer: anytype, value: Value, do_escape: bool) !void {
    switch (value) {
        .null => {},
        .bool => |b| try writer.writeAll(if (b) "true" else "false"),
        .int => |i| try writer.print("{d}", .{i}),
        .float => |f| try writer.print("{d}", .{f}),
        .string => |s| if (do_escape) try escape.html(writer, s) else try writer.writeAll(s),
        // writing a list/object directly is a no-op; spec leaves it
        // implementation-defined and most renderers emit nothing
        .list, .object => {},
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

test "inverted section over bool false renders" {
    const got = try renderToBuf(64, "{{^ok}}no{{/ok}}", .{ .ok = false });
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("no", got);
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

test "deep dotted path" {
    const got = try renderToBuf(128, "{{user.address.city}}", .{
        .user = .{ .address = .{ .city = @as([]const u8, "Lagos") } },
    });
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("Lagos", got);
}

test "standalone section tags don't leak newlines" {
    const got = try renderToBuf(64, "{{#ok}}\nhi\n{{/ok}}\n", .{ .ok = true });
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("hi\n", got);
}

// ----- dynamic Value tests -----

test "Value: writes a string variable" {
    const obj = Value{ .object = &[_]Value.Field{
        .{ .key = "name", .value = .{ .string = "Aleem" } },
    } };
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var t = try parser.parse(std.testing.allocator, "Hello, {{name}}!");
    defer t.deinit();
    try render(t, fbs.writer(), obj);
    try std.testing.expectEqualStrings("Hello, Aleem!", fbs.getWritten());
}

test "Value: escapes HTML by default" {
    const obj = Value{ .object = &[_]Value.Field{
        .{ .key = "x", .value = .{ .string = "<&>" } },
    } };
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var t = try parser.parse(std.testing.allocator, "{{x}} {{{x}}}");
    defer t.deinit();
    try render(t, fbs.writer(), obj);
    try std.testing.expectEqualStrings("&lt;&amp;&gt; <&>", fbs.getWritten());
}

test "Value: dotted path through nested objects" {
    const inner = [_]Value.Field{
        .{ .key = "city", .value = .{ .string = "Lagos" } },
    };
    const outer = [_]Value.Field{
        .{ .key = "user", .value = .{ .object = &[_]Value.Field{
            .{ .key = "address", .value = .{ .object = &inner } },
        } } },
    };
    const ctx = Value{ .object = &outer };

    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var t = try parser.parse(std.testing.allocator, "{{user.address.city}}");
    defer t.deinit();
    try render(t, fbs.writer(), ctx);
    try std.testing.expectEqualStrings("Lagos", fbs.getWritten());
}

test "Value: section over a list iterates with implicit ." {
    const items = [_]Value{
        .{ .string = "a" },
        .{ .string = "b" },
        .{ .string = "c" },
    };
    const obj = Value{ .object = &[_]Value.Field{
        .{ .key = "xs", .value = .{ .list = &items } },
    } };

    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var t = try parser.parse(std.testing.allocator, "{{#xs}}[{{.}}]{{/xs}}");
    defer t.deinit();
    try render(t, fbs.writer(), obj);
    try std.testing.expectEqualStrings("[a][b][c]", fbs.getWritten());
}

test "Value: inverted section over null renders body" {
    const obj = Value{ .object = &[_]Value.Field{
        .{ .key = "x", .value = .null },
    } };
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var t = try parser.parse(std.testing.allocator, "{{^x}}none{{/x}}");
    defer t.deinit();
    try render(t, fbs.writer(), obj);
    try std.testing.expectEqualStrings("none", fbs.getWritten());
}

test "Value: section over object pushes scope and parent falls back" {
    const inner = [_]Value.Field{
        .{ .key = "name", .value = .{ .string = "Aleem" } },
    };
    const outer = [_]Value.Field{
        .{ .key = "prefix", .value = .{ .string = "p" } },
        .{ .key = "user", .value = .{ .object = &inner } },
    };
    const ctx = Value{ .object = &outer };

    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    var t = try parser.parse(std.testing.allocator, "{{#user}}{{prefix}}-{{name}}{{/user}}");
    defer t.deinit();
    try render(t, fbs.writer(), ctx);
    try std.testing.expectEqualStrings("p-Aleem", fbs.getWritten());
}
