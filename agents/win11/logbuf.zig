//! Small thread-safe rolling log used by the tray UI.

const std = @import("std");
const c = @import("winapi");

const max_lines = 256;
const max_len = 240;

pub const LogBuffer = struct {
    io: std.Io,
    mutex: std.Io.Mutex = .init,
    lines: [max_lines][max_len]u8 = undefined,
    lens: [max_lines]u16 = @splat(0),
    total: u64 = 0,

    pub fn init(io: std.Io) LogBuffer {
        return .{ .io = io };
    }

    pub fn log(self: *LogBuffer, text: []const u8) void {
        var line_buf: [max_len]u8 = undefined;
        var st: c.SYSTEMTIME = std.mem.zeroes(c.SYSTEMTIME);
        c.GetLocalTime(&st);
        const prefix = std.fmt.bufPrint(&line_buf, "{d:0>2}:{d:0>2}:{d:0>2} ", .{
            st.wHour,
            st.wMinute,
            st.wSecond,
        }) catch return;
        const n = @min(prefix.len + text.len, line_buf.len - 1);
        @memcpy(line_buf[0..prefix.len], prefix);
        @memcpy(line_buf[prefix.len..n], text[0 .. n - prefix.len]);

        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);
        const idx: usize = @intCast(self.total % max_lines);
        @memcpy(self.lines[idx][0..n], line_buf[0..n]);
        self.lens[idx] = @intCast(n);
        self.total +%= 1;
    }

    pub fn logf(self: *LogBuffer, comptime fmt: []const u8, args: anytype) void {
        var buf: [max_len]u8 = undefined;
        const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
        self.log(text);
    }

    /// Snapshot all retained lines (oldest first) and return the total counter.
    pub fn snapshot(self: *LogBuffer, gpa: std.mem.Allocator, out: *std.ArrayList(u8)) u64 {
        self.mutex.lockUncancelable(self.io);
        defer self.mutex.unlock(self.io);

        const count: u64 = @min(self.total, max_lines);
        const first = self.total - count;
        var i: u64 = 0;
        while (i < count) : (i += 1) {
            const idx: usize = @intCast((first + i) % max_lines);
            const n = self.lens[idx];
            out.appendSlice(gpa, self.lines[idx][0..n]) catch return self.total;
            out.append(gpa, '\n') catch return self.total;
        }
        return self.total;
    }
};
