const ast = @import("ast.zig");
const parser = @import("parser.zig");
const render_mod = @import("render.zig");
const value_mod = @import("value.zig");

pub const Template = ast.Template;
pub const Node = ast.Node;
pub const parse = parser.parse;
pub const render = render_mod.render;
pub const ParseError = parser.ParseError;
pub const Value = value_mod.Value;
pub const valueFromJson = value_mod.fromJson;
pub const escape = @import("escape.zig");

test {
    _ = @import("escape.zig");
    _ = @import("parser.zig");
    _ = @import("render.zig");
    _ = @import("value.zig");
}
