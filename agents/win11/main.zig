//! DVUI/DX11 tray UI for the Win11 agent.
//!
//! The native tray icon lives in a hidden Win32 window.  The visible window,
//! config editor and log view are rendered with DVUI on top of D3D11.

const std = @import("std");

const VERSION = "0.1.0";
const dvui = @import("dvui");
const Backend = @import("dx11-backend");
const c = @import("winapi");
const config = @import("config.zig");
const worker = @import("worker.zig");
const LogBuffer = @import("logbuf.zig").LogBuffer;

const window_class = Backend.win32.L("PimonAgentWin11Dvui");
const WM_TRAY: u32 = 0x8000 + 1;

const ID_OPEN: usize = 0xE001;
const ID_START: usize = 0xE002;
const ID_STOP: usize = 0xE003;
const ID_EXIT: usize = 0xE004;

const App = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    path_buf: [config.max_path]u8 = @splat(0),
    path_len: usize = 0,
    config_text: std.ArrayList(u8) = .empty,
    log_text: std.ArrayList(u8) = .empty,
    log: LogBuffer = undefined,
    log_total: u64 = 0,
    main_hwnd: ?Backend.win32.HWND = null,
    original_wndproc: ?Backend.win32.WNDPROC = null,
    taskbar_msg: u32 = 0,
    tray_added: bool = false,
    worker_thread: ?std.Thread = null,
    stop: std.atomic.Value(bool) = .init(false),
    running: std.atomic.Value(bool) = .init(false),
    quit: bool = false,
    show_requested: bool = false,

    fn path(self: *const App) []const u8 {
        return self.path_buf[0..self.path_len];
    }
};

pub var ui_console_debug: bool = false;

var app: App = undefined;

fn uiLog(text: []const u8) void {
    if (ui_console_debug) std.debug.print("{s}", .{text});
    var path_buf: [c.MAX_PATH + 32]u16 = @splat(0);
    const base = c.GetTempPathW(path_buf.len, &path_buf);
    if (base == 0 or base >= path_buf.len) return;
    const name: []const u16 = std.unicode.utf8ToUtf16LeStringLiteral("pimon-agent-win11.log");
    if (@as(usize, base) + name.len + 1 > path_buf.len) return;
    @memcpy(path_buf[base .. base + name.len], name);
    path_buf[base + name.len] = 0;
    const h = c.CreateFileW(&path_buf, c.FILE_APPEND_DATA, c.FILE_SHARE_READ | c.FILE_SHARE_WRITE, null, c.OPEN_ALWAYS, c.FILE_ATTRIBUTE_NORMAL, null) orelse return;
    if (@intFromPtr(h) == std.math.maxInt(usize)) return;
    defer _ = c.CloseHandle(h);
    var written: c.DWORD = 0;
    _ = c.WriteFile(h, text.ptr, @intCast(text.len), &written, null);
}

fn uiLogf(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    uiLog(text);
}

fn uiException(info: c.PEXCEPTION_POINTERS) callconv(.c) c.LONG {
    if (info != null and info.*.ExceptionRecord != null) {
        const rec = info.*.ExceptionRecord.*;
        uiLogf("UNHANDLED EXCEPTION code=0x{x} address=0x{x}\n", .{ rec.ExceptionCode, @intFromPtr(rec.ExceptionAddress) });
    }
    return c.EXCEPTION_CONTINUE_SEARCH;
}

