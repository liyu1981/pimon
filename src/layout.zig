//! Runtime-driven layout engine: **schema in code, layout instance in a
//! `.layout.zon` file**.
//!
//! The tree structure (which widgets, their text, ordering, nesting, bindings
//! and actions) lives in a ZON file read at runtime.  Editing that file only
//! needs a restart (or the in-UI *Reload* action) -- no recompile.  Zig only
//! owns the *schema* (`Node`): the set of components and properties it
//! understands.
//!
//! Parsing uses the built-in `std.zon` (recursive typed parse), so there is no
//! third-party runtime ZON dependency.
//!
//! ## Widget IDs
//!
//! DVUI derives a widget id from `@src()` (call site) plus `Options.id_extra`.
//! Inside this interpreter every component *kind* has its own fixed call site,
//! so the only collision is between same-kind siblings -- resolved by passing
//! `id_extra = <index within parent>`, which is DVUI's documented pattern for
//! loops.
//!
//! ```zig
//! // layouts/dashboard.layout.zon
//! .{
//!     .component = .vbox,
//!     .expand = .both,
//!     .children = .{
//!         .{ .component = .label, .text = "Hello" },
//!         .{ .component = .button, .text = "Apply", .action = "save" },
//!     },
//! }
//! ```

const std = @import("std");
const dvui = @import("dvui");

/// The components this engine knows how to render.  Adding a *new kind* means
/// touching this enum and `renderNode`; rearranging, retitling, rebinding or
/// reordering existing ones does not.
pub const Component = enum {
    vbox,
    hbox,
    label,
    title,
    heading,
    button,
    checkbox,
    separator,
    spacer,
};

/// One node of the layout tree.  Everything except `component` is optional, so
/// a `.zon` file only states what it cares about.
pub const Node = struct {
    component: Component,

    /// Display text (`label`, `title`, `heading`, `button`, `checkbox`).
    text: ?[]const u8 = null,
    /// Box fill behaviour: `.none`, `.horizontal`, `.vertical`, `.both`.
    expand: ?dvui.Options.Expand = null,
    /// Boolean state key for `checkbox` (see `Bindings`).
    bind: ?[]const u8 = null,
    /// Action name dispatched to the app when a `button` is pressed.
    action: ?[]const u8 = null,
    /// Uniform padding in logical pixels (boxes).
    padding: ?f32 = null,
    /// Minimum size hints (useful for `spacer`).
    width: ?f32 = null,
    height: ?f32 = null,
    /// Nested children (`vbox` / `hbox`).
    children: ?[]const Node = null,
};

/// Runtime state backing `bind` keys, plus the action a button dispatched this
/// frame.
pub const Bindings = struct {
    bools: std.StringHashMapUnmanaged(bool) = .empty,
    action: ?[]const u8 = null,

    pub fn deinit(self: *Bindings, gpa: std.mem.Allocator) void {
        self.bools.deinit(gpa);
        self.* = undefined;
    }

    /// Register a key up front (done for every `bind` in the tree at load time)
    /// so no rehash can move storage while DVUI holds a `*bool` mid-frame.
    pub fn register(self: *Bindings, gpa: std.mem.Allocator, key: []const u8) !void {
        const gop = try self.bools.getOrPut(gpa, key);
        if (!gop.found_existing) gop.value_ptr.* = false;
    }

    pub fn getBool(self: *Bindings, gpa: std.mem.Allocator, key: []const u8) *bool {
        self.register(gpa, key) catch {};
        return self.bools.getPtr(key) orelse &dangling_false;
    }

    var dangling_false: bool = false;

    pub fn takeAction(self: *Bindings) ?[]const u8 {
        const a = self.action;
        self.action = null;
        return a;
    }
};

/// A loaded `.layout.zon` document.
pub const Layout = struct {
    gpa: std.mem.Allocator,
    io: std.Io,
    path: []const u8,
    arena: ?*std.heap.ArenaAllocator = null,
    root: ?Node = null,
    /// Short, static description of the last load failure (details are logged).
    load_error: ?[]const u8 = null,

    pub fn init(gpa: std.mem.Allocator, io: std.Io, path: []const u8) Layout {
        return .{ .gpa = gpa, .io = io, .path = path };
    }

    /// (Re)read and parse the layout file.  Never fails: records `load_error`
    /// and logs the details instead, so the app keeps running with whatever it
    /// had (or shows the error in the UI).
    pub fn load(self: *Layout) void {
        self.freeTree();

        // `std.zon.parse` wants a sentinel-terminated source, so request a `[:0]u8`.
        const source = std.Io.Dir.cwd().readFileAllocOptions(
            self.io,
            self.path,
            self.gpa,
            .limited(1 << 20),
            .@"1",
            0,
        ) catch |err| {
            self.load_error = switch (err) {
                error.FileNotFound => "layout file not found",
                error.AccessDenied => "layout file not readable (permissions)",
                error.StreamTooLong => "layout file too large (>1 MiB)",
                else => "could not read layout file",
            };
            std.log.err("layout: {s}: {s}", .{ self.path, self.load_error.? });
            return;
        };
        defer self.gpa.free(source);

        const arena = self.gpa.create(std.heap.ArenaAllocator) catch {
            self.load_error = "out of memory";
            return;
        };
        arena.* = .init(self.gpa);
        errdefer self.gpa.destroy(arena);

        var diag: std.zon.parse.Diagnostics = undefined;
        const root = std.zon.parse.fromSlice(Node, .{
            .gpa = arena.allocator(),
            .arena = arena.allocator(),
            .source = source,
            .diagnostics = &diag,
        }) catch |err| {
            diag.log(self.path);
            self.load_error = switch (err) {
                error.OutOfMemory => "out of memory",
                error.ParseZon => "layout file has a syntax/schema error",
            };
            std.log.err("layout: {s}: {s}", .{ self.path, self.load_error.? });
            arena.deinit();
            self.gpa.destroy(arena);
            return;
        };

        self.arena = arena;
        self.root = root;
        self.load_error = null;
        std.log.info("layout: loaded {s}", .{self.path});
    }

    pub fn deinit(self: *Layout) void {
        self.freeTree();
        self.path = "";
    }

    fn freeTree(self: *Layout) void {
        if (self.arena) |a| {
            a.deinit();
            self.gpa.destroy(a);
            self.arena = null;
        }
        self.root = null;
    }

    /// Pre-register every `bind` key in the tree so the bindings map never has
    /// to grow while DVUI is mid-frame holding `*bool` pointers.
    pub fn registerBindings(self: *Layout, b: *Bindings) void {
        if (self.root) |*r| registerNode(r, self.gpa, b);
    }

    fn registerNode(node: *const Node, gpa: std.mem.Allocator, b: *Bindings) void {
        if (node.bind) |k| b.register(gpa, k) catch {};
        if (node.children) |ch| {
            for (ch) |*child| registerNode(child, gpa, b);
        }
    }

    /// Render the loaded tree into the current DVUI frame.
    pub fn render(self: *Layout, b: *Bindings) void {
        if (self.root) |*r| renderNode(r, self.gpa, b, 0);
    }
};

