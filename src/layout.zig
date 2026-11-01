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
const widgets = @import("widgets");
const data = @import("data");

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
    /// Radial arc meter: track + threshold markers + value arc, with the
    /// value and unit centred in the arc.  Use `value` or `bind_value`.
    gauge,
    /// Small line chart of a series (`data`, or live `bind_data`).
    sparkline,
};

/// One node of the layout tree.  Everything except `component` is optional, so
/// a `.zon` file only states what it cares about.
pub const Node = struct {
    component: Component,

    /// Display text (`label`, `title`, `heading`, `button`, `checkbox`).
    text: ?[]const u8 = null,
    /// Live text key (label/title/heading/button); wins over `text`.
    bind_text: ?[]const u8 = null,
    /// Expected kind of the bound value (`float`/`series`/`text`/`boolean`).
    /// Optional: it is inferred from the binding field when omitted.  A
    /// mismatch with the field is logged and the inferred kind wins.
    bind_type: ?data.Kind = null,
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

    // --- `gauge` -----------------------------------------------------------
    /// Static value.  Ignored when `bind_value` is set.
    value: ?f32 = null,
    /// Full scale (default 100).  The value arc turns yellow near 78% and red
    /// near 90%, matching the threshold markers drawn at the end of the sweep.
    max: ?f32 = null,
    /// Unit shown under the value, e.g. "%", "°C", "W".
    unit: ?[]const u8 = null,
    /// Live scalar key (see `Bindings.setFloat`); wins over `value`.
    bind_value: ?[]const u8 = null,
    /// Draw the gauge's yellow/red warning bands (default off).
    show_thresholds: ?bool = null,

    // --- `sparkline` -------------------------------------------------------
    /// Static series of samples.
    data: ?[]const f32 = null,
    /// Live series key (see `Bindings.setSeries`); wins over `data`.
    bind_data: ?[]const u8 = null,

    // --- both --------------------------------------------------------------
    /// Accent colour: a name (green, lime, red, yellow, orange, cyan, blue,
    /// white, gray) or hex "rrggbb" / "aarrggbb".
    color: ?[]const u8 = null,

    /// Nested children (`vbox` / `hbox`).
    children: ?[]const Node = null,
};

