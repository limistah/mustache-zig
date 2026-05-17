// Mustache spec conformance runner.
//
//     git clone https://github.com/mustache/spec mustache-zig/spec
//     zig build spec

const std = @import("std");
const mustache = @import("mustache");

const required_suites = [_][]const u8{
    "spec/specs/comments.json",
    "spec/specs/interpolation.json",
    "spec/specs/sections.json",
    "spec/specs/inverted.json",
    "spec/specs/delimiters.json",
    "spec/specs/partials.json",
    "spec/specs/~dynamic-names.json",
};

// Optional suites: we try to pass these but failures are reported as warnings
// and do not fail the build. They cover Mustache 1.4 features (inheritance,
// lambdas) where partial support is acceptable for a v0.x release.
const optional_suites = [_][]const u8{
    "spec/specs/~inheritance.json",
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
    partials: ?std.json.Value = null,
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
    var optional_total: usize = 0;
    var optional_passed: usize = 0;
    var optional_fails: usize = 0;

    const Suite = struct { path: []const u8, optional: bool };
    var suites: std.ArrayList(Suite) = .empty;
    defer suites.deinit(alloc);
    for (required_suites) |p| try suites.append(alloc, .{ .path = p, .optional = false });
    for (optional_suites) |p| try suites.append(alloc, .{ .path = p, .optional = true });

    for (suites.items) |suite| {
        const path = suite.path;
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

        const tag = if (suite.optional) "(optional)" else "";
        try err.print("--- {s} ({d} cases) {s}\n", .{ path, parsed.value.tests.len, tag });

        for (parsed.value.tests) |case| {
            if (suite.optional) optional_total += 1 else total += 1;
            const result = runCase(alloc, case) catch |e| {
                if (suite.optional) optional_fails += 1 else fail_count += 1;
                try err.print("  ERR  {s}: {s}\n", .{ case.name, @errorName(e) });
                continue;
            };
            if (result.ok) {
                if (suite.optional) optional_passed += 1 else passed += 1;
            } else {
                if (suite.optional) optional_fails += 1 else fail_count += 1;
                try err.print("  FAIL {s}\n    desc:     {s}\n    template: {s}\n    expected: {s}\n    got:      {s}\n", .{
                    case.name, case.desc, case.template, case.expected, result.got,
                });
            }
            alloc.free(result.got);
        }
    }

    try err.print("\nrequired: {d}/{d} passed", .{ passed, total });
    if (fail_count > 0) try err.print(" ({d} failed)", .{fail_count});
    if (optional_total > 0) {
        try err.print("\noptional: {d}/{d} passed", .{ optional_passed, optional_total });
        if (optional_fails > 0) try err.print(" ({d} failed; informational only)", .{optional_fails});
    }
    try err.writeAll("\n");
    if (fail_count > 0) std.process.exit(1);
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

    // Build a Partials map by parsing each partial source.
    var partials: mustache.Partials = .init(allocator);
    defer {
        var it = partials.iterator();
        while (it.next()) |entry| entry.value_ptr.deinit();
        partials.deinit();
    }
    if (case.partials) |pjson| if (pjson == .object) {
        var it = pjson.object.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* != .string) continue;
            const p = try mustache.parse(allocator, entry.value_ptr.string);
            try partials.put(entry.key_ptr.*, p);
        }
    };

    var aw: std.Io.Writer.Allocating = .init(allocator);
    errdefer aw.deinit();
    try mustache.renderWithPartials(tmpl, &aw.writer, data, &partials);

    const got = try aw.toOwnedSlice();
    return .{ .ok = std.mem.eql(u8, got, case.expected), .got = got };
}