fn optionsFor(node: *const Node, idx: usize) dvui.Options {
    return .{
        .id_extra = idx,
        .expand = node.expand,
        .padding = if (node.padding) |p| dvui.Rect.all(p) else null,
        .min_size_content = if (node.width != null or node.height != null)
            .{ .w = node.width orelse 0, .h = node.height orelse 0 }
        else
            null,
    };
}

fn renderNode(node: *const Node, gpa: std.mem.Allocator, b: *Bindings, idx: usize) void {
    const opts = optionsFor(node, idx);

    switch (node.component) {
        .vbox, .hbox => {
            const dir: dvui.enums.Direction = if (node.component == .hbox) .horizontal else .vertical;
            var box = dvui.box(@src(), .{ .dir = dir }, opts);
            defer box.deinit();
            if (node.children) |children| {
                for (children, 0..) |*child, i| renderNode(child, gpa, b, i);
            }
        },
        .label => dvui.labelNoFmt(@src(), node.text orelse "", .{}, opts),
        .title => dvui.labelNoFmt(@src(), node.text orelse "", .{}, opts.override(.{ .font = .theme(.title) })),
        .heading => dvui.labelNoFmt(@src(), node.text orelse "", .{}, opts.override(.{ .font = .theme(.heading) })),
        .button => {
            if (dvui.button(@src(), node.text orelse "Button", .{}, opts)) {
                if (node.action) |action| b.action = action;
            }
        },
        .checkbox => {
            if (node.bind) |key| {
                const target = b.getBool(gpa, key);
                _ = dvui.checkbox(@src(), target, node.text, opts);
            } else {
                dvui.labelNoFmt(@src(), "(checkbox missing .bind)", .{}, opts);
            }
        },
        .separator => {
            _ = dvui.separator(@src(), opts);
        },
        .spacer => {
            var box = dvui.box(@src(), .{}, opts);
            defer box.deinit();
        },
    }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const sample =
    \\.{
    \\    .component = .vbox,
    \\    .expand = .both,
    \\    .children = .{
    \\        .{ .component = .title, .text = "Settings" },
    \\        .{ .component = .hbox, .children = .{
    \\            .{ .component = .label, .text = "Enable:" },
    \\            .{ .component = .checkbox, .bind = "perf", .text = "Perf" },
    \\        } },
    \\        .{ .component = .button, .text = "Apply", .action = "save" },
    \\    },
    \\}
;

test "parse a nested layout" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var diag: std.zon.parse.Diagnostics = undefined;
    const root = try std.zon.parse.fromSlice(Node, .{
        .gpa = arena.allocator(),
        .arena = arena.allocator(),
        .source = sample,
        .diagnostics = &diag,
    });

    try std.testing.expect(root.component == .vbox);
    try std.testing.expect(root.expand.? == .both);
    const kids = root.children.?;
    try std.testing.expectEqual(@as(usize, 3), kids.len);
    try std.testing.expect(kids[0].component == .title);
    try std.testing.expectEqualStrings("Settings", kids[0].text.?);
    try std.testing.expect(kids[1].component == .hbox);
    try std.testing.expectEqualStrings("perf", kids[1].children.?[1].bind.?);
    try std.testing.expectEqualStrings("save", kids[2].action.?);
}

test "rejects an unknown component" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var diag: std.zon.parse.Diagnostics = undefined;
    const result = std.zon.parse.fromSlice(Node, .{
        .gpa = arena.allocator(),
        .arena = arena.allocator(),
        .source = ".{ .component = .sparkle }",
        .diagnostics = &diag,
    });
    try std.testing.expectError(error.ParseZon, result);
}

test "binds register once and stay addressable" {
    var b: Bindings = .{};
    defer b.deinit(std.testing.allocator);

    try b.register(std.testing.allocator, "perf");
    try b.register(std.testing.allocator, "perf");
    try std.testing.expectEqual(@as(usize, 1), b.bools.count());

    const p1 = b.getBool(std.testing.allocator, "perf");
    const p2 = b.getBool(std.testing.allocator, "perf");
    p1.* = true;
    try std.testing.expect(p2.*);

    b.action = "save";
    try std.testing.expectEqualStrings("save", b.takeAction().?);
    try std.testing.expect(b.takeAction() == null);
}
