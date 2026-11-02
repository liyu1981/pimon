//! pimon Win11 agent — a small Win32 tray application.
//!
//! Starts in the system tray, keeps a rolling log, exposes Start/Stop, and lets
//! the user edit and save `%APPDATA%\pimon\agent.config` in the window.
//!
//! `install-config` still creates the config and opens Notepad, without
//! starting the GUI.

const std = @import("std");
const c = @import("winapi");
const config = @import("config.zig");
const worker = @import("worker.zig");
const LogBuffer = @import("logbuf.zig").LogBuffer;

const class_name = std.unicode.utf8ToUtf16LeStringLiteral("PimonAgentWin11");
const window_title = std.unicode.utf8ToUtf16LeStringLiteral("pimon-agent-win11");
const WM_TRAY: c.UINT = 0x8000 + 1;
const TIMER_ID: c.UINT_PTR = 1;
const IDC_ARROW: [*:0]const u16 = @ptrFromInt(32512);
const IDI_APPLICATION: [*:0]const u16 = @ptrFromInt(32512);

// HMENU is a C pointer type with 4-byte alignment in the translated headers;
// child control IDs must therefore be aligned when passed as @ptrFromInt.
const ID_START: usize = 1000;
const ID_STOP: usize = 1004;
const ID_SAVE: usize = 1008;
const ID_RELOAD: usize = 1012;
const ID_HIDE: usize = 1016;
const ID_EXIT: usize = 1020;
const ID_OPEN: usize = 1024;

const App = struct {
    io: std.Io,
    gpa: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    hwnd: c.HWND = null,
    hcfg: c.HWND = null,
    hlog: c.HWND = null,
    hstatus: c.HWND = null,
    hstart: c.HWND = null,
    hstop: c.HWND = null,
    cfg_label: c.HWND = null,
    log_label: c.HWND = null,
    path_buf: [config.max_path]u8 = @splat(0),
    path_len: usize = 0,
    log: LogBuffer = undefined,
    log_seen: u64 = 0,
    worker_thread: ?std.Thread = null,
    stop: std.atomic.Value(bool) = .init(false),
    running: std.atomic.Value(bool) = .init(false),
    tray_added: bool = false,
    tray_msg: c.UINT = 0,
    taskbar_msg: c.UINT = 0,
    instance: c.HINSTANCE = null,

    fn path(self: *const App) []const u8 {
        return self.path_buf[0..self.path_len];
    }
};

var app: App = undefined;

pub var console_debug: bool = false;

fn debugLog(comptime fmt: []const u8, args: anytype) void {
    var msg_buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&msg_buf, fmt, args) catch return;
    if (console_debug) std.debug.print("{s}", .{msg});

    var path_buf: [c.MAX_PATH + 32]u16 = @splat(0);
    const base_len = c.GetTempPathW(path_buf.len, &path_buf);
    if (base_len == 0 or base_len >= path_buf.len) return;
    const name: []const u16 = std.unicode.utf8ToUtf16LeStringLiteral("pimon-agent-win11.log");
    if (@as(usize, base_len) + name.len + 1 > path_buf.len) return;
    @memcpy(path_buf[base_len .. base_len + name.len], name);
    path_buf[base_len + name.len] = 0;

    const handle = c.CreateFileW(
        &path_buf,
        c.FILE_APPEND_DATA,
        c.FILE_SHARE_READ | c.FILE_SHARE_WRITE,
        null,
        c.OPEN_ALWAYS,
        c.FILE_ATTRIBUTE_NORMAL,
        null,
    ) orelse return;
    if (@intFromPtr(handle) == std.math.maxInt(usize)) return;
    defer _ = c.CloseHandle(handle);
    var written: c.DWORD = 0;
    _ = c.WriteFile(handle, msg.ptr, @intCast(msg.len), &written, null);
}

fn unhandledException(info: c.PEXCEPTION_POINTERS) callconv(.c) c.LONG {
    if (info != null) {
        if (info.*.ExceptionRecord != null) {
            const rec = info.*.ExceptionRecord.*;
            debugLog("UNHANDLED EXCEPTION code=0x{x} address=0x{x} params={d}\n", .{
                rec.ExceptionCode,
                @intFromPtr(rec.ExceptionAddress),
                rec.NumberParameters,
            });
        }
    }
    return c.EXCEPTION_CONTINUE_SEARCH;
}

