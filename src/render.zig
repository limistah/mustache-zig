const std = @import("std");
const ast = @import("ast.zig");
const escape = @import("escape.zig");

// Context stack representation:
//   empty stack:        .{}
//   one-frame stack:    .{ ctx, .{} }
//   two-frame stack:    .{ inner, .{ outer, .{} } }
//
// Lookups walk innermost -> outermost. Sections that match by name push the
// matched value as a new innermost frame and recurse into the body.

pub fn render(template: ast.Template, writer: anytype, context: anytype) !void {
    return renderNodes(template.nodes, writer, .{ context, .{} });
}

fn renderNodes(nodes: []const ast.Node, writer: anytype, stack: anytype) !void {
    for (nodes) |node| {
        switch (node) {
            .text => |t| try writer.writeAll(t),
            .variable => |v| try lookupAndWrite(writer, stack, v.name, v.escape),
            .section => |s| try renderSection(writer, stack, s, false),
            .inverted => |s| try renderSection(writer, stack, s, true),
        }
    }
}

// ----- variable lookup -----

fn lookupAndWrite(writer: anytype, stack: anytype, name: []const u8, do_escape: bool) !void {
    if (@typeInfo(@TypeOf(stack)).@"struct".fields.len == 0) return; // not found, emit nothing
    if (try tryWriteFromFrame(writer, stack[0], name, do_escape)) return;
    return lookupAndWrite(writer, stack[1], name, do_escape);
}

fn tryWriteFromFrame(writer: anytype, frame: anytype, name: []const u8, do_escape: bool) !bool {
    // implicit iterator: {{.}} writes the current frame itself
    if (name.len == 1 and name[0] == '.') {
        try writeValue(writer, frame, do_escape);
        return true;
    }
    const T = @TypeOf(frame);
    const info = @typeInfo(T);
    if (info == .@"struct" and !info.@"struct".is_tuple) {
        inline for (info.@"struct".fields) |f| {
            if (std.mem.eql(u8, f.name, name)) {
                try writeValue(writer, @field(frame, f.name), do_escape);
                return true;
            }
        }
    }
    return false;
}

// ----- section lookup + dispatch -----

fn renderSection(writer: anytype, stack: anytype, section: ast.Node.Section, inverted: bool) !void {
    if (try trySection(writer, stack, stack, section, inverted)) return;
    // not found anywhere: spec says falsy
    if (inverted) try renderNodes(section.body, writer, stack);
}

fn trySection(
    writer: anytype,
    original: anytype,
    search: anytype,
    section: ast.Node.Section,
    inverted: bool,
) !bool {
    const SInfo = @typeInfo(@TypeOf(search)).@"struct";
    if (SInfo.fields.len == 0) return false;

    const frame = search[0];
    const T = @TypeOf(frame);
    const info = @typeInfo(T);

    if (info == .@"struct" and !info.@"struct".is_tuple) {
        inline for (info.@"struct".fields) |f| {
            if (std.mem.eql(u8, f.name, section.name)) {
                try dispatchSection(writer, original, @field(frame, f.name), section, inverted);
                return true;
            }
        }
    }
    return trySection(writer, original, search[1], section, inverted);
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
    const owned = try std.testing.allocator.dupe(u8, fbs.getWritten());
    return owned;
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

test "optional null renders empty, some unwraps" {
    const a: ?[]const u8 = "yes";
    const b: ?[]const u8 = null;
    const got = try renderToBuf(64, "[{{a}}][{{b}}]", .{ .a = a, .b = b });
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("[yes][]", got);
}

test "section over bool true renders once" {
    const got = try renderToBuf(64, "{{#ok}}yes{{/ok}}", .{ .ok = true });
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("yes", got);
}

test "section over bool false skips" {
    const got = try renderToBuf(64, "{{#ok}}yes{{/ok}}!", .{ .ok = false });
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("!", got);
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

test "section iterates over a slice with implicit .{}" {
    const items = [_][]const u8{ "a", "b", "c" };
    const got = try renderToBuf(64, "{{#xs}}[{{.}}]{{/xs}}", .{ .xs = @as([]const []const u8, &items) });
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("[a][b][c]", got);
}

test "section iterates over a slice of structs and falls back to parent scope" {
    const Item = struct { label: []const u8 };
    const items = [_]Item{ .{ .label = "x" }, .{ .label = "y" } };
    const got = try renderToBuf(
        256,
        "{{#items}}{{prefix}}-{{label}};{{/items}}",
        .{
            .prefix = @as([]const u8, "p"),
            .items = @as([]const Item, &items),
        },
    );
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("p-x;p-y;", got);
}

test "nested struct section pushes scope" {
    const got = try renderToBuf(128, "{{#user}}{{name}} ({{age}}){{/user}}", .{
        .user = .{ .name = @as([]const u8, "Aleem"), .age = @as(u32, 30) },
    });
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("Aleem (30)", got);
}

test "empty list is falsy" {
    const empty: []const []const u8 = &.{};
    const got = try renderToBuf(64, "{{#xs}}skip{{/xs}}{{^xs}}empty{{/xs}}", .{ .xs = empty });
    defer std.testing.allocator.free(got);
    try std.testing.expectEqualStrings("empty", got);
}