pub fn main(init: std.process.Init) !void {
    _ = c.SetUnhandledExceptionFilter(uiException);
    uiLog("ui main entered\n");
    app.io = init.io;
    app.gpa = init.gpa;
    app.environ = init.environ_map;
    app.log = LogBuffer.init(init.io);

    var args = Args{};
    args.parse(init) catch |err| {
        messageBoxf("pimon-agent-win11", "Invalid arguments: {s}", .{@errorName(err)});
        return;
    };
    if (args.help) {
        messageBox("pimon-agent-win11", usage_text);
        return;
    }

    const path = config.resolvePath(init.environ_map, args.config_path, &app.path_buf) catch |err| {
        messageBoxf("pimon-agent-win11", "Cannot resolve config path: {s}", .{@errorName(err)});
        return;
    };
    app.path_len = path.len;
    app.show_requested = args.show;

    if (args.install_config) {
        installConfig();
        return;
    }
    if (args.once) {
        runOnceMode();
        return;
    }

    loadConfigText();
    uiLogf("config path: {s}\n", .{path});

    dvui.io = init.io;
    uiLog("registering dvui window class\n");
    const icon = appIcon();
    Backend.RegisterClass(window_class, .{ .icon = icon, .icon_small = icon }) catch |err| {
        uiLogf("RegisterClass failed: {s} (win32 error {d})\n", .{ @errorName(err), Backend.win32.GetLastError() });
        messageBoxf("pimon-agent-win11", "Cannot register the DVUI window class: {s}", .{@errorName(err)});
        return err;
    };
    uiLog("dvui window class registered\n");
    var state: Backend.WindowState = undefined;
    uiLog("initWindow begin\n");
    const backend = Backend.initWindow(&state, .{
        .registered_class = window_class,
        .dvui_gpa = init.gpa,
        .allocator = init.gpa,
        .size = .{ .w = 1000.0, .h = 700.0 },
        .min_size = .{ .w = 760.0, .h = 520.0 },
        .vsync = true,
        .title = "pimon-agent-win11 " ++ VERSION,
        .dvui_window_init_options = .{
            .theme = dvui.Theme.builtin.adwaita_dark,
        },
    }) catch |err| {
        uiLogf("initWindow failed: {s} (win32 error {d})\n", .{ @errorName(err), Backend.win32.GetLastError() });
        messageBoxf("pimon-agent-win11", "Cannot create the DVUI/DX11 window: {s}", .{@errorName(err)});
        return err;
    };
    uiLog("initWindow returned\n");
    defer backend.deinit();
    app.main_hwnd = Backend.hwndFromContext(backend);
    uiLog("dvui backend initialized\n");

    defer removeTrayIcon();
    defer shutdownWorker();
    defer {
        app.config_text.deinit(app.gpa);
        app.log_text.deinit(app.gpa);
    }
    installTray();
    uiLogf("tray added={s}\n", .{if (app.tray_added) "true" else "false"});

    const win = backend.getWindow();
    const started = startFromConfig(false);
    uiLogf("auto start={s} hidden={s}\n", .{ if (started) "true" else "false", if (args.hidden) "true" else "false" });
    if (args.hidden and started and app.tray_added) {
        hideWindow();
    } else {
        showWindow();
    }

    uiLog("entering DVUI loop\n");
    main_loop: while (!app.quit) {
        const result = Backend.serviceMessageQueue();
        if (app.quit) break;
        switch (result) {
            .queue_empty => {
                const nstime = win.beginWait(backend.hasEvent());
                try win.begin(nstime);
                try uiFrame(win);
                handleWindowEvents(win);
                _ = try win.end(.{});
                if (Backend.win32.IsIconic(app.main_hwnd) != 0) hideWindow();
            },
            .quit => break :main_loop,
        }
    }
}

