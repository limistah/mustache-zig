const std = @import("std");

pub const Node = union(enum) {
    text: []const u8,
    variable: Variable,
    section: Section,
    inverted: Section,
    partial: Partial,
    block: Block,
    parent: ParentInvocation,

    pub const Variable = struct {
        path: []const []const u8,
        escape: bool,
    };

    pub const Section = struct {
        path: []const []const u8,
        body: []const Node,
    };

    // {{$name}}default{{/name}} — overridable named block.
    //
    // `indent` is the block's intrinsic indent (leading whitespace on its
    // line in the source). When the block expands a multi-line override or
    // default body, this indent is prepended after every newline so each
    // rendered line aligns with the block tag's column.
    pub const Block = struct {
        name: []const u8,
        body: []const Node,
        indent: []const u8 = "",
    };

    // {{<parent}}...{{/parent}} — invokes a partial as a "parent template",
    // where the invocation body contains {{$block}} overrides that replace
    // matching blocks in the parent. Mustache 1.4 inheritance feature.
    pub const ParentInvocation = struct {
        name: []const u8,
        indent: []const u8,
        overrides: []const Block,
    };

    pub const Partial = struct {
        // For static partials ({{>name}}), `name` is the literal partial name
        // and `path` is empty. For dynamic partials ({{>*key.path}}, Mustache
        // 1.4), `path` is the dotted lookup path resolved against context to
        // obtain the actual partial name at render time, and `name` holds the
        // raw lookup string (unused at render).
        name: []const u8,
        path: []const []const u8,
        indent: []const u8,
        dynamic: bool,
    };
};

pub const Template = struct {
    nodes: []const Node,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(self: *Template) void {
        self.arena.deinit();
    }
};
