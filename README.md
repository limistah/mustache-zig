# mustache-zig

A spec-conformant [Mustache](https://mustache.github.io/) templating library
for Zig.

- **194 / 194** Mustache spec tests passing across **all 9 suites**, including
  the optional `~dynamic-names`, `~inheritance`, and `~lambdas` suites.
- No compromise on the spec. Standalone-line stripping, dotted paths,
  `\r\n` handling, set-delimiter, partials with the standalone-indent rule,
  multi-level block inheritance with reindentation — all covered.
- Monomorphic renderer. No `anytype` cascades, no comptime explosions; the
  whole library compiles in a couple of seconds.
- Single allocator-passed entry point, optional partials, optional lambdas.
  Use what you need.

```zig
const std = @import("std");
const mustache = @import("mustache");

pub fn main(init: std.process.Init) !void {
    var t = try mustache.parse(init.gpa, "Hello, {{name}}!");
    defer t.deinit();

    const root = [_]mustache.Value.Field{
        .{ .key = "name", .value = .{ .string = "Aleem" } },
    };

    var out_buf: [128]u8 = undefined;
    var stdout = std.Io.File.stdout().writer(init.io, &out_buf);
    try mustache.render(t, &stdout.interface, .{ .object = &root });
    try stdout.interface.flush();
}
```

## Status

| Spec suite              | Pass    | Notes                                  |
|-------------------------|---------|----------------------------------------|
| `comments`              | 12 / 12 |                                        |
| `interpolation`         | 42 / 42 |                                        |
| `sections`              | 34 / 34 |                                        |
| `inverted`              | 22 / 22 |                                        |
| `delimiters`            | 14 / 14 | `{{=<% %>=}}`                          |
| `partials`              | 12 / 12 | Including the standalone-indent rule.  |
| `~dynamic-names` (1.4)  | 21 / 21 | `{{>*key.path}}`                       |
| `~inheritance` (1.4)    | 27 / 27 | Parents, blocks, multi-level overrides.|
| `~lambdas` (1.4)        | 10 / 10 | Via a user-supplied harness.           |
| **Total**               |**194 / 194**|                                    |

Tested against Zig **0.16.0**.

## Install

mustache-zig is distributed as a Zig package. Add it to your project's
`build.zig.zon`:

```zig
.dependencies = .{
    .mustache = .{
        .url = "https://github.com/limistah/mustache-zig/archive/refs/tags/v0.4.0.tar.gz",
        // Copy the hash from the SHA256SUMS asset on the release page,
        // or run `zig fetch --save <url>` and let zig fill it in.
        .hash = "...",
    },
},
```

Then in `build.zig`:

```zig
const mustache_dep = b.dependency("mustache", .{
    .target = target,
    .optimize = optimize,
});
exe.root_module.addImport("mustache", mustache_dep.module("mustache"));
```

## The data model: `Value`

Templates render against a `Value` — a tagged union covering the eight
JSON-shaped variants plus a lambda:

```zig
pub const Value = union(enum) {
    null,
    bool: bool,
    int: i64,
    float: f64,
    string: []const u8,
    list: []const Value,
    object: []const Field,
    lambda: Lambda,
};
```

Build it however you want. For static data, array literals work fine:

```zig
const item1 = [_]mustache.Value.Field{
    .{ .key = "name",  .value = .{ .string = "keyboard" } },
    .{ .key = "price", .value = .{ .int = 120 } },
};
const item2 = [_]mustache.Value.Field{
    .{ .key = "name",  .value = .{ .string = "monitor" } },
    .{ .key = "price", .value = .{ .int = 480 } },
};
const items = [_]mustache.Value{
    .{ .object = &item1 },
    .{ .object = &item2 },
};
const root = [_]mustache.Value.Field{
    .{ .key = "items", .value = .{ .list = &items } },
};
const ctx: mustache.Value = .{ .object = &root };
```

For JSON-shaped data parsed at runtime, `valueFromJson` converts a
`std.json.Value` into a `Value` referencing the same string memory (so
keep the JSON arena alive for the duration of the render):

```zig
var parsed = try std.json.parseFromSlice(std.json.Value, alloc, json_src, .{});
defer parsed.deinit();

var arena = std.heap.ArenaAllocator.init(alloc);
defer arena.deinit();
const ctx = try mustache.valueFromJson(arena.allocator(), parsed.value);
```

> **Why no `Value.fromStruct`?** An earlier prototype rendered Zig structs
> directly via `@typeInfo` + recursive `anytype`. It works for one or two
> demo structs, but the compiler generates a fresh function instance per
> distinct context type — a test suite with a dozen anonymous-struct
> contexts blew through memory in minutes. The monomorphic `Value` path
> compiles in seconds and renders just as fast in practice. A struct
> adapter can be written on top if you want one.

## Rendering

```zig
pub fn render(template: Template, writer: *Writer, value: Value) RenderError!void;
pub fn renderWithPartials(t, w, v, partials: *const Partials) RenderError!void;
pub fn renderEx(t, w, v, opts: RenderOptions) RenderError!void;

pub const RenderOptions = struct {
    partials: ?*const Partials = null,
    allocator: ?std.mem.Allocator = null, // required iff templates may invoke lambdas
};

pub const RenderError = Writer.Error || Allocator.Error || ParseError;
```

The common case is just `render`. Reach for `renderEx` when you need
partials, lambdas, or both.

## Partials

Partials are pre-parsed `Template`s registered in a `Partials` map by
name. You own the map and the templates inside it.

```zig
var partials: mustache.Partials = .init(alloc);
defer {
    var it = partials.iterator();
    while (it.next()) |entry| entry.value_ptr.deinit();
    partials.deinit();
}
try partials.put("greeting", try mustache.parse(alloc, "Hello, {{name}}!"));

var t = try mustache.parse(alloc, "<{{>greeting}}>");
defer t.deinit();
try mustache.renderWithPartials(t, &writer, ctx, &partials);
```

Standalone-line indentation just works. A partial referenced as

```mustache
  {{>greeting}}
```

with a two-space leading indent has every line of its rendered output
prefixed with two spaces (only the partial's structural text — multi-line
variable expansions inside the partial are not re-indented per the spec).

### Dynamic partial names

Use `{{>*key.path}}` to look up the partial's name in the current context:

```mustache
{{>*template_name}}
```

The resolved string is used as the partial name to load from the map.

## Inheritance (parents and blocks)

`{{$name}}default{{/name}}` defines a named, overridable region with
default content. `{{<name}}...{{/name}}` invokes a partial as a "parent
template", and the body collects `{{$x}}` blocks that replace matching
blocks inside that partial.

Multi-level inheritance follows the Mustache 1.4 rule: the outermost
caller's override wins.

Block reindentation matches the spec — common leading whitespace is
removed at the definition site, and the parent's intrinsic indent is
added at the expansion site:

```mustache
parent.mustache:    Hi,\n  {{$block}}\n  {{/block}}\n
caller:             {{<parent}}{{$block}}\n    one\n    two\n{{/block}}{{/parent}}\n
output:             Hi,\n  one\n  two\n
```

## Set delimiter

```mustache
{{=<% %>=}}
Hello, <%name%>!
```

Triple-stache `{{{x}}}` only works with the default `{{` / `}}` delimiters;
once changed, use `{{&x}}` (or the new-delimiter equivalent) for raw
output.

## Lambdas

A `Lambda` is a Zig function plus an opaque context. Bind one in a `Value`,
and the renderer invokes it on encounter:

```zig
const Counter = struct { n: i64 = 0 };
var counter: Counter = .{};

fn callCounter(
    ctx_raw: *anyopaque,
    gpa: std.mem.Allocator,
    section_text: ?[]const u8,
) std.mem.Allocator.Error![]u8 {
    _ = section_text;
    const c: *Counter = @ptrCast(@alignCast(ctx_raw));
    c.n += 1;
    return std.fmt.allocPrint(gpa, "{d}", .{c.n});
}

const root = [_]mustache.Value.Field{
    .{ .key = "n", .value = .{ .lambda = .{ .ctx = &counter, .callFn = callCounter } } },
};

var t = try mustache.parse(alloc, "{{n}} {{n}} {{n}}");
defer t.deinit();
try mustache.renderEx(t, &writer, .{ .object = &root }, .{
    .allocator = alloc, // required: renderer allocates the lambda's return + parsed sub-template
});
// output: "1 2 3"
```

### Semantics

- **Variable lambda** (`{{name}}`): `section_text` is `null`. Return value
  is parsed with the default `{{` `}}` delimiters and rendered in the
  current scope. `{{name}}` HTML-escapes the rendered output; `{{{name}}}`
  / `{{&name}}` emits it raw.
- **Section lambda** (`{{#name}}body{{/name}}`): `section_text` is the
  raw source between the tags. Return value is parsed with the
  delimiters in effect at the section site (so alt-delim sections work).
- **Inverted section lambda** (`{{^name}}body{{/name}}`): per spec, a
  lambda is always truthy in inverted context, so the body is skipped.
  The function is not called.

### `valueFromJsonWithCodeReplacement`

The spec's lambda tests store per-language source code under a special
JSON form: `{"__tag__": "code", "ruby": "...", "js": "...", ...}`. The
helper

```zig
pub fn valueFromJsonWithCodeReplacement(
    allocator: std.mem.Allocator,
    json: std.json.Value,
    replacement: Value,
) !Value;
```

converts a JSON tree into a `Value` while substituting any object
matching that shape with `replacement` (typically a `.lambda`). This is
exactly how the spec runner wires up its lambda harness — see
[`tests/spec_runner.zig`](tests/spec_runner.zig) for a complete example.

## Errors

```zig
pub const ParseError = error{
    UnclosedTag, EmptyTag, UnclosedSection, UnexpectedClose, MismatchedClose,
    InvalidDelimiterTag,
} || std.mem.Allocator.Error;

pub const RenderError = Writer.Error || Allocator.Error || ParseError;
```

Render errors include parse errors because lambda return values are
re-parsed at render time; if a lambda emits a malformed template, that
parse fails through the same error union.

## Building

```sh
zig build              # build the demo binary
zig build run          # build and run the demo
zig build test         # run library unit tests (46 tests)
zig build spec         # run the Mustache spec conformance suite (194 tests)
```

The spec suite needs the official spec repo cloned at `./spec`. The
repository ships it as a git submodule, so:

```sh
git clone --recurse-submodules https://github.com/limistah/mustache-zig
# or, in an existing clone:
git submodule update --init --recursive
```

## Design notes

- The renderer is **monomorphic on `Value`**. An earlier comptime-struct
  path was removed because it exploded compile times on real test
  suites. The trade-off: users with native structs build a `Value` tree
  (or convert from JSON). Compile and link times are bounded.
- The **context stack** is a singly-linked list of `Frame{value, parent}`
  living on the renderer's call stack. No heap allocations during render
  (lambdas are the exception — they allocate, hence the explicit
  `RenderOptions.allocator`).
- The **parser** does standalone-line stripping inline, threads a small
  `State` through recursive calls for section/block/parent bodies, and
  captures everything later passes need (block intrinsic indents,
  section raw bodies, current delimiters at each section site).
- **Indent state** is carried by an `IndentState{indent, strip, at_line_start}`
  threaded through the renderer. Block reindentation is one strip + one
  prepend per line in a single pass.

## Acknowledgments

- The Mustache spec maintainers for the conformance corpus.
- [hoisie/mustache](https://github.com/hoisie/mustache) (Go) and
  [nickel-org/rust-mustache](https://github.com/nickel-org/rust-mustache)
  (Rust) for prior art on the dynamic-Value renderer shape.
- [maciejhirsz/ramhorns](https://github.com/maciejhirsz/ramhorns) (Rust)
  for the convincing demonstration that the comptime/struct path is
  worth aspiring to — even if it ultimately didn't survive contact with
  Zig's monomorphization model in this project.