fn uiFrame(win: *dvui.Window) !void {
    _ = win;
    var root = dvui.box(@src(), .{ .dir = .vertical }, .{
        .expand = .both,
        .background = true,
        .style = .window,
        .padding = dvui.Rect.all(10),
    });
    defer root.deinit();

    {
        var header = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .horizontal });
        defer header.deinit();

        dvui.labelNoFmt(@src(), "pimon-agent-win11 " ++ VERSION, .{}, .{ .font = .theme(.title), .gravity_y = 0.5 });
        const running = app.running.load(.acquire);
        dvui.labelNoFmt(@src(), if (running) "  Running" else "  Stopped", .{}, .{
            .gravity_y = 0.5,
            .color_text = .{ .color = if (running) dvui.Color{ .r = 0x5c, .g = 0xe0, .b = 0x5c, .a = 0xff } else dvui.Color{ .r = 0xc0, .g = 0xc0, .b = 0xc0, .a = 0xff } },
        });

        if (dvui.button(@src(), "Start", .{}, .{ .gravity_x = 1.0, .id_extra = 1 })) {
            _ = startFromConfig(true);
        }
        if (dvui.button(@src(), "Stop", .{}, .{ .id_extra = 2 })) {
            stopWorker();
        }
        if (dvui.button(@src(), "Save Config", .{}, .{ .id_extra = 3 })) {
            _ = saveConfig();
        }
        if (dvui.button(@src(), "Reload", .{}, .{ .id_extra = 4 })) {
            loadConfigText();
        }
        if (dvui.button(@src(), "Hide", .{}, .{ .id_extra = 5 })) {
            hideWindow();
        }
    }

    _ = dvui.separator(@src(), .{ .expand = .horizontal });

    var body = dvui.box(@src(), .{ .dir = .horizontal }, .{ .expand = .both });
    defer body.deinit();

    {
        var cfg_box = dvui.box(@src(), .{ .dir = .vertical }, .{
            .expand = .vertical,
            .min_size_content = .{ .w = 430 },
        });
        defer cfg_box.deinit();
        dvui.labelNoFmt(@src(), "Configuration", .{}, .{ .font = .theme(.heading) });
        dvui.labelNoFmt(@src(), "PIMON_URL, PIMON_HTTP_SECRET, interval, agent name, GPU", .{}, .{});
        var te = dvui.textEntry(@src(), .{
            .text = .{ .array_list = .{
                .backing = &app.config_text,
                .allocator = app.gpa,
                .limit = 64 * 1024,
            } },
            .multiline = true,
            .scroll_vertical = true,
        }, .{
            .expand = .both,
            .font = .theme(.mono),
            .min_size_content = .{ .h = 220 },
        });
        te.deinit();
    }

    _ = dvui.separator(@src(), .{ .expand = .vertical });

    {
        var log_box = dvui.box(@src(), .{ .dir = .vertical }, .{ .expand = .both });
        defer log_box.deinit();
        dvui.labelNoFmt(@src(), "Log", .{}, .{ .font = .theme(.heading) });

        refreshLogText();
        var scroll = dvui.scrollArea(@src(), .{}, .{ .expand = .both });
        defer scroll.deinit();
        var tl = dvui.textLayout(@src(), .{}, .{ .expand = .horizontal, .font = .theme(.mono) });
        defer tl.deinit();
        tl.addText(app.log_text.items, .{});
    }
}

fn handleWindowEvents(win: *dvui.Window) void {
    for (dvui.events()) |*e| {
        if (e.evt == .window and e.evt.window.action == .close) {
            e.handle(@src(), win.data());
            hideWindow();
        }
    }
}

fn loadConfigText() void {
    app.config_text.clearRetainingCapacity();
    const raw = config.readRaw(app.io, app.gpa, app.path()) catch |err| blk: {
        app.log.logf("cannot read config: {s}", .{@errorName(err)});
        break :blk null;
    };
    if (raw) |text| {
        defer app.gpa.free(text);
        app.config_text.appendSlice(app.gpa, text) catch {};
        app.log.logf("config loaded: {s}", .{app.path()});
    } else {
        app.config_text.appendSlice(app.gpa, config.template) catch {};
        app.log.logf("config not found: {s}", .{app.path()});
    }
}

fn saveConfig() bool {
    config.saveText(app.io, app.path(), app.config_text.items) catch |err| {
        app.log.logf("cannot save config: {s}", .{@errorName(err)});
        return false;
    };
    app.log.logf("config saved: {s}", .{app.path()});
    return true;
}

fn configFromText() ?config.Config {
    var cfg = config.Config{};
    config.parseText(app.config_text.items, &cfg) catch |err| {
        app.log.logf("invalid config: {s}", .{@errorName(err)});
        return null;
    };
    if (cfg.url().len == 0) {
        app.log.log("PIMON_URL is empty");
        return null;
    }
    if (cfg.secret().len == 0) {
        app.log.log("PIMON_HTTP_SECRET is empty");
        return null;
    }
    return cfg;
}

fn startFromConfig(save: bool) bool {
    if (app.running.load(.acquire)) {
        app.log.log("already running");
        return true;
    }
    const cfg = configFromText() orelse return false;
    if (save) _ = saveConfig();
    return startWorker(cfg);
}

fn startWorker(cfg: config.Config) bool {
    if (app.worker_thread) |thread| {
        thread.join();
        app.worker_thread = null;
    }
    app.stop.store(false, .release);
    app.running.store(true, .release);

    const ctx = app.gpa.create(worker.Context) catch {
        app.running.store(false, .release);
        app.log.log("out of memory starting worker");
        return false;
    };
    ctx.* = .{
        .io = app.io,
        .gpa = app.gpa,
        .environ = app.environ,
        .cfg = cfg,
        .log = &app.log,
        .stop = &app.stop,
        .running = &app.running,
    };
    app.worker_thread = std.Thread.spawn(.{ .stack_size = 512 * 1024 }, worker.run, .{ctx}) catch |err| {
        app.gpa.destroy(ctx);
        app.running.store(false, .release);
        app.log.logf("cannot start worker: {s}", .{@errorName(err)});
        return false;
    };
    app.log.logf("start requested -> {s}", .{cfg.url()});
    return true;
}

