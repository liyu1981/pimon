//! Host tests for the platform-independent Win11 agent pieces.

const std = @import("std");

test {
    _ = @import("config.zig");
    _ = @import("history.zig");
    _ = @import("client.zig");
}