pub export fn wWinMain(
    hInstance: *anyopaque,
    hPrevInstance: ?*anyopaque,
    pCmdLine: [*:0]u16,
    nCmdShow: c_int,
) callconv(.c) c_int {
    _ = hInstance;
    _ = hPrevInstance;
    _ = pCmdLine;
    _ = nCmdShow;
    _ = c.SetUnhandledExceptionFilter(unhandledException);
    debugLog("wWinMain entered\n", .{});

    const gpa = std.heap.smp_allocator;
    const args_vec = std.os.windows.peb().ProcessParameters.CommandLine.slice();
    var threaded: std.Io.Threaded = .init(gpa, .{
        .argv0 = .init(.{ .vector = args_vec }),
        .environ = .{ .block = .global },
    });
    const io = threaded.io();
    debugLog("Io initialized\n", .{});

    var environ_map = std.process.Environ.createMap(.{ .block = .global }, gpa) catch {
        _ = c.MessageBoxW(
            null,
            std.unicode.utf8ToUtf16LeStringLiteral("Cannot read the process environment."),
            window_title,
            c.MB_OK | c.MB_ICONERROR,
        );
        return 1;
    };

    debugLog("environment map ready, entering run\n", .{});
    return run(io, gpa, &environ_map, args_vec);
}

pub fn run(
    io: std.Io,
    gpa: std.mem.Allocator,
    environ: *const std.process.Environ.Map,
    args_vec: []const u16,
) c_int {
    app.io = io;
    app.gpa = gpa;
    app.environ = environ;
    app.log = LogBuffer.init(io);

    debugLog("run started\n", .{});
    var args = Args{};
    args.parse(.{ .vector = args_vec }, gpa) catch |err| {
        messageBoxf("pimon-agent-win11", "Invalid arguments: {s}", .{@errorName(err)});
        return 2;
    };
    if (args.help) {
        messageBox("pimon-agent-win11", usage_text);
        return 0;
    }

    const path = config.resolvePath(environ, args.config_path, &app.path_buf) catch |err| {
        messageBoxf("pimon-agent-win11", "Cannot resolve config path: {s}", .{@errorName(err)});
        return 2;
    };
    app.path_len = path.len;
    debugLog("config path: {s}\n", .{path});

    if (args.install_config) {
        installConfig();
        return 0;
    }

    if (args.once) {
        runOnceMode();
        return 0;
    }

    if (!createWindow()) {
        debugLog("createWindow failed\n", .{});
        return 1;
    }
    debugLog("window created\n", .{});
    loadEditorFromDisk();
    const started = startFromEditor(false);
    debugLog("startFromEditor={s} tray={s} hidden={s}\n", .{ if (started) "true" else "false", if (app.tray_added) "true" else "false", if (args.hidden) "true" else "false" });
    if (args.hidden and started and app.tray_added) {
        hideWindow();
    } else {
        showWindow();
    }

    debugLog("entering message loop\n", .{});
    messageLoop();
    debugLog("message loop exited\n", .{});
    return 0;
}

fn messageLoop() void {
    var msg: c.MSG = undefined;
    while (true) {
        const ret = c.GetMessageW(&msg, null, 0, 0);
        if (ret <= 0) break;
        _ = c.TranslateMessage(&msg);
        _ = c.DispatchMessageW(&msg);
    }
}