fn stopWorker() void {
    if (!app.running.load(.acquire)) return;
    app.stop.store(true, .release);
    app.log.log("stop requested");
}

fn shutdownWorker() void {
    app.stop.store(true, .release);
    if (app.worker_thread) |thread| {
        if (app.running.load(.acquire)) {
            thread.detach();
        } else {
            thread.join();
        }
        app.worker_thread = null;
    }
}

fn refreshLogText() void {
    const total = app.log.totalCount();
    if (total == app.log_total) return;
    app.log_text.clearRetainingCapacity();
    _ = app.log.snapshot(app.gpa, &app.log_text);
    app.log_total = total;
}

const SW_HIDE: Backend.win32.SHOW_WINDOW_CMD = @bitCast(@as(u32, 0));
const SW_SHOW: Backend.win32.SHOW_WINDOW_CMD = @bitCast(@as(u32, 5));
const SW_RESTORE: Backend.win32.SHOW_WINDOW_CMD = @bitCast(@as(u32, 9));

fn showWindow() void {
    uiLogf("showWindow hwnd=0x{x}\n", .{@intFromPtr(app.main_hwnd)});
    if (app.main_hwnd == null) return;
    _ = Backend.win32.ShowWindow(app.main_hwnd, SW_RESTORE);
    _ = Backend.win32.ShowWindow(app.main_hwnd, SW_SHOW);
    _ = Backend.win32.SetForegroundWindow(app.main_hwnd);
}

fn hideWindow() void {
    uiLogf("hideWindow hwnd=0x{x}\n", .{@intFromPtr(app.main_hwnd)});
    if (app.main_hwnd == null) return;
    _ = Backend.win32.ShowWindow(app.main_hwnd, SW_HIDE);
}

fn appIcon() ?Backend.win32.HICON {
    const hinst = Backend.win32.GetModuleHandleW(null);
    const resource: [*:0]align(1) const u16 = @ptrFromInt(1);
    return Backend.win32.LoadIconW(hinst, resource);
}

fn installTray() void {
    const hwnd = app.main_hwnd orelse return;
    app.taskbar_msg = Backend.win32.RegisterWindowMessageW(Backend.win32.L("TaskbarCreated"));
    const previous = Backend.win32.SetWindowLongPtrW(hwnd, Backend.win32.GWLP_WNDPROC, @bitCast(@intFromPtr(&mainWndProc)));
    if (previous != 0) app.original_wndproc = @ptrFromInt(@as(usize, @bitCast(previous)));
    addTrayIcon();
}

fn mainWndProc(
    hwnd: Backend.win32.HWND,
    msg: u32,
    wparam: Backend.win32.WPARAM,
    lparam: Backend.win32.LPARAM,
) callconv(.winapi) Backend.win32.LRESULT {
    switch (msg) {
        WM_TRAY => {
            const ev: u32 = @intCast(@as(u64, @bitCast(lparam)) & 0xffff);
            uiLogf("tray event {d}\n", .{ev});
            if (ev == Backend.win32.WM_LBUTTONUP or ev == Backend.win32.WM_LBUTTONDBLCLK) {
                showWindow();
            } else if (ev == Backend.win32.WM_RBUTTONDOWN or ev == Backend.win32.WM_RBUTTONUP or ev == Backend.win32.WM_CONTEXTMENU) {
                showTrayMenu();
            }
            return 0;
        },
        Backend.win32.WM_COMMAND => {
            const id: usize = @intCast(wparam & 0xffff);
            switch (id) {
                ID_OPEN => {
                    uiLogf("tray command {d}\n", .{id});
                    showWindow();
                    return 0;
                },
                ID_START => {
                    uiLogf("tray command {d}\n", .{id});
                    _ = startFromConfig(true);
                    return 0;
                },
                ID_STOP => {
                    uiLogf("tray command {d}\n", .{id});
                    stopWorker();
                    return 0;
                },
                ID_EXIT => {
                    uiLogf("tray command {d}\n", .{id});
                    app.quit = true;
                    return 0;
                },
                else => {},
            }
        },
        else => {
            if (app.taskbar_msg != 0 and msg == app.taskbar_msg) {
                addTrayIcon();
                return 0;
            }
        },
    }

    if (app.original_wndproc) |original| {
        return Backend.win32.CallWindowProcW(original, hwnd, msg, wparam, lparam);
    }
    return Backend.win32.DefWindowProcW(hwnd, msg, wparam, lparam);
}

