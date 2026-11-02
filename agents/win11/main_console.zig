//! Console-subsystem diagnostic build of the DVUI Win11 UI.
//!
//! `zig build win-debug` → `pimon-agent-win11-debug.exe`.

const std = @import("std");
const appmod = @import("main.zig");

pub fn main(init: std.process.Init) !void {
    appmod.ui_console_debug = true;
    std.debug.print("pimon-agent-win11-debug: starting\n", .{});
    appmod.main(init) catch |err| {
        std.debug.print("pimon-agent-win11-debug: fatal: {s}\n", .{@errorName(err)});
        return err;
    };
    std.debug.print("pimon-agent-win11-debug: exited\n", .{});
}