fn createWindow() bool {
    app.instance = c.GetModuleHandleW(null);
    app.tray_msg = WM_TRAY;
    app.taskbar_msg = c.RegisterWindowMessageW(std.unicode.utf8ToUtf16LeStringLiteral("TaskbarCreated"));

    var wc: c.WNDCLASSEXW = std.mem.zeroes(c.WNDCLASSEXW);
    wc.cbSize = @sizeOf(c.WNDCLASSEXW);
    wc.style = c.CS_HREDRAW | c.CS_VREDRAW;
    wc.lpfnWndProc = wndProc;
    wc.hInstance = app.instance;
    wc.hCursor = c.LoadCursorW(null, IDC_ARROW);
    wc.hIcon = c.LoadIconW(null, IDI_APPLICATION);
    wc.hbrBackground = @ptrCast(@alignCast(c.GetStockObject(c.WHITE_BRUSH)));
    wc.lpszClassName = class_name;
    if (c.RegisterClassExW(&wc) == 0) {
        debugLog("RegisterClassExW failed\n", .{});
        messageBox("pimon-agent-win11", "Cannot register the window class.");
        return false;
    }
    debugLog("window class registered\n", .{});

    app.hwnd = c.CreateWindowExW(
        0,
        class_name,
        window_title,
        c.WS_OVERLAPPEDWINDOW | c.WS_CLIPCHILDREN | c.WS_MINIMIZEBOX | c.WS_SYSMENU,
        c.CW_USEDEFAULT,
        c.CW_USEDEFAULT,
        840,
        640,
        null,
        null,
        app.instance,
        null,
    );
    if (app.hwnd == null) {
        debugLog("CreateWindowExW failed\n", .{});
        messageBox("pimon-agent-win11", "Cannot create the main window.");
        return false;
    }
    debugLog("main window handle created\n", .{});

    debugLog("createControls begin\n", .{});
    createControls();
    debugLog("createControls done\n", .{});
    layoutControls();
    debugLog("layoutControls done\n", .{});
    _ = c.SetTimer(app.hwnd, TIMER_ID, 250, null);
    debugLog("timer set\n", .{});
    updateStatus();
    debugLog("status updated\n", .{});
    addTrayIcon();
    debugLog("tray_added={s}\n", .{if (app.tray_added) "true" else "false"});
    return true;
}

fn createControls() void {
    const parent = app.hwnd;
    const inst = app.instance;

    app.hstart = makeButton(parent, inst, "Start", ID_START);
    debugLog("start button\n", .{});
    app.hstop = makeButton(parent, inst, "Stop", ID_STOP);
    debugLog("stop button\n", .{});
    _ = makeButton(parent, inst, "Save Config", ID_SAVE);
    debugLog("save button\n", .{});
    _ = makeButton(parent, inst, "Reload", ID_RELOAD);
    debugLog("reload button\n", .{});
    _ = makeButton(parent, inst, "Hide", ID_HIDE);
    debugLog("hide button\n", .{});
    _ = makeButton(parent, inst, "Exit", ID_EXIT);
    debugLog("exit button\n", .{});

    app.hstatus = c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
        std.unicode.utf8ToUtf16LeStringLiteral("Stopped"),
        c.WS_CHILD | c.WS_VISIBLE,
        0,
        0,
        100,
        20,
        parent,
        null,
        inst,
        null,
    );
    setFont(app.hstatus, false);
    debugLog("status control\n", .{});

    app.cfg_label = makeLabel(parent, inst, "Configuration");
    debugLog("config label\n", .{});
    app.log_label = makeLabel(parent, inst, "Log");
    debugLog("log label\n", .{});

    app.hcfg = c.CreateWindowExW(
        c.WS_EX_CLIENTEDGE,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT"),
        null,
        c.WS_CHILD | c.WS_VISIBLE | c.WS_VSCROLL | c.WS_TABSTOP |
            c.ES_MULTILINE | c.ES_AUTOVSCROLL | c.ES_WANTRETURN,
        0,
        0,
        100,
        100,
        parent,
        null,
        inst,
        null,
    );
    setFont(app.hcfg, true);
    debugLog("config edit\n", .{});

    app.hlog = c.CreateWindowExW(
        c.WS_EX_CLIENTEDGE,
        std.unicode.utf8ToUtf16LeStringLiteral("EDIT"),
        null,
        c.WS_CHILD | c.WS_VISIBLE | c.WS_VSCROLL | c.WS_TABSTOP |
            c.ES_MULTILINE | c.ES_AUTOVSCROLL | c.ES_READONLY,
        0,
        0,
        100,
        100,
        parent,
        null,
        inst,
        null,
    );
    setFont(app.hlog, true);
    debugLog("log edit\n", .{});
}

