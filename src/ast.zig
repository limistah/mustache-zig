const std = @import("std");

pub const Node = union(enum) {
    text: []const u8,
    variable: Variable,
    section: Section,
    inverted: Section,

    pub const Variable = struct {
        path: []const []const u8,
        escape: bool,
    };

    pub const Section = struct {
        path: []const []const u8,
        body: []const Node,
    };
};

pub const Template = struct {
    nodes: []const Node,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Template) void {
        self.arena.deinit();
    }
};
