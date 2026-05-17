// Mustache spec conformance runner.
//
// Clone github.com/mustache/spec into ./spec and run with:
//
//     zig build spec
//
// Reads the four required suites from the spec repo's checked-in JSON
// renditions. Partials, delimiters, and lambdas are deferred.

const std = @import("std");
const mustache = @import("mustache");

const required_suites = [_][]const u8{
    "spec/specs/comments.json",
    "spec/specs/interpolation.json",
    "spec/specs/sections.json",
    "spec/specs/inverted.json",
};

const SpecFile = struct {
    overview: []const u8 = "",
    tests: []const SpecCase,
};

const SpecCase = struct {
    name: []const u8,
    desc: []const u8 = "",
    data: std.json.Value,
    template: []const u8,
    expected: []const u8,
};

pub fn main(init: std.process.Init) !void {
    const alloc = init.gpa;
    const io = init.io;

    var err_buf: [4096]u8 = undefined;
    var err_writer = std.Io.File.stderr().writer(io, &err_buf);
    const err = &err_writer.interface;
    defer err.flush() catch {};

    var total: usize = 0;
    var passed: usize = 0;
    var fail_count: usize = 0;

    for (required_suites) |path| {
        const cwd = std.Io.Dir.cwd();
        const file = cwd.openFile(io, path, .{}) catch |e| {
            try err.print("could not open {s}: {s}\n", .{ path, @errorName(e) });
            try err.writeAll("(clone github.com/mustache/spec into ./spec first)\n");
            try err.flush();
            std.process.exit(2);
        };
        defer file.close(io);
        const len_u64 = try file.length(io);
        const len: usize = @intCast(len_u64);
        const contents = try alloc.alloc(u8, len);
        defer alloc.free(contents);
        _ = try file.readPositionalAll(io, contents, 0);

        var parsed = try std.json.parseFromSlice(SpecFile, alloc, contents, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        try err.print("--- {s} ({d} cases)\n", .{ path, parsed.value.tests.len });

        for (parsed.value.tests) |case| {
            total += 1;
            const result = runCase(alloc, case) catch |e| {
                fail_count += 1;
                try err.print("  ERR  {s}: {s}\n", .{ case.name, @errorName(e) });
                continue;
            };
            if (result.ok) {
                passed += 1;
            } else {
                fail_count += 1;
                try err.print("  FAIL {s}\n    desc:     {s}\n    template: {s}\n    expected: {s}\n    got:      {s}\n", .{
                    case.name,
                    case.desc,
                    case.template,
                    case.expected,
                    result.got,
                });
            }
            alloc.free(result.got);
        }
    }

    try err.print("\n{d}/{d} passed", .{ passed, total });
    if (fail_count > 0) {
        try err.print(" ({d} failed)\n", .{fail_count});
        try err.flush();
        std.process.exit(1);
    }
    try err.writeAll("\n");
}

const CaseResult = struct {
    ok: bool,
    got: []u8,
};

fn runCase(allocator: std.mem.Allocator, case: SpecCase) !CaseResult {
    var tmpl = try mustache.parse(allocator, case.template);
    defer tmpl.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const data = try mustache.valueFromJson(arena.allocator(), case.data);

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try mustache.render(tmpl, &aw.writer, data);

    const got = try aw.toOwnedSlice();
    return .{ .ok = std.mem.eql(u8, got, case.expected), .got = got };
}