fn makeButton(parent: c.HWND, inst: c.HINSTANCE, text: []const u8, id: usize) c.HWND {
    const wide = std.unicode.utf8ToUtf16LeAllocZ(app.gpa, text) catch return null;
    defer app.gpa.free(wide);
    const h = c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("BUTTON"),
        wide.ptr,
        c.WS_CHILD | c.WS_VISIBLE | c.WS_TABSTOP | c.BS_PUSHBUTTON,
        0,
        0,
        100,
        28,
        parent,
        @ptrFromInt(id),
        inst,
        null,
    );
    setFont(h, false);
    return h;
}

fn makeLabel(parent: c.HWND, inst: c.HINSTANCE, text: []const u8) c.HWND {
    const wide = std.unicode.utf8ToUtf16LeAllocZ(app.gpa, text) catch return null;
    defer app.gpa.free(wide);
    const h = c.CreateWindowExW(
        0,
        std.unicode.utf8ToUtf16LeStringLiteral("STATIC"),
        wide.ptr,
        c.WS_CHILD | c.WS_VISIBLE,
        0,
        0,
        100,
        18,
        parent,
        null,
        inst,
        null,
    );
    setFont(h, false);
    return h;
}

fn setFont(h: c.HWND, fixed: bool) void {
    if (h == null) return;
    const stock = if (fixed) c.ANSI_FIXED_FONT else c.DEFAULT_GUI_FONT;
    const font = c.GetStockObject(stock);
    if (font) |f| {
        _ = c.SendMessageW(h, c.WM_SETFONT, @intFromPtr(f), 1);
    }
}

fn layoutControls() void {
    debugLog("layout enter\n", .{});
    if (app.hwnd == null) return;
    var rc: c.RECT = undefined;
    if (c.GetClientRect(app.hwnd, &rc) == 0) return;
    const width: c_int = rc.right - rc.left;
    const height: c_int = rc.bottom - rc.top;
    const pad: c_int = 8;
    const bh: c_int = 28;
    var x: c_int = pad;
    const bw: c_int = 88;
    const gap: c_int = 6;
    inline for (.{ app.hstart, app.hstop }) |h| {
        _ = c.MoveWindow(h, x, pad, bw, bh, 1);
        x += bw + gap;
    }
    // Save / Reload / Hide / Exit are not stored; they are found by command id
    // through fixed positions instead.
    _ = c.MoveWindow(findButton(ID_SAVE), x, pad, 105, bh, 1);
    x += 105 + gap;
    _ = c.MoveWindow(findButton(ID_RELOAD), x, pad, 80, bh, 1);
    x += 80 + gap;
    _ = c.MoveWindow(findButton(ID_HIDE), x, pad, 70, bh, 1);
    x += 70 + gap;
    _ = c.MoveWindow(findButton(ID_EXIT), x, pad, 70, bh, 1);
    x += 70 + gap;
    _ = c.MoveWindow(app.hstatus, x, pad + 5, @max(80, width - x - pad), 20, 1);

    const cfg_y = pad + bh + 10;
    const cfg_h = @max(120, @divTrunc(height, 3));
    _ = c.MoveWindow(app.cfg_label, pad, cfg_y, 200, 18, 1);
    _ = c.MoveWindow(app.hcfg, pad, cfg_y + 20, width - 2 * pad, cfg_h, 1);

    const log_y = cfg_y + cfg_h + 30;
    _ = c.MoveWindow(app.log_label, pad, log_y, 100, 18, 1);
    _ = c.MoveWindow(app.hlog, pad, log_y + 20, width - 2 * pad, @max(60, height - log_y - 28), 1);
    debugLog("layout done\n", .{});
}

/// Buttons are not stored individually; locate them by ID via GetDlgItem.
fn findButton(id: usize) c.HWND {
    return c.GetDlgItem(app.hwnd, @intCast(id));
}

