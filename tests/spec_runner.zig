// Mustache spec conformance runner.
//
//     git clone https://github.com/mustache/spec mustache-zig/spec
//     zig build spec
//
// Lambda harness: each lambda spec test stores per-language source code in
// its data object (under __tag__: "code"). We register a hand-written Zig
// implementation per test name, substitute the matching Lambda Value into
// the parsed JSON tree, and let the renderer drive the rest.

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
    "spec/specs/~inheritance.json",
    "spec/specs/~lambdas.json",
};

const optional_suites = [_][]const u8{};

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
            // Reset any per-test lambda state before each case.
            multi_call_counter = 0;

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
    const aalloc = arena.allocator();

    // Build the test's Value tree, substituting any __tag__: "code"
    // objects with a Lambda bound to this test's handler.
    const lambda_replacement: mustache.Value = blk: {
        const handler = lambdaForCase(case.name) orelse break :blk .null;
        // Allocate the lambda's per-call context in the arena so its
        // pointer is stable for the duration of this case.
        const ctx_ptr = try aalloc.create(LambdaCtx);
        ctx_ptr.* = .{ .handler = handler };
        break :blk .{ .lambda = .{ .ctx = ctx_ptr, .callFn = lambdaTrampoline } };
    };
    const data = try mustache.valueFromJsonWithCodeReplacement(aalloc, case.data, lambda_replacement);

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
    try mustache.renderEx(tmpl, &aw.writer, data, .{
        .partials = &partials,
        .allocator = aalloc,
    });

    const got = try aw.toOwnedSlice();
    return .{ .ok = std.mem.eql(u8, got, case.expected), .got = got };
}

// ----- lambda harness -----

const LambdaHandler = *const fn (gpa: std.mem.Allocator, section_text: ?[]const u8) std.mem.Allocator.Error![]u8;

const LambdaCtx = struct {
    handler: LambdaHandler,
};

fn lambdaTrampoline(
    ctx_raw: *anyopaque,
    gpa: std.mem.Allocator,
    section_text: ?[]const u8,
) std.mem.Allocator.Error![]u8 {
    const ctx: *LambdaCtx = @ptrCast(@alignCast(ctx_raw));
    return ctx.handler(gpa, section_text);
}

// Shared mutable state for the "Multiple Calls" tests. Reset before each
// case in main().
var multi_call_counter: i64 = 0;

fn lambdaForCase(name: []const u8) ?LambdaHandler {
    const Pair = struct { name: []const u8, fn_: LambdaHandler };
    const map = [_]Pair{
        .{ .name = "Interpolation", .fn_ = lambdaInterpolation },
        .{ .name = "Interpolation - Expansion", .fn_ = lambdaInterpolationExpansion },
        .{ .name = "Interpolation - Alternate Delimiters", .fn_ = lambdaInterpolationAltDelim },
        .{ .name = "Interpolation - Multiple Calls", .fn_ = lambdaMultipleCalls },
        .{ .name = "Escaping", .fn_ = lambdaEscaping },
        .{ .name = "Section", .fn_ = lambdaSection },
        .{ .name = "Section - Expansion", .fn_ = lambdaSectionExpansion },
        .{ .name = "Section - Alternate Delimiters", .fn_ = lambdaSectionAltDelim },
        .{ .name = "Section - Multiple Calls", .fn_ = lambdaSectionMultipleCalls },
        .{ .name = "Inverted Section", .fn_ = lambdaInvertedSection },
    };
    for (map) |p| if (std.mem.eql(u8, p.name, name)) return p.fn_;
    return null;
}

// ruby: proc { "world" }
fn lambdaInterpolation(gpa: std.mem.Allocator, section_text: ?[]const u8) ![]u8 {
    _ = section_text;
    return gpa.dupe(u8, "world");
}

// ruby: proc { "{{planet}}" }
fn lambdaInterpolationExpansion(gpa: std.mem.Allocator, section_text: ?[]const u8) ![]u8 {
    _ = section_text;
    return gpa.dupe(u8, "{{planet}}");
}

// ruby: proc { "|planet| => {{planet}}" }
fn lambdaInterpolationAltDelim(gpa: std.mem.Allocator, section_text: ?[]const u8) ![]u8 {
    _ = section_text;
    return gpa.dupe(u8, "|planet| => {{planet}}");
}

// ruby: proc { $calls ||= 0; $calls += 1 }
fn lambdaMultipleCalls(gpa: std.mem.Allocator, section_text: ?[]const u8) ![]u8 {
    _ = section_text;
    multi_call_counter += 1;
    return std.fmt.allocPrint(gpa, "{d}", .{multi_call_counter});
}

// ruby: proc { ">" }
fn lambdaEscaping(gpa: std.mem.Allocator, section_text: ?[]const u8) ![]u8 {
    _ = section_text;
    return gpa.dupe(u8, ">");
}

// ruby: proc { |text| text == "{{x}}" ? "yes" : "no" }
fn lambdaSection(gpa: std.mem.Allocator, section_text: ?[]const u8) ![]u8 {
    const t = section_text orelse "";
    return gpa.dupe(u8, if (std.mem.eql(u8, t, "{{x}}")) "yes" else "no");
}

// ruby: proc { |text| "#{text}{{planet}}#{text}" }
fn lambdaSectionExpansion(gpa: std.mem.Allocator, section_text: ?[]const u8) ![]u8 {
    const t = section_text orelse "";
    return std.fmt.allocPrint(gpa, "{s}{{{{planet}}}}{s}", .{ t, t });
}

// ruby: proc { |text| "#{text}{{planet}} => |planet|#{text}" }
fn lambdaSectionAltDelim(gpa: std.mem.Allocator, section_text: ?[]const u8) ![]u8 {
    const t = section_text orelse "";
    return std.fmt.allocPrint(gpa, "{s}{{{{planet}}}} => |planet|{s}", .{ t, t });
}

// ruby: proc { |text| "__#{text}__" }
fn lambdaSectionMultipleCalls(gpa: std.mem.Allocator, section_text: ?[]const u8) ![]u8 {
    const t = section_text orelse "";
    return std.fmt.allocPrint(gpa, "__{s}__", .{t});
}

// ruby: proc { |text| false }
// Lambdas in inverted sections are always truthy per spec, so this body
// is never actually called by the renderer. Empty output suffices.
fn lambdaInvertedSection(gpa: std.mem.Allocator, section_text: ?[]const u8) ![]u8 {
    _ = section_text;
    return gpa.dupe(u8, "");
}
