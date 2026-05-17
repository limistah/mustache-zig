const std = @import("std");
const mustache = @import("mustache");

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    const source =
        \\Hello, {{name}}!
        \\{{#items}}- {{name}}: ${{price}} (buyer: {{buyer}})
        \\{{/items}}{{^items}}(no items){{/items}}Bio: {{{bio}}}
        \\
    ;

    var tmpl = try mustache.parse(alloc, source);
    defer tmpl.deinit();

    // Build a Value tree.
    const item1 = [_]mustache.Value.Field{
        .{ .key = "name", .value = .{ .string = "keyboard" } },
        .{ .key = "price", .value = .{ .int = 120 } },
    };
    const item2 = [_]mustache.Value.Field{
        .{ .key = "name", .value = .{ .string = "monitor" } },
        .{ .key = "price", .value = .{ .int = 480 } },
    };
    const items = [_]mustache.Value{
        .{ .object = &item1 },
        .{ .object = &item2 },
    };
    const root = [_]mustache.Value.Field{
        .{ .key = "name", .value = .{ .string = "Aleem" } },
        .{ .key = "buyer", .value = .{ .string = "Aleem" } },
        .{ .key = "bio", .value = .{ .string = "<b>builder</b> & shipper" } },
        .{ .key = "items", .value = .{ .list = &items } },
    };

    var out_buf: [4096]u8 = undefined;
    var stdout_writer = std.Io.File.stdout().writer(io, &out_buf);
    const stdout = &stdout_writer.interface;

    try mustache.render(tmpl, stdout, .{ .object = &root });
    try stdout.flush();
}