/// Runtime state backing `bind` keys, plus the action a button dispatched this
/// frame.
pub const Bindings = struct {
    bools: std.StringHashMapUnmanaged(bool) = .empty,
    /// Live scalar values, published by the app each frame (`setFloat`).
    floats: std.StringHashMapUnmanaged(f32) = .empty,
    /// Live data series for sparklines (`setSeries`).  The app owns the
    /// backing storage and must keep it stable between publish and render.
    series: std.StringHashMapUnmanaged([]const f32) = .empty,
    /// Live strings for `bind_text` labels (borrowed; republished each frame).
    strings: std.StringHashMapUnmanaged([]const u8) = .empty,
    /// Declared expected kind per key (from layout `bind_type` / inference).
    kinds: std.StringHashMapUnmanaged(data.Kind) = .empty,
    action: ?[]const u8 = null,

    /// Keys copied on behalf of the network listener (owned by this map).
    owned_keys: std.ArrayList([]u8) = .empty,
    /// Series copied on behalf of the network listener; key + data are owned.
    owned_series: std.StringHashMapUnmanaged([]f32) = .empty,
    /// Text copied on behalf of the network listener; key + value are owned.
    owned_texts: std.StringHashMapUnmanaged([]u8) = .empty,

    pub fn deinit(self: *Bindings, gpa: std.mem.Allocator) void {
        self.bools.deinit(gpa);
        self.floats.deinit(gpa);
        self.series.deinit(gpa);
        self.strings.deinit(gpa);
        self.kinds.deinit(gpa);
        for (self.owned_keys.items) |key| gpa.free(key);
        self.owned_keys.deinit(gpa);
        var it = self.owned_series.iterator();
        while (it.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            gpa.free(entry.value_ptr.*);
        }
        self.owned_series.deinit(gpa);
        var text_it = self.owned_texts.iterator();
        while (text_it.next()) |entry| {
            gpa.free(entry.key_ptr.*);
            gpa.free(entry.value_ptr.*);
        }
        self.owned_texts.deinit(gpa);
        self.* = undefined;
    }

    // --- live scalars (gauge `bind_value`) --------------------------------
    pub fn setFloat(self: *Bindings, gpa: std.mem.Allocator, key: []const u8, value: f32) !void {
        _ = try self.floats.put(gpa, key, value);
    }

    pub fn getFloat(self: *const Bindings, key: []const u8) ?f32 {
        return self.floats.get(key);
    }

    /// Like `setFloat`, but `key` is copied so callers may free their own
    /// buffer afterwards (used by the network listener).
    pub fn setFloatOwned(self: *Bindings, gpa: std.mem.Allocator, key: []const u8, value: f32) !void {
        try self.owned_keys.ensureUnusedCapacity(gpa, 1);
        const owned = try gpa.dupe(u8, key);
        errdefer gpa.free(owned);
        const gop = try self.floats.getOrPut(gpa, owned);
        if (gop.found_existing) {
            gpa.free(owned);
        } else {
            self.owned_keys.appendAssumeCapacity(owned);
        }
        gop.value_ptr.* = value;
    }

    /// Set an already-registered checkbox binding; unknown keys are ignored.
    pub fn setBool(self: *Bindings, key: []const u8, value: bool) bool {
        const ptr = self.bools.getPtr(key) orelse return false;
        ptr.* = value;
        return true;
    }

    // --- live series (sparkline `bind_data`) ------------------------------
    pub fn setSeries(self: *Bindings, gpa: std.mem.Allocator, key: []const u8, samples: []const f32) !void {
        _ = try self.series.put(gpa, key, samples);
    }

    pub fn getSeries(self: *const Bindings, key: []const u8) ?[]const f32 {
        return self.series.get(key);
    }

    /// Like `setSeries`, but key and samples are copied (network listener).
    pub fn setSeriesOwned(self: *Bindings, gpa: std.mem.Allocator, key: []const u8, samples: []const f32) !void {
        try self.series.ensureUnusedCapacity(gpa, 1);
        try self.owned_series.ensureUnusedCapacity(gpa, 1);
        const owned_data = try gpa.dupe(f32, samples);
        errdefer gpa.free(owned_data);

        if (self.owned_series.getEntry(key)) |entry| {
            gpa.free(entry.value_ptr.*);
            entry.value_ptr.* = owned_data;
            // The series map must key off our owned copy, never the caller's
            // buffer: the event (and its key) is freed right after apply.
            self.series.putAssumeCapacity(entry.key_ptr.*, owned_data);
        } else {
            const owned_key = try gpa.dupe(u8, key);
            errdefer gpa.free(owned_key);
            self.owned_series.putAssumeCapacity(owned_key, owned_data);
            self.series.putAssumeCapacity(owned_key, owned_data);
        }
    }

    // --- live text (label/title/heading `bind_text`) ----------------------
    pub fn setText(self: *Bindings, gpa: std.mem.Allocator, key: []const u8, value: []const u8) !void {
        _ = try self.strings.put(gpa, key, value);
    }

    pub fn getText(self: *const Bindings, key: []const u8) ?[]const u8 {
        return self.strings.get(key);
    }

    /// Like `setText`, but key and value are copied (network listener).
    pub fn setTextOwned(self: *Bindings, gpa: std.mem.Allocator, key: []const u8, value: []const u8) !void {
        try self.strings.ensureUnusedCapacity(gpa, 1);
        try self.owned_texts.ensureUnusedCapacity(gpa, 1);
        const owned_value = try gpa.dupe(u8, value);
        errdefer gpa.free(owned_value);

        if (self.owned_texts.getEntry(key)) |entry| {
            gpa.free(entry.value_ptr.*);
            entry.value_ptr.* = owned_value;
            self.strings.putAssumeCapacity(entry.key_ptr.*, owned_value);
        } else {
            const owned_key = try gpa.dupe(u8, key);
            errdefer gpa.free(owned_key);
            self.owned_texts.putAssumeCapacity(owned_key, owned_value);
            self.strings.putAssumeCapacity(owned_key, owned_value);
        }
    }

    // --- universal typed API ----------------------------------------------

    /// Declare the kind a layout expects for `key`.  Conflicting declarations
    /// keep the first kind and log a warning.
    pub fn declare(self: *Bindings, gpa: std.mem.Allocator, key: []const u8, kind: data.Kind) !void {
        const gop = try self.kinds.getOrPut(gpa, key);
        if (gop.found_existing) {
            if (gop.value_ptr.* != kind) {
                std.log.warn("layout: binding '{s}' declared as both {s} and {s}; keeping {s}", .{
                    key,
                    @tagName(gop.value_ptr.*),
                    @tagName(kind),
                    @tagName(gop.value_ptr.*),
                });
            }
            return;
        }
        gop.value_ptr.* = kind;
    }

    pub fn kindOf(self: *const Bindings, key: []const u8) ?data.Kind {
        return self.kinds.get(key);
    }

    /// Universal publish used by the local `/proc` sampler and by remote
    /// injections.  Returns false (and stores nothing) when the value kind
    /// does not match the kind the layout declared for `key`.
    pub fn publish(self: *Bindings, gpa: std.mem.Allocator, key: []const u8, value: data.Value) !bool {
        const kind = data.kindOf(value);
        if (self.kinds.get(key)) |expected| {
            if (expected != kind) {
                std.log.debug("data: '{s}' expects {s}, ignoring {s}", .{ key, @tagName(expected), @tagName(kind) });
                return false;
            }
        }

        switch (value) {
            .float => |v| try self.setFloat(gpa, key, v),
            .series => |v| try self.setSeries(gpa, key, v),
            .text => |v| try self.setText(gpa, key, v),
            .boolean => |v| if (!self.setBool(key, v)) return false,
        }
        return true;
    }

    /// Same as `publish`, but takes ownership of key and payload (used for
    /// JSON/network events whose buffers are freed after apply).
    pub fn publishOwned(self: *Bindings, gpa: std.mem.Allocator, key: []const u8, value: data.Value) !bool {
        const kind = data.kindOf(value);
        if (self.kinds.get(key)) |expected| {
            if (expected != kind) {
                std.log.debug("data: '{s}' expects {s}, ignoring {s}", .{ key, @tagName(expected), @tagName(kind) });
                return false;
            }
        }

        switch (value) {
            .float => |v| try self.setFloatOwned(gpa, key, v),
            .series => |v| try self.setSeriesOwned(gpa, key, v),
            .text => |v| try self.setTextOwned(gpa, key, v),
            .boolean => |v| if (!self.setBool(key, v)) return false,
        }
        return true;
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

const InferredBinding = struct { key: []const u8, kind: data.Kind };

fn inferredBinding(node: *const Node) ?InferredBinding {
    if (node.bind_text) |key| return .{ .key = key, .kind = .text };
    if (node.bind_value) |key| return .{ .key = key, .kind = .float };
    if (node.bind_data) |key| return .{ .key = key, .kind = .series };
    if (node.bind) |key| return .{ .key = key, .kind = .boolean };
    return null;
}

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
        if (inferredBinding(node)) |binding| {
            if (node.bind_type) |declared| {
                if (declared != binding.kind) {
                    std.log.err("layout: binding '{s}' is {s} but bind_type says {s}; using {s}", .{
                        binding.key,
                        @tagName(binding.kind),
                        @tagName(declared),
                        @tagName(binding.kind),
                    });
                }
            }
            b.declare(gpa, binding.key, binding.kind) catch {};
            if (binding.kind == .boolean) b.register(gpa, binding.key) catch {};
        } else if (node.bind_type != null) {
            std.log.warn("layout: .bind_type set without a binding key", .{});
        }
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

fn textFor(node: *const Node, b: *const Bindings) []const u8 {
    if (node.bind_text) |key| {
        if (b.getText(key)) |value| return value;
    }
    return node.text orelse "";
}

fn renderNode(node: *const Node, gpa: std.mem.Allocator, b: *Bindings, idx: usize) void {
    const opts = optionsFor(node, idx);
    const text = textFor(node, b);

    switch (node.component) {
        .vbox, .hbox => {
            const dir: dvui.enums.Direction = if (node.component == .hbox) .horizontal else .vertical;
            var box = dvui.box(@src(), .{ .dir = dir }, opts);
            defer box.deinit();
            if (node.children) |children| {
                for (children, 0..) |*child, i| renderNode(child, gpa, b, i);
            }
        },
        .label => dvui.labelNoFmt(@src(), text, .{}, opts),
        .title => dvui.labelNoFmt(@src(), text, .{}, opts.override(.{ .font = .theme(.title) })),
        .heading => dvui.labelNoFmt(@src(), text, .{}, opts.override(.{ .font = .theme(.heading) })),
        .button => {
            if (dvui.button(@src(), if (text.len > 0) text else "Button", .{}, opts)) {
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
        .gauge => {
            const gauge_opts: widgets.gauge.Options = .{
                .value = if (node.bind_value) |k| b.getFloat(k) orelse node.value orelse 0.0 else node.value orelse 0.0,
                .max = node.max orelse 100.0,
                .accent = widgets.palette.parse(node.color) orelse widgets.palette.green,
                .show_thresholds = node.show_thresholds orelse false,
            };
            widgets.gauge.cell(idx, node.text orelse "", gauge_opts, node.unit orelse "", node.width orelse 180, node.height orelse 150, opts);
        },
        .sparkline => {
            const series = if (node.bind_data) |k|
                b.getSeries(k) orelse node.data
            else
                node.data;

            var s = dvui.box(@src(), .{ .dir = .vertical }, opts.override(.{
                .min_size_content = .{ .w = node.width orelse 180, .h = node.height orelse 56 },
                .background = false,
            }));
            defer s.deinit();

            widgets.sparkline.draw(s.data().rectScale(), series, widgets.palette.parse(node.color) orelse widgets.sparkline.default_color);
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

test "gauge and sparkline schema" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();

    var diag: std.zon.parse.Diagnostics = undefined;
    const root = try std.zon.parse.fromSlice(Node, .{
        .gpa = arena.allocator(),
        .arena = arena.allocator(),
        .source =
        \\.{
        \\    .component = .hbox,
        \\    .children = .{
        \\        .{ .component = .gauge, .bind_value = "cpu.temp", .max = 80.0, .unit = "C", .color = "green", .show_thresholds = true, .bind_type = .float },
        \\        .{ .component = .sparkline, .bind_data = "cpu.load_hist", .color = "cyan", .height = 48.0 },
        \\        .{ .component = .gauge, .value = 22.4, .max = 100.0, .unit = "%" },
        \\    },
        \\}
        ,
        .diagnostics = &diag,
    });

    const kids = root.children.?;
    try std.testing.expect(kids[0].component == .gauge);
    try std.testing.expectEqualStrings("cpu.temp", kids[0].bind_value.?);
    try std.testing.expectEqual(@as(f32, 80.0), kids[0].max.?);
    try std.testing.expectEqualStrings("C", kids[0].unit.?);
    try std.testing.expect(kids[0].show_thresholds.?);
    try std.testing.expectEqual(data.Kind.float, kids[0].bind_type.?);
    try std.testing.expect(kids[1].component == .sparkline);
    try std.testing.expectEqualStrings("cpu.load_hist", kids[1].bind_data.?);
    try std.testing.expectEqual(@as(f32, 48.0), kids[1].height.?);
    try std.testing.expect(kids[2].component == .gauge);
    try std.testing.expect(kids[2].bind_value == null);
    try std.testing.expectEqual(@as(f32, 22.4), kids[2].value.?);
}

test "owned bindings copy keys and data" {
    const gpa = std.testing.allocator;
    var b: Bindings = .{};
    defer b.deinit(gpa);

    var key_buf: [8]u8 = undefined;
    @memcpy(key_buf[0..4], "temp");
    try b.setFloatOwned(gpa, key_buf[0..4], 20);
    key_buf[0] = 'X'; // caller's buffer is free to change
    try std.testing.expectEqual(@as(f32, 20), b.getFloat("temp").?);
    try b.setFloatOwned(gpa, "temp", 30); // update, no key growth
    try std.testing.expectEqual(@as(f32, 30), b.getFloat("temp").?);

    var samples = [_]f32{ 1, 2, 3 };
    try b.setSeriesOwned(gpa, "hist", &samples);
    samples[1] = 9;
    try std.testing.expectEqual(@as(f32, 2), b.getSeries("hist").?[1]);
    try b.setSeriesOwned(gpa, "hist", &.{ 4, 5 });
    try std.testing.expectEqual(@as(usize, 2), b.getSeries("hist").?.len);
}

test "float and series bindings" {
    var b: Bindings = .{};
    defer b.deinit(std.testing.allocator);

    const gpa = std.testing.allocator;
    try b.setFloat(gpa, "cpu.temp", 49.0);
    try b.setFloat(gpa, "cpu.temp", 51.0); // overwrite
    try std.testing.expectEqual(@as(f32, 51.0), b.getFloat("cpu.temp").?);
    try std.testing.expect(b.getFloat("missing") == null);

    const series = [_]f32{ 1, 2, 3 };
    try b.setSeries(gpa, "cpu.load_hist", &series);
    const got = b.getSeries("cpu.load_hist").?;
    try std.testing.expectEqual(@as(usize, 3), got.len);
    try std.testing.expectEqual(@as(f32, 2.0), got[1]);

    try b.setText(gpa, "sys.host", "pivedev");
    try std.testing.expectEqualStrings("pivedev", b.getText("sys.host").?);
    try std.testing.expect(b.getText("sys.missing") == null);

    // Universal typed API: declared kinds reject mismatches.
    try b.declare(gpa, "typed.float", .float);
    try std.testing.expect(try b.publish(gpa, "typed.float", .{ .float = 7.5 }));
    try std.testing.expectEqual(@as(f32, 7.5), b.getFloat("typed.float").?);
    try std.testing.expect(!try b.publish(gpa, "typed.float", .{ .text = "nope" }));
    try std.testing.expect(b.getText("typed.float") == null);
    try std.testing.expectEqual(data.Kind.float, b.kindOf("typed.float").?);
}
