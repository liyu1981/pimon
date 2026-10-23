//! Reusable drawing widgets, shared by the built-in dashboard screen and the
//! `.layout.zig` interpreter.
//!
//! They live in their own module so both `dashboard.zig` (module `dashboard`)
//! and `layout.zig` (module `layout`) can use them — Zig forbids one file from
//! belonging to two modules.

pub const arc = @import("widgets/arc.zig");
pub const gauge = @import("widgets/gauge.zig");
pub const sparkline = @import("widgets/sparkline.zig");
pub const palette = @import("widgets/palette.zig");

test {
    @import("std").testing.refAllDecls(@This());
}
