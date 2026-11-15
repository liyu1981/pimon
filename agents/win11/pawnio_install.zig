//! Opt-in installation of the official PawnIO driver.
//!
//! We deliberately do not bundle the kernel driver.  The agent downloads the
//! official setup executable over HTTPS, verifies a pinned SHA-256, and runs
//! the vendor installer.  The installer remains responsible for DriverStore
//! registration, upgrades and uninstall registration.

const std = @import("std");
const c = @import("winapi");
const LogBuffer = @import("logbuf.zig").LogBuffer;
const pawnio = @import("pawnio.zig");

pub const version = "2.2.0";
pub const url = "https://github.com/namazso/PawnIO.Setup/releases/download/2.2.0/PawnIO_setup.exe";
pub const sha256 = "1f519a22e47187f70a1379a48ca604981c4fcf694f4e65b734aaa74a9fba3032";

const max_download = 8 * 1024 * 1024;
const device_wait_attempts = 20;
const device_wait_ms = 500;

pub fn run(io: std.Io, gpa: std.mem.Allocator, temp_dir: []const u8, log: *LogBuffer) bool {
    if (pawnio.isDeviceAvailable()) {
        log.log("pawnio: device already available");
        return true;
    }

    log.logf("pawnio: downloading official installer {s}", .{version});
    const body = download(io, gpa, url) catch |err| {
        log.logf("pawnio: download failed ({s})", .{@errorName(err)});
        return false;
    };
    defer gpa.free(body);

    var digest: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(body, &digest, .{});
    const digest_hex = std.fmt.bytesToHex(digest, .lower);
    if (!std.mem.eql(u8, &digest_hex, sha256)) {
        log.log("pawnio: installer checksum mismatch; refusing to run it");
        return false;
    }

    if (pawnio.isDeviceAvailable()) {
        log.log("pawnio: device became available; skipping installer");
        return true;
    }

    const path = std.fmt.allocPrint(gpa, "{s}\\pimon-pawnio-setup-{s}.exe", .{ temp_dir, version }) catch {
        log.log("pawnio: out of memory preparing installer path");
        return false;
    };
    defer gpa.free(path);
    defer std.Io.Dir.cwd().deleteFile(io, path) catch {};

    const file = std.Io.Dir.cwd().createFile(io, path, .{}) catch |err| {
        log.logf("pawnio: cannot create installer file ({s})", .{@errorName(err)});
        return false;
    };
    defer file.close(io);
    file.writeStreamingAll(io, body) catch |err| {
        log.logf("pawnio: cannot write installer ({s})", .{@errorName(err)});
        return false;
    };

    log.logf("pawnio: running official installer ({d} bytes)", .{body.len});
    if (!runInstaller(gpa, path)) {
        log.log("pawnio: installer failed to start");
        return false;
    }

    var attempt: usize = 0;
    while (attempt < device_wait_attempts) : (attempt += 1) {
        if (pawnio.isDeviceAvailable()) {
            log.log("pawnio: driver device is available");
            return true;
        }
        std.Io.sleep(io, .{ .nanoseconds = device_wait_ms * std.time.ns_per_ms }, .awake) catch {};
    }

    log.log("pawnio: installer finished but the device is still unavailable (reboot may be required)");
    return false;
}

fn download(io: std.Io, gpa: std.mem.Allocator, uri_text: []const u8) ![]u8 {
    var client: std.http.Client = .{ .allocator = gpa, .io = io };
    defer client.deinit();

    const uri = try std.Uri.parse(uri_text);
    var req = try client.request(.GET, uri, .{ .keep_alive = false });
    defer req.deinit();
    try req.sendBodiless();

    var redirect_buf: [8192]u8 = undefined;
    var response = try req.receiveHead(&redirect_buf);
    if (response.head.status.class() != .success) return error.HttpStatus;

    var read_buf: [4096]u8 = undefined;
    return try response.reader(&read_buf).allocRemaining(gpa, .limited(max_download));
}

fn runInstaller(gpa: std.mem.Allocator, path: []const u8) bool {
    const path_w = std.unicode.utf8ToUtf16LeAllocZ(gpa, path) catch return false;
    defer gpa.free(path_w);

    var si: c.STARTUPINFOW = std.mem.zeroes(c.STARTUPINFOW);
    si.cb = @sizeOf(c.STARTUPINFOW);
    var pi: c.PROCESS_INFORMATION = std.mem.zeroes(c.PROCESS_INFORMATION);
    if (c.CreateProcessW(path_w.ptr, null, null, null, 0, 0, null, null, &si, &pi) == 0) return false;

    defer {
        _ = c.CloseHandle(pi.hProcess);
        _ = c.CloseHandle(pi.hThread);
    }
    _ = c.WaitForSingleObject(pi.hProcess, c.INFINITE);
    return true;
}
