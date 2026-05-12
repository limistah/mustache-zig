const std = @import("std");
const mustache = @import("mustache");

const Item = struct { name: []const u8, price: u32 };

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const source =
        \\Hello, {{name}}!
        \\
        \\{{#items}}- {{name}}: ${{price}} (buyer: {{buyer}})
        \\{{/items}}{{^items}}(no items){{/items}}
        \\Bio: {{{bio}}}
        \\
    ;

    var tmpl = try mustache.parse(alloc, source);
    defer tmpl.deinit();

    const items = [_]Item{
        .{ .name = "keyboard", .price = 120 },
        .{ .name = "monitor", .price = 480 },
    };

    const ctx = .{
        .name = @as([]const u8, "Aleem"),
        .buyer = @as([]const u8, "Aleem"),
        .bio = @as([]const u8, "<b>builder</b> & shipper"),
        .items = @as([]const Item, &items),
    };

    var buf: [4096]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try mustache.render(tmpl, fbs.writer(), ctx);

    const stdout = std.io.getStdOut();
    try stdout.writeAll(fbs.getWritten());
}
