//! Small fixed-size rolling series for the pimon sparklines.

const std = @import("std");

pub const History = struct {
    buf: [48]f32 = @splat(0),
    len: u32 = 0,

    pub fn push(self: *History, value: f32) void {
        std.mem.copyForwards(f32, self.buf[0 .. self.buf.len - 1], self.buf[1..]);
        self.buf[self.buf.len - 1] = value;
        if (self.len < self.buf.len) self.len += 1;
    }

    pub fn slice(self: *const History) []const f32 {
        if (self.len == 0) return &.{};
        return self.buf[self.buf.len - self.len ..];
    }
};

test "history exposes the filled tail" {
    var h: History = .{};
    try std.testing.expectEqual(@as(usize, 0), h.slice().len);
    h.push(1);
    h.push(2);
    const s = h.slice();
    try std.testing.expectEqual(@as(usize, 2), s.len);
    try std.testing.expectEqual(@as(f32, 1), s[0]);
    try std.testing.expectEqual(@as(f32, 2), s[1]);
}