fn addTrayIcon() void {
    const hwnd = app.main_hwnd orelse return;
    var nid: Backend.win32.NOTIFYICONDATAW = std.mem.zeroes(Backend.win32.NOTIFYICONDATAW);
    nid.cbSize = @sizeOf(Backend.win32.NOTIFYICONDATAW);
    nid.hWnd = hwnd;
    nid.uID = 1;
    nid.uFlags = .{ .MESSAGE = 1, .ICON = 1, .TIP = 1 };
    nid.uCallbackMessage = WM_TRAY;
    nid.hIcon = appIcon() orelse Backend.win32.LoadIconW(null, Backend.win32.IDI_APPLICATION);
    const tip: []const u16 = std.unicode.utf8ToUtf16LeStringLiteral("pimon-agent-win11");
    @memcpy(nid.szTip[0..tip.len], tip);
    if (Backend.win32.Shell_NotifyIconW(Backend.win32.NIM_ADD, &nid) != 0) app.tray_added = true;
    uiLogf("tray add main hwnd=0x{x} result={s}\n", .{ @intFromPtr(hwnd), if (app.tray_added) "true" else "false" });
}

fn removeTrayIcon() void {
    const hwnd = app.main_hwnd orelse return;
    if (!app.tray_added) return;
    var nid: Backend.win32.NOTIFYICONDATAW = std.mem.zeroes(Backend.win32.NOTIFYICONDATAW);
    nid.cbSize = @sizeOf(Backend.win32.NOTIFYICONDATAW);
    nid.hWnd = hwnd;
    nid.uID = 1;
    _ = Backend.win32.Shell_NotifyIconW(Backend.win32.NIM_DELETE, &nid);
    app.tray_added = false;
}

fn showTrayMenu() void {
    uiLog("showTrayMenu\n");
    const hwnd = app.main_hwnd orelse return;
    const menu = Backend.win32.CreatePopupMenu() orelse return;
    defer _ = Backend.win32.DestroyMenu(menu);
    _ = Backend.win32.AppendMenuW(menu, Backend.win32.MF_STRING, ID_OPEN, Backend.win32.L("Open"));
    _ = Backend.win32.AppendMenuW(menu, Backend.win32.MF_SEPARATOR, 0, null);
    _ = Backend.win32.AppendMenuW(menu, Backend.win32.MF_STRING, ID_START, Backend.win32.L("Start"));
    _ = Backend.win32.AppendMenuW(menu, Backend.win32.MF_STRING, ID_STOP, Backend.win32.L("Stop"));
    _ = Backend.win32.AppendMenuW(menu, Backend.win32.MF_SEPARATOR, 0, null);
    _ = Backend.win32.AppendMenuW(menu, Backend.win32.MF_STRING, ID_EXIT, Backend.win32.L("Exit"));
    var pt: Backend.win32.POINT = undefined;
    _ = Backend.win32.GetCursorPos(&pt);
    _ = Backend.win32.SetForegroundWindow(hwnd);
    _ = Backend.win32.TrackPopupMenu(
        menu,
        .{ .RIGHTBUTTON = 1, .BOTTOMALIGN = 1 },
        pt.x,
        pt.y,
        0,
        hwnd,
        null,
    );
    _ = Backend.win32.PostMessageW(hwnd, Backend.win32.WM_NULL, 0, 0);
}

fn installConfig() void {
    const result = config.installTemplate(app.io, app.path()) catch |err| {
        messageBoxf("pimon-agent-win11", "Cannot write {s}: {s}", .{ app.path(), @errorName(err) });
        return;
    };
    const msg = switch (result) {
        .created => "Config created; opening Notepad.",
        .exists => "Config already exists; opening Notepad.",
    };
    messageBox("pimon-agent-win11", msg);
    if (!openInNotepad(app.gpa, app.path())) {
        messageBoxf("pimon-agent-win11", "Could not launch Notepad. Edit this file manually:\n{s}", .{app.path()});
    }
}

