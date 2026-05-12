const std = @import("std");

pub fn html(writer: anytype, input: []const u8) !void {
    var start: usize = 0;
    for (input, 0..) |c, i| {
        const replacement: ?[]const u8 = switch (c) {
            '&' => "&amp;",
            '<' => "&lt;",
            '>' => "&gt;",
            '"' => "&quot;",
            '\'' => "&#39;",
            else => null,
        };
        if (replacement) |r| {
            if (i > start) try writer.writeAll(input[start..i]);
            try writer.writeAll(r);
            start = i + 1;
        }
    }
    if (start < input.len) try writer.writeAll(input[start..]);
}

test "escapes the five characters" {
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try html(fbs.writer(), "<a href=\"x\">it's & ok</a>");
    try std.testing.expectEqualStrings(
        "&lt;a href=&quot;x&quot;&gt;it&#39;s &amp; ok&lt;/a&gt;",
        fbs.getWritten(),
    );
}

test "passthrough for plain text" {
    var buf: [64]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try html(fbs.writer(), "hello world");
    try std.testing.expectEqualStrings("hello world", fbs.getWritten());
}

test "empty input" {
    var buf: [16]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    try html(fbs.writer(), "");
    try std.testing.expectEqualStrings("", fbs.getWritten());
}
