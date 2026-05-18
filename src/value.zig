const std = @import("std");

// Dynamic Mustache value. The comptime/struct path is still preferred when
// the data shape is known; Value is for JSON-style data assembled at runtime.
pub const Value = union(enum) {
    null,
    bool: bool,
    int: i64,
    float: f64,
    string: []const u8,
    list: []const Value,
    object: []const Field,
    lambda: Lambda,

    pub const Field = struct {
        key: []const u8,
        value: Value,
    };

    // A Mustache 1.4 lambda. `call` is invoked at render time:
    //   - For variable interpolation, `section_text` is null and the
    //     return value is parsed as a fresh Mustache template using the
    //     default {{ }} delimiters.
    //   - For section invocation, `section_text` is the raw source text
    //     between the section's opening and closing tags. The return
    //     value is parsed using the delimiters currently in effect at
    //     the section's site.
    // The caller (renderer) owns the returned slice and must free it with
    // the same allocator.
    pub const Lambda = struct {
        ctx: *anyopaque,
        callFn: *const fn (
            ctx: *anyopaque,
            gpa: std.mem.Allocator,
            section_text: ?[]const u8,
        ) std.mem.Allocator.Error![]u8,

        pub fn call(
            self: Lambda,
            gpa: std.mem.Allocator,
            section_text: ?[]const u8,
        ) std.mem.Allocator.Error![]u8 {
            return self.callFn(self.ctx, gpa, section_text);
        }
    };

    pub fn lookup(self: Value, key: []const u8) ?Value {
        return switch (self) {
            .object => |fields| for (fields) |f| {
                if (std.mem.eql(u8, f.key, key)) break f.value;
            } else null,
            else => null,
        };
    }
};

pub const FromJsonError = std.mem.Allocator.Error;

// Convert a std.json.Value tree into a Value tree. The output uses the
// provided allocator (typically an arena) for new allocations; string slices
// from the input are referenced, not copied — keep the json source alive.
pub fn fromJson(allocator: std.mem.Allocator, json: std.json.Value) FromJsonError!Value {
    return switch (json) {
        .null => .null,
        .bool => |b| .{ .bool = b },
        .integer => |i| .{ .int = i },
        .float => |f| .{ .float = f },
        .number_string => |s| .{ .string = s },
        .string => |s| .{ .string = s },
        .array => |arr| blk: {
            const xs = try allocator.alloc(Value, arr.items.len);
            for (arr.items, 0..) |item, i| xs[i] = try fromJson(allocator, item);
            break :blk .{ .list = xs };
        },
        .object => |obj| blk: {
            const fields = try allocator.alloc(Value.Field, obj.count());
            var it = obj.iterator();
            var idx: usize = 0;
            while (it.next()) |entry| : (idx += 1) {
                fields[idx] = .{
                    .key = entry.key_ptr.*,
                    .value = try fromJson(allocator, entry.value_ptr.*),
                };
            }
            break :blk .{ .object = fields };
        },
    };
}

// Construct a JSON-to-Value adapter that replaces any object containing
// {"__tag__": "code", ...} with `replacement` (typically a Lambda). Matches
// the Mustache lambda spec's per-language code-source data layout. The
// `replacement` should be a `.lambda` Value built by the caller.
pub fn fromJsonWithCodeReplacement(
    allocator: std.mem.Allocator,
    json: std.json.Value,
    replacement: Value,
) FromJsonError!Value {
    return switch (json) {
        .null => .null,
        .bool => |b| .{ .bool = b },
        .integer => |i| .{ .int = i },
        .float => |f| .{ .float = f },
        .number_string => |s| .{ .string = s },
        .string => |s| .{ .string = s },
        .array => |arr| blk: {
            const xs = try allocator.alloc(Value, arr.items.len);
            for (arr.items, 0..) |item, i|
                xs[i] = try fromJsonWithCodeReplacement(allocator, item, replacement);
            break :blk .{ .list = xs };
        },
        .object => |obj| blk: {
            // Detect __tag__ == "code" — the spec's lambda marker.
            if (obj.get("__tag__")) |tag| {
                if (tag == .string and std.mem.eql(u8, tag.string, "code")) {
                    break :blk replacement;
                }
            }
            const fields = try allocator.alloc(Value.Field, obj.count());
            var it = obj.iterator();
            var idx: usize = 0;
            while (it.next()) |entry| : (idx += 1) {
                fields[idx] = .{
                    .key = entry.key_ptr.*,
                    .value = try fromJsonWithCodeReplacement(allocator, entry.value_ptr.*, replacement),
                };
            }
            break :blk .{ .object = fields };
        },
    };
}

test "lookup on object" {
    const v = Value{ .object = &[_]Value.Field{
        .{ .key = "a", .value = .{ .int = 1 } },
        .{ .key = "b", .value = .{ .string = "x" } },
    } };
    try std.testing.expectEqual(@as(i64, 1), v.lookup("a").?.int);
    try std.testing.expectEqualStrings("x", v.lookup("b").?.string);
    try std.testing.expectEqual(@as(?Value, null), v.lookup("c"));
}

test "lookup on non-object returns null" {
    const v = Value{ .int = 7 };
    try std.testing.expectEqual(@as(?Value, null), v.lookup("a"));
}
