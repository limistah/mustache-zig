const std = @import("std");

pub const Node = union(enum) {
    text: []const u8,
    variable: Variable,
    section: Section,
    inverted: Section,
    partial: Partial,

    pub const Variable = struct {
        path: []const []const u8,
        escape: bool,
    };

    pub const Section = struct {
        path: []const []const u8,
        body: []const Node,
    };

    pub const Partial = struct {
        name: []const u8,
        // Leading whitespace of the partial tag's line if the tag was
        // standalone; empty otherwise. Per spec, this indent is prepended to
        // every line of the rendered partial.
        indent: []const u8,
    };
};

pub const Template = struct {
    nodes: []const Node,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Template) void {
        self.arena.deinit();
    }
};
