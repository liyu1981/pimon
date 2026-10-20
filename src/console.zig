//! Console/VT helpers.
//!
//! When pimon runs from a Linux virtual console, the kernel keeps drawing the
//! text cursor and any pending console output on top of the framebuffer.  Put
//! the VT into `KD_GRAPHICS` mode so the kernel stops touching the screen, and
//! restore `KD_TEXT` on exit.

const std = @import("std");
const posix = std.posix;
const linux = std.os.linux;

const KDSETMODE: u32 = 0x4B3A;
const KDGETMODE: u32 = 0x4B3B;
const KD_TEXT: usize = 0;
const KD_GRAPHICS: usize = 1;

pub const Console = struct {
    fd: posix.fd_t,
    prev_mode: usize,

    /// Try to grab the console.  Returns null when there is no VT (e.g. SSH,
    /// a container, or a plain file framebuffer) which is not an error.
    pub fn acquire() ?Console {
        const fd = posix.openat(posix.AT.FDCWD, "/dev/tty0", .{ .ACCMODE = .RDWR }, 0) catch
            posix.openat(posix.AT.FDCWD, "/dev/console", .{ .ACCMODE = .RDWR }, 0) catch return null;
        errdefer _ = linux.close(fd);

        var mode: usize = 0;
        const got = posix.errno(linux.ioctl(fd, KDGETMODE, @intFromPtr(&mode))) == .SUCCESS;
        if (!got) {
            _ = linux.close(fd);
            return null;
        }

        // Also hide the cursor and clear the screen for good measure.
        writeAll(fd, "\x1b[?25l\x1b[2J\x1b[H");

        if (posix.errno(linux.ioctl(fd, KDSETMODE, KD_GRAPHICS)) != .SUCCESS) {
            _ = linux.close(fd);
            return null;
        }

        return .{ .fd = fd, .prev_mode = mode };
    }

    pub fn release(self: Console) void {
        _ = linux.ioctl(self.fd, KDSETMODE, self.prev_mode);
        writeAll(self.fd, "\x1b[?25h\x1b[2J\x1b[H");
        _ = linux.close(self.fd);
    }
};

fn writeAll(fd: posix.fd_t, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = linux.write(fd, bytes.ptr + off, bytes.len - off);
        if (posix.errno(n) != .SUCCESS) return;
        const wrote: usize = @intCast(n);
        if (wrote == 0) return;
        off += wrote;
    }
}