fn runOnceMode() void {
    const raw = config.readRaw(app.io, app.gpa, app.path()) catch |err| blk: {
        messageBoxf("pimon-agent-win11", "Cannot read config: {s}", .{@errorName(err)});
        break :blk null;
    };
    const text = raw orelse {
        messageBox("pimon-agent-win11", "Config not found. Run install-config first.");
        return;
    };
    defer app.gpa.free(text);

    var cfg = config.Config{};
    config.parseText(text, &cfg) catch |err| {
        messageBoxf("pimon-agent-win11", "Invalid config: {s}", .{@errorName(err)});
        return;
    };
    if (cfg.url().len == 0 or cfg.secret().len == 0) {
        messageBox("pimon-agent-win11", "PIMON_URL and PIMON_HTTP_SECRET must both be set.");
        return;
    }

    var log = LogBuffer.init(app.io);
    const ok = worker.runOnce(app.io, app.gpa, app.environ, cfg, &log);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(app.gpa);
    _ = log.snapshot(app.gpa, &out);
    const tail = if (out.items.len > 1800) out.items[out.items.len - 1800 ..] else out.items;
    var combined: std.ArrayList(u8) = .empty;
    defer combined.deinit(app.gpa);
    combined.appendSlice(app.gpa, if (ok) "Upload succeeded.\n\n" else "Upload failed.\n\n") catch return;
    combined.appendSlice(app.gpa, tail) catch return;
    messageBox("pimon-agent-win11 --once", combined.items);
}

fn openInNotepad(gpa: std.mem.Allocator, path: []const u8) bool {
    var cmd_buf: [config.max_path + 32]u8 = undefined;
    const cmd = std.fmt.bufPrint(&cmd_buf, "notepad.exe \"{s}\"", .{path}) catch return false;
    const cmd_w = std.unicode.utf8ToUtf16LeAllocZ(gpa, cmd) catch return false;
    defer gpa.free(cmd_w);
    var si: c.STARTUPINFOW = std.mem.zeroes(c.STARTUPINFOW);
    si.cb = @sizeOf(c.STARTUPINFOW);
    var pi: c.PROCESS_INFORMATION = std.mem.zeroes(c.PROCESS_INFORMATION);
    if (c.CreateProcessW(null, cmd_w.ptr, null, null, 0, 0, null, null, &si, &pi) == 0) return false;
    _ = c.CloseHandle(pi.hProcess);
    _ = c.CloseHandle(pi.hThread);
    return true;
}

fn messageBox(title: []const u8, text: []const u8) void {
    const title_w = std.unicode.utf8ToUtf16LeAllocZ(app.gpa, title) catch return;
    defer app.gpa.free(title_w);
    const text_w = std.unicode.utf8ToUtf16LeAllocZ(app.gpa, text) catch return;
    defer app.gpa.free(text_w);
    _ = c.MessageBoxW(null, text_w.ptr, title_w.ptr, c.MB_OK | c.MB_ICONINFORMATION);
}

fn messageBoxf(title: []const u8, comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    messageBox(title, text);
}

const Args = struct {
    config_path: ?[]const u8 = null,
    install_config: bool = false,
    once: bool = false,
    show: bool = false,
    hidden: bool = false,
    help: bool = false,

    fn parse(self: *Args, init: std.process.Init) !void {
        var it = try std.process.Args.Iterator.initAllocator(init.minimal.args, init.gpa);
        defer it.deinit();
        _ = it.next();
        while (it.next()) |arg| {
            if (std.mem.eql(u8, arg, "install-config") or std.mem.eql(u8, arg, "config")) {
                self.install_config = true;
            } else if (std.mem.eql(u8, arg, "--config")) {
                self.config_path = it.next() orelse return error.MissingValue;
            } else if (std.mem.eql(u8, arg, "--once")) {
                self.once = true;
            } else if (std.mem.eql(u8, arg, "--show")) {
                self.show = true;
            } else if (std.mem.eql(u8, arg, "--hidden")) {
                self.hidden = true;
            } else if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                self.help = true;
            } else {
                return error.UnknownArgument;
            }
        }
    }
};

const usage_text =
    \\pimon-agent-win11 - DVUI tray UI for the Win11 agent
    \\
    \\Usage:
    \\  pimon-agent-win11 [--hidden] [--config PATH]
    \\  pimon-agent-win11 install-config [--config PATH]
    \\  pimon-agent-win11 --once [--config PATH]
    \\
;