fn wndProc(hwnd: c.HWND, msg: c.UINT, wparam: c.WPARAM, lparam: c.LPARAM) callconv(.c) c.LRESULT {
    switch (msg) {
        c.WM_SIZE => {
            layoutControls();
            return 0;
        },
        c.WM_TIMER => {
            refreshLogs();
            updateStatus();
            return 0;
        },
        c.WM_SYSCOMMAND => {
            if ((wparam & 0xfff0) == c.SC_MINIMIZE) {
                hideWindow();
                return 0;
            }
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
        c.WM_COMMAND => {
            const id: usize = @intCast(wparam & 0xffff);
            handleCommand(id);
            return 0;
        },
        c.WM_CLOSE => {
            hideWindow();
            return 0;
        },
        c.WM_DESTROY => {
            shutdown();
            c.PostQuitMessage(0);
            return 0;
        },
        WM_TRAY => {
            const ev: c.UINT = @intCast(@as(u64, @bitCast(lparam)) & 0xffff);
            if (ev == c.WM_LBUTTONDBLCLK) {
                showWindow();
            } else if (ev == c.WM_RBUTTONUP or ev == c.WM_CONTEXTMENU) {
                showTrayMenu();
            }
            return 0;
        },
        else => {
            if (app.taskbar_msg != 0 and msg == app.taskbar_msg) {
                addTrayIcon();
                return 0;
            }
            return c.DefWindowProcW(hwnd, msg, wparam, lparam);
        },
    }
}

fn handleCommand(id: usize) void {
    switch (id) {
        ID_START => {
            _ = startFromEditor(true);
            updateStatus();
        },
        ID_STOP => stopWorker(),
        ID_SAVE => _ = saveEditor(),
        ID_RELOAD => loadEditorFromDisk(),
        ID_HIDE => hideWindow(),
        ID_OPEN => showWindow(),
        ID_EXIT => {
            _ = c.DestroyWindow(app.hwnd);
        },
        else => {},
    }
}

fn showWindow() void {
    debugLog("showWindow\n", .{});
    if (app.hwnd == null) return;
    _ = c.ShowWindow(app.hwnd, c.SW_SHOW);
    _ = c.SetForegroundWindow(app.hwnd);
    debugLog("showWindow done\n", .{});
}

fn hideWindow() void {
    if (app.hwnd == null) return;
    _ = c.ShowWindow(app.hwnd, c.SW_HIDE);
}

fn addTrayIcon() void {
    debugLog("tray add enter\n", .{});
    if (app.hwnd == null) return;
    var nid: c.NOTIFYICONDATAW = std.mem.zeroes(c.NOTIFYICONDATAW);
    nid.cbSize = @sizeOf(c.NOTIFYICONDATAW);
    nid.hWnd = app.hwnd;
    nid.uID = 1;
    nid.uFlags = c.NIF_MESSAGE | c.NIF_ICON | c.NIF_TIP;
    nid.uCallbackMessage = app.tray_msg;
    nid.hIcon = c.LoadIconW(null, IDI_APPLICATION);
    const tip: []const u16 = std.unicode.utf8ToUtf16LeStringLiteral("pimon-agent-win11");
    @memcpy(nid.szTip[0..tip.len], tip);
    debugLog("tray notify call\n", .{});
    if (c.Shell_NotifyIconW(c.NIM_ADD, &nid) != 0) {
        app.tray_added = true;
    }
    debugLog("tray notify done\n", .{});
}

fn removeTrayIcon() void {
    if (app.hwnd == null or !app.tray_added) return;
    var nid: c.NOTIFYICONDATAW = std.mem.zeroes(c.NOTIFYICONDATAW);
    nid.cbSize = @sizeOf(c.NOTIFYICONDATAW);
    nid.hWnd = app.hwnd;
    nid.uID = 1;
    _ = c.Shell_NotifyIconW(c.NIM_DELETE, &nid);
    app.tray_added = false;
}

fn showTrayMenu() void {
    const menu = c.CreatePopupMenu();
    if (menu == null) return;
    defer _ = c.DestroyMenu(menu);
    _ = c.AppendMenuW(menu, c.MF_STRING, ID_OPEN, std.unicode.utf8ToUtf16LeStringLiteral("Open"));
    _ = c.AppendMenuW(menu, c.MF_SEPARATOR, 0, null);
    _ = c.AppendMenuW(menu, c.MF_STRING, ID_START, std.unicode.utf8ToUtf16LeStringLiteral("Start"));
    _ = c.AppendMenuW(menu, c.MF_STRING, ID_STOP, std.unicode.utf8ToUtf16LeStringLiteral("Stop"));
    _ = c.AppendMenuW(menu, c.MF_SEPARATOR, 0, null);
    _ = c.AppendMenuW(menu, c.MF_STRING, ID_EXIT, std.unicode.utf8ToUtf16LeStringLiteral("Exit"));

    var pt: c.POINT = undefined;
    _ = c.GetCursorPos(&pt);
    _ = c.SetForegroundWindow(app.hwnd);
    _ = c.TrackPopupMenu(menu, c.TPM_LEFTALIGN | c.TPM_BOTTOMALIGN | c.TPM_RIGHTBUTTON, pt.x, pt.y, 0, app.hwnd, null);
    _ = c.PostMessageW(app.hwnd, c.WM_NULL, 0, 0);
}

fn updateStatus() void {
    const running = app.running.load(.acquire);
    if (app.hstatus != null) {
        setWindowTextUtf8(app.hstatus, if (running) "Running" else "Stopped");
    }
    _ = c.EnableWindow(app.hstart, if (running) 0 else 1);
    _ = c.EnableWindow(app.hstop, if (running) 1 else 0);
}

fn refreshLogs() void {
    debugLog("refreshLogs enter\n", .{});
    if (app.hlog == null) return;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(app.gpa);
    const total = app.log.snapshot(app.gpa, &out);
    debugLog("refreshLogs snapshot total={d} bytes={d}\n", .{ total, out.items.len });
    if (total == app.log_seen) return;
    setWindowTextUtf8(app.hlog, out.items);
    debugLog("refreshLogs text set\n", .{});
    app.log_seen = total;
    const end_w: c.WPARAM = @bitCast(@as(isize, -1));
    const end_l: c.LPARAM = -1;
    _ = c.SendMessageW(app.hlog, c.EM_SETSEL, end_w, end_l);
    debugLog("refreshLogs selection set\n", .{});
    _ = c.SendMessageW(app.hlog, c.EM_SCROLLCARET, 0, 0);
    debugLog("refreshLogs done\n", .{});
}

fn loadEditorFromDisk() void {
    const raw = config.readRaw(app.io, app.gpa, app.path()) catch |err| blk: {
        app.log.logf("cannot read config: {s}", .{@errorName(err)});
        break :blk null;
    };
    debugLog("loadEditor readRaw done\n", .{});
    if (raw) |text| {
        defer app.gpa.free(text);
        debugLog("config bytes={d}\n", .{text.len});
        setWindowTextUtf8(app.hcfg, text);
        debugLog("config editor set\n", .{});
        debugLog("before app.log config loaded\n", .{});
        app.log.logf("config loaded: {s}", .{app.path()});
        debugLog("after app.log config loaded\n", .{});
    } else {
        setWindowTextUtf8(app.hcfg, config.template);
        debugLog("config template set\n", .{});
        app.log.logf("config not found: {s}", .{app.path()});
    }
    debugLog("before refreshLogs after editor load\n", .{});
    app.log_seen = 0;
    refreshLogs();
    debugLog("loadEditor done\n", .{});
}

fn saveEditor() bool {
    const text = readEditor() catch |err| {
        app.log.logf("cannot read editor: {s}", .{@errorName(err)});
        return false;
    };
    defer app.gpa.free(text);
    config.saveText(app.io, app.path(), text) catch |err| {
        app.log.logf("cannot save config: {s}", .{@errorName(err)});
        return false;
    };
    app.log.logf("config saved: {s}", .{app.path()});
    return true;
}

fn configFromEditor() ?config.Config {
    debugLog("configFromEditor begin\n", .{});
    const text = readEditor() catch |err| {
        app.log.logf("cannot read config editor: {s}", .{@errorName(err)});
        return null;
    };
    defer app.gpa.free(text);
    debugLog("config editor bytes={d}\n", .{text.len});

    var cfg = config.Config{};
    config.parseText(text, &cfg) catch |err| {
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
    debugLog("configFromEditor done\n", .{});
    return cfg;
}

fn startFromEditor(save: bool) bool {
    debugLog("startFromEditor begin\n", .{});
    if (app.running.load(.acquire)) {
        app.log.log("already running");
        return true;
    }
    const cfg = configFromEditor() orelse {
        debugLog("configFromEditor returned null\n", .{});
        return false;
    };
    debugLog("config parsed, url={s}\n", .{cfg.url()});
    if (save) _ = saveEditor();
    debugLog("startWorker begin\n", .{});
    const ok = startWorker(cfg);
    debugLog("startWorker returned {s}\n", .{if (ok) "true" else "false"});
    return ok;
}

fn startWorker(cfg: config.Config) bool {
    debugLog("startWorker enter\n", .{});
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

    debugLog("spawning worker\n", .{});
    app.worker_thread = std.Thread.spawn(.{ .stack_size = 512 * 1024 }, worker.run, .{ctx}) catch |err| {
        app.gpa.destroy(ctx);
        app.running.store(false, .release);
        app.log.logf("cannot start worker: {s}", .{@errorName(err)});
        return false;
    };
    app.log.logf("start requested -> {s}", .{cfg.url()});
    debugLog("worker started\n", .{});
    updateStatus();
    return true;
}

fn stopWorker() void {
    if (!app.running.load(.acquire)) return;
    app.stop.store(true, .release);
    app.log.log("stop requested");
}

fn shutdown() void {
    app.stop.store(true, .release);
    if (app.worker_thread) |thread| {
        // Exit must not hang on a blocked HTTP request.  If the worker is
        // already stopping, reap it; otherwise let process exit tear it down.
        if (app.running.load(.acquire)) {
            thread.detach();
        } else {
            thread.join();
        }
        app.worker_thread = null;
    }
    removeTrayIcon();
    if (app.hwnd != null) _ = c.KillTimer(app.hwnd, TIMER_ID);
}

fn setWindowTextUtf8(h: c.HWND, text: []const u8) void {
    debugLog("setWindowText enter hwnd=0x{x} bytes={d}\n", .{ @intFromPtr(h), text.len });
    if (h == null) return;
    const wide = std.unicode.utf8ToUtf16LeAllocZ(app.gpa, text) catch {
        debugLog("setWindowText utf16 conversion failed\n", .{});
        return;
    };
    defer app.gpa.free(wide);
    debugLog("setWindowText converted\n", .{});
    _ = c.SetWindowTextW(h, wide.ptr);
    debugLog("setWindowText done\n", .{});
}

fn readEditor() ![]u8 {
    const h = app.hcfg;
    const len = c.GetWindowTextLengthW(h);
    if (len <= 0) return app.gpa.dupe(u8, "");
    const buf = try app.gpa.alloc(u16, @as(usize, @intCast(len)) + 1);
    defer app.gpa.free(buf);
    const n = c.GetWindowTextW(h, buf.ptr, @intCast(buf.len));
    if (n <= 0) return app.gpa.dupe(u8, "");
    return std.unicode.utf16LeToUtf8Alloc(app.gpa, buf[0..@intCast(n)]);
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
    debugLog("config editor bytes={d}\n", .{text.len});

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
    const prefix = if (ok) "Upload succeeded.\n\n" else "Upload failed.\n\n";
    var combined: std.ArrayList(u8) = .empty;
    defer combined.deinit(app.gpa);
    combined.appendSlice(app.gpa, prefix) catch return;
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

    fn parse(self: *Args, args: std.process.Args, gpa: std.mem.Allocator) !void {
        var it = try std.process.Args.Iterator.initAllocator(args, gpa);
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
    \\pimon-agent-win11 - Windows 11 metrics agent for pimon
    \\
    \\Usage:
    \\  pimon-agent-win11 [--hidden] [--config PATH]
    \\  pimon-agent-win11 install-config [--config PATH]
    \\  pimon-agent-win11 --once [--config PATH]
    \\
    \\The normal mode starts in the system tray.  Double-click the tray icon (or
    \\right-click -> Open) to see logs and edit the config.  Start/Stop are in the
    \\window and the tray menu.
;
