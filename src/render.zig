const std = @import("std");
const ast = @import("ast.zig");
const escape = @import("escape.zig");

pub const RenderError = error{MissingField};

pub fn render(template: ast.Template, writer: anytype, context: anytype) !void {
    for (template.nodes) |node| {
        switch (node) {
            .text => |t| try writer.writeAll(t),
            .variable => |v| try renderField(writer, context, v.name, v.escape),
        }
    }
}

fn renderField(
    writer: anytype,
    context: anytype,
    name: []const u8,
    do_escape: bool,
) !void {
    const T = @TypeOf(context);
    const info = @typeInfo(T);
    if (info != .@"struct") {
        @compileError("mustache context must be a struct, got " ++ @typeName(T));
    }

    inline for (info.@"struct".fields) |f| {
        if (std.mem.eql(u8, f.name, name)) {
            return writeValue(writer, @field(context, f.name), do_escape);
        }
    }
    return error.MissingField;
}

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

const parser = @import("parser.zig");

test "renders against a struct via comptime reflection" {
    var t = try parser.parse(std.testing.allocator, "Hello, {{name}}! You are {{age}}.");
    defer t.deinit();

    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    const ctx = .{ .name = @as([]const u8, "Aleem"), .age = @as(u32, 30) };
    try render(t, fbs.writer(), ctx);

    try std.testing.expectEqualStrings("Hello, Aleem! You are 30.", fbs.getWritten());
}

test "escapes by default and unescapes with triple" {
    var t = try parser.parse(std.testing.allocator, "esc:{{x}} raw:{{{x}}}");
    defer t.deinit();

    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    const ctx = .{ .x = @as([]const u8, "<b>&</b>") };
    try render(t, fbs.writer(), ctx);

    try std.testing.expectEqualStrings("esc:&lt;b&gt;&amp;&lt;/b&gt; raw:<b>&</b>", fbs.getWritten());
}

test "missing field returns an error" {
    var t = try parser.parse(std.testing.allocator, "{{nope}}");
    defer t.deinit();

    var buf: [16]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    const ctx = .{ .name = @as([]const u8, "x") };
    try std.testing.expectError(error.MissingField, render(t, fbs.writer(), ctx));
}

test "renders optionals (null elides, some unwraps)" {
    var t = try parser.parse(std.testing.allocator, "[{{a}}][{{b}}]");
    defer t.deinit();

    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    const a: ?[]const u8 = "yes";
    const b: ?[]const u8 = null;
    try render(t, fbs.writer(), .{ .a = a, .b = b });

    try std.testing.expectEqualStrings("[yes][]", fbs.getWritten());
}

test "renders bools" {
    var t = try parser.parse(std.testing.allocator, "{{ok}}");
    defer t.deinit();

    var buf: [16]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);

    try render(t, fbs.writer(), .{ .ok = true });
    try std.testing.expectEqualStrings("true", fbs.getWritten());
}
