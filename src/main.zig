const std = @import("std");
const mustache = @import("mustache");

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const source = "Hello, {{name}}!\nAge: {{age}}\nBio (escaped): {{bio}}\nBio (raw):     {{{bio}}}\n";

    var tmpl = try mustache.parse(alloc, source);
    defer tmpl.deinit();

    const ctx = .{
        .name = @as([]const u8, "Aleem"),
        .age = @as(u32, 30),
        .bio = @as([]const u8, "<b>builder</b> & shipper"),
    };

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try mustache.render(tmpl, fbs.writer(), ctx);

    const stdout = std.io.getStdOut();
    _ = try stdout.writeAll(fbs.getWritten());
}
