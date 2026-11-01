//! Console-subsystem diagnostic build of the tray agent.
//!
//! `zig build win-debug` → `pimon-agent-win11-debug.exe`.
//! It uses the same UI/worker code, prints startup diagnostics to the terminal,
//! and still writes `%TEMP%\pimon-agent-win11.log`.

const std = @import("std");
const appmod = @import("main.zig");

pub fn main(init: std.process.Init) !void {
    appmod.console_debug = true;
    std.debug.print("pimon-agent-win11-debug: starting\n", .{});
    const rc = appmod.run(init.io, init.gpa, init.environ_map, init.minimal.args.vector);
    std.debug.print("pimon-agent-win11-debug: exit {d}\n", .{rc});
    if (rc != 0) std.process.exit(@intCast(rc));
}
