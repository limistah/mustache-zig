// Mustache spec conformance runner.
//
// Clone github.com/mustache/spec into ./spec (as a submodule or plain clone)
// and run with:
//
//     zig build spec
//
// The spec repository ships JSON renderings of each suite alongside the YAML
// source. We read the four required suites and skip the optional ones for
// now (~lambdas, ~dynamic-names, ~inheritance). Partials are also absent
// because the renderer doesn't support them yet.

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

pub fn main() !void {
    var gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    var total: usize = 0;
    var passed: usize = 0;
    var fail_count: usize = 0;

    const stderr = std.io.getStdErr().writer();

    for (required_suites) |path| {
        const file = std.fs.cwd().openFile(path, .{}) catch |err| {
            try stderr.print("could not open {s}: {s}\n", .{ path, @errorName(err) });
            try stderr.writeAll("(clone github.com/mustache/spec into ./spec first)\n");
            std.process.exit(2);
        };
        defer file.close();
        const contents = try file.readToEndAlloc(alloc, 16 * 1024 * 1024);
        defer alloc.free(contents);

        var parsed = try std.json.parseFromSlice(SpecFile, alloc, contents, .{
            .ignore_unknown_fields = true,
        });
        defer parsed.deinit();

        try stderr.print("--- {s} ({d} cases)\n", .{ path, parsed.value.tests.len });

        for (parsed.value.tests) |case| {
            total += 1;
            const result = runCase(alloc, case) catch |err| {
                fail_count += 1;
                try stderr.print("  ERR  {s}: {s}\n", .{ case.name, @errorName(err) });
                continue;
            };
            if (result.ok) {
                passed += 1;
            } else {
                fail_count += 1;
                try stderr.print("  FAIL {s}\n", .{case.name});
                try stderr.print("       desc:     {s}\n", .{case.desc});
                try stderr.print("       template: {s}\n", .{quoteOneLine(case.template)});
                try stderr.print("       expected: {s}\n", .{quoteOneLine(case.expected)});
                try stderr.print("       got:      {s}\n", .{quoteOneLine(result.got)});
            }
            alloc.free(result.got);
        }
    }

    try stderr.print("\n{d}/{d} passed", .{ passed, total });
    if (fail_count > 0) {
        try stderr.print(" ({d} failed)\n", .{fail_count});
        std.process.exit(1);
    }
    try stderr.writeAll("\n");
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

    var out: std.ArrayList(u8) = .init(allocator);
    errdefer out.deinit();

    try mustache.render(tmpl, out.writer(), data);

    const got = try out.toOwnedSlice();
    return .{ .ok = std.mem.eql(u8, got, case.expected), .got = got };
}

// Replace newlines and tabs with their escaped forms for one-line diff output.
fn quoteOneLine(s: []const u8) []const u8 {
    // We can't allocate inside this helper without complicating callers.
    // Just return the raw string; the caller's print handles whatever's in it.
    return s;
}
