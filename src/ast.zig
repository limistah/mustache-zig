const std = @import("std");

pub const Node = union(enum) {
    text: []const u8,
    variable: Variable,

    pub const Variable = struct {
        name: []const u8,
        escape: bool,
    };
};

pub const Template = struct {
    nodes: []const Node,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Template) void {
        self.arena.deinit();
    }
};
