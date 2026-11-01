# pimon

A small system dashboard for a headless Raspberry Pi, built with
[DVUI](https://github.com/david-vanderson/dvui) and rendered straight to the
console.

Two output backends are included:

| Backend | How it draws | Use it for |
| --- | --- | --- |
| **SDL2 + KMSDRM** (default) | DRM/KMS via SDL2, OpenGL ES2 renderer (VideoCore IV / Mesa vc4) | The Pi 2 in CLI mode — GPU accelerated, smooth |
| **framebuffer** (`-Dgui=fb`) | pure-CPU rasterizer into `/dev/fb0` | machines without DRM, or as a dependency-free fallback |

Neither needs X11 or Wayland. The SDL2 path goes through SDL's `kmsdrm` video
driver and the `opengles2` renderer, which talk directly to the GPU while still
owning the console.

## Layout

```
build.zig            build logic + backend selection + Pi cross steps
build.zig.zon        pinned DVUI dependency
src/main.zig         SDL2/KMSDRM front-end (default)
src/main_fb.zig      software /dev/fb0 front-end (-Dgui=fb)
src/dashboard.zig    screen composition (built-in + .layout.zon)
src/layout.zig       .layout.zon engine: schema + ZON parser + interpreter
src/metrics.zig      host metrics sampled from /proc (+ load history)
src/net.zig          optional HTTP + WebSocket control listener
src/data.zig         universal typed data values (float/series/text/bool)
agents/win11/        Windows 11 daemon that pushes metrics to pimon
src/widgets.zig      module root for the reusable drawing widgets
src/widgets/arc.zig  Canvas-style arc() with round end caps
src/widgets/gauge.zig     radial gauge (background arc + value arc)
src/widgets/sparkline.zig line chart of a numeric series
src/widgets/palette.zig   widget colours + name/hex parser
layouts/*.layout.zon runtime-driven UI markup (pi-monitor, win11-monitor, ...)
src/backend.zig      DVUI backend: framebuffer + evdev (fb mode)
src/fbdev.zig        /dev/fb0 ioctl + mmap, pixel packing (fb mode)
src/soft_render.zig  CPU triangle rasterizer (fb mode)
src/input.zig        Linux evdev keyboard / mouse / touch (fb mode)
src/console.zig      VT graphics mode helper (fb mode)
vendor/sdl2/         vendored SDL2 (2.32.10) with a Zig build enabling KMSDRM
```

## 1. Install the dependencies (on the Pi)

SDL2 is **built from source by Zig** (vendored in `vendor/sdl2`, KMSDRM +
OpenGL ES2 enabled), so `libsdl2-dev` is *not* needed.  You only need the
headers the KMSDRM driver compiles against — at runtime SDL `dlopen`s the
libraries, so no extra libs are linked:

```sh
sudo apt update
sudo apt install -y libdrm-dev libgbm-dev libgles2-mesa-dev
```

(The same three packages on your desktop let you cross-compile `pi2-sdl`.)

## 2. Permissions for the console user

Running from a pure TTY means there is no window manager to hand out device
access, so the user needs the `video` and `input` groups:

```sh
sudo usermod -aG video,input pi       # use your own username if not "pi"
# log out and back in, or reboot
```

`sudo ./pimon` also works if you would rather not change groups.

## 3. Build

There are two variants for the Pi 2 (ARMv7).  Both are selected with the same
`-Dgui` option and installed under different names so they can live side by
side:

| Command | Output | Backend |
| --- | --- | --- |
| `zig build` | `zig-out/bin/pimon-sdl` | SDL2 + KMSDRM / OpenGL ES2 |
| `zig build -Dgui=fb` | `zig-out/bin/pimon-fb` | software rasterizer → `/dev/fb0` |

### On the Pi 2 (recommended)

Building natively targets ARMv7 automatically and compiles SDL2 from the
vendored source:

```sh
# GPU version (SDL2 + KMSDRM built from source)
zig build -Doptimize=ReleaseFast            # → zig-out/bin/pimon-sdl

# software version
zig build -Doptimize=ReleaseFast -Dgui=fb   # → zig-out/bin/pimon-fb

./zig-out/bin/pimon-sdl
```

On a 1 GB Pi you can cap the parallelism to avoid running out of memory:
`zig build -Doptimize=ReleaseFast -j2`.

Run it from a text console (boot to CLI with `sudo raspi-config` → *System
Options* → *Boot / Auto Login* → *Console*, or just switch to an unused VT).
KMSDRM takes over the screen directly.

### Cross-compiling from a desktop

```sh
# software version: fully static ARMv7 binary, zero dependencies
zig build pi2-fb            # → zig-out/bin/pimon-pi2-fb

# SDL2 version: SDL2 is compiled from vendored source for armv7
zig build pi2-sdl           # → zig-out/bin/pimon-pi2-sdl

# both ARMv7 binaries at once
zig build pi2
```

### Convenience build scripts

```sh
./scripts/build-dev.sh       # host Debug + Windows agent Debug → dist/dev/
./scripts/build-release.sh   # Pi 2/host ReleaseFast + agent ReleaseSafe → dist/release/
```

`build-dev.sh` produces `pimon-sdl`, `pimon-fb`, and `pimon-agent-win11.exe`
under `dist/dev/`.  `build-release.sh` also builds the ARMv7 binaries and
produces `pimon-pi2-sdl`, `pimon-pi2-fb`, host release binaries, and the
release Windows agent under `dist/release/`.

### Windows 11 agent

```sh
zig build win -Doptimize=ReleaseSafe   # → zig-out/bin/pimon-agent-win11.exe (x86_64-windows-gnu)
```

The agent is a Win32 tray application that samples Win11 CPU/RAM/network/GPU
(PDH + DXGI, optional NVML) and pushes batches to pimon.  It starts hidden in
the system tray; double-click the icon to see the live log, Start/Stop buttons,
and an editable config panel.  On Windows you can also create/edit the config
with:

```powershell
.\pimon-agent-win11.exe install-config
```

See `agents/win11/README.md` for the config file, keys and Windows startup
options.

No `libsdl2-dev`, no `dpkg --add-architecture`, no multiarch.  SDL2 is compiled
from the vendored source for `arm-linux-gnueabihf`.  The KMSDRM driver
`dlopen`s `libdrm`/`libgbm`/EGL at runtime, so the link step needs no GPU
libraries — only the **headers** at compile time.  Those come from your host's
`libdrm-dev libgbm-dev libgles2-mesa-dev` (the drm/gbm headers are portable C,
so host x86 headers are fine for an arm target).  If your armhf headers live
somewhere else, point at them:

```sh
zig build pi2-sdl -Ddrm-include=/path/to/armhf/include
```

The resulting `pimon-pi2-sdl` is a single statically-linked SDL2 binary; only
the Pi's runtime `libdrm.so.2`, `libgbm.so.1`, `libEGL`, `libGLESv2` (all
present on Raspberry Pi OS) are needed at run time.

### Desktop smoke test (framebuffer mode)

```sh
zig build -Dgui=fb run -- \
  --fb /tmp/pimon.fb --size 800x480 --bpp 32 \
  --frames 10 --dump /tmp/pimon.png --no-input --no-console
```

## Options

### SDL2/KMSDRM backend (default)

| Option | Meaning |
| --- | --- |
| `--size WxH` | requested size (KMSDRM uses the panel's preferred mode) |
| `--fps N` | target frame rate (default 30; `0` = vsync-driven) |
| `--frames N` | exit after `N` frames (`0` = run until Quit) |
| `--video-driver S` | SDL video driver (default `kmsdrm`; try `x11` on a desktop) |
| `--render-driver S` | SDL render driver (default `opengles2`; try `software`) |
| `--windowed` | do not request fullscreen (KMSDRM is always fullscreen) |
| `--no-vsync` | disable vertical sync |
| `--no-drm-master` | set `SDL_KMSDRM_REQUIRE_DRM_MASTER=0` |
| `--light` / `--dark` | colour scheme |
| `--no-http` | disable the `~/.config/pimon.config` control listener |
| `--gen-config` | create/upgrade `~/.config/pimon.config` and exit |

The relevant SDL hints are applied before `SDL_Init`:

```zig
SDL_HINT_VIDEODRIVER          = "kmsdrm"
SDL_HINT_RENDER_DRIVER        = "opengles2"
SDL_OPENGL_ES_DRIVER          = "1"
SDL_HINT_KMSDRM_REQUIRE_DRM_MASTER (left at SDL's default unless --no-drm-master)
```

Build-time flags ( Zig `build` options, not runtime flags):

| Build flag | Meaning |
| --- | --- |
| `-Dsdl2=zig` | build SDL2 from vendored source with KMSDRM (default) |
| `-Dsdl2=system` | link the host's `libSDL2` instead |
| `-Dx11=true` | also compile the X11 video driver into SDL2 (desktop testing) |
| `-Ddrm-include=PATH` | extra include dir holding `xf86drm.h` (cross builds) |

### Framebuffer backend (`-Dgui=fb`)

| Option | Meaning |
| --- | --- |
| `--fb PATH` | framebuffer device or file (default `/dev/fb0`) |
| `--size WxH`, `--bpp N` | force geometry (needed for plain files) |
| `--fps N`, `--frames N` | frame pacing / auto-exit |
| `--dump PATH` | write the final frame to PNG and exit |
| `--scale F` | content scale |
| `--light` / `--dark`, `--clear RRGGBB` | appearance |
| `--no-input`, `--keyboard PATH`, `--pointer PATH` | evdev input control |
| `--no-console` | leave the VT in text mode |
| `--no-http` | disable the `~/.config/pimon.config` control listener |
| `--gen-config` | create/upgrade `~/.config/pimon.config` and exit |

Keyboard controls (both backends): `Tab`/`Shift-Tab` move focus, `Enter`/`Space`
activate, `Esc` or the Quit button exits.

## Network control listener

Both front-ends can expose a small REST + WebSocket API so another device can
read live metrics or inject values into a `.layout.zon` screen.  It is **off by
default** and configured from an env-file at `~/.config/pimon.config`.
Generate one (with a random secret) or upgrade an existing file after pulling
new keys:

```sh
./zig-out/bin/pimon-fb --gen-config    # or pimon-sdl on the SDL build
```

The command is idempotent and non-destructive: existing values (including
`PIMON_HTTP_ENABLED=0`), comments and unknown keys are preserved, missing keys
are appended (defaults: enabled, `127.0.0.1`, port `8717`), and an
empty/placeholder secret is replaced with a fresh 32-byte token.  The file is written atomically with mode `0600`; a second run reports
`unchanged`.  It needs no display and exits immediately.

A commented template also lives in `pimon.config.example`, and the equivalent
manual setup is:

```sh
mkdir -p ~/.config
umask 077
cat > ~/.config/pimon.config <<CONFIG
PIMON_HTTP_ENABLED=1
PIMON_HTTP_BIND=127.0.0.1
PIMON_HTTP_PORT=8717
PIMON_HTTP_SECRET=$(openssl rand -base64 32)
CONFIG
chmod 600 ~/.config/pimon.config
```

| key | meaning |
| --- | --- |
| `PIMON_HTTP_ENABLED` | `1`/`true`/`on`/`yes` to start the listener (default off) |
| `PIMON_HTTP_BIND` | local IP literal to bind (default `127.0.0.1`) |
| `PIMON_HTTP_PORT` | TCP port (default `8717`) |
| `PIMON_HTTP_SECRET` | bearer token (alias `PIMON_HTTP_TOKEN`); required |

`#`/`;` comments, `export KEY=...`, blank lines and single/double quotes are
accepted.  Pass `--no-http` to ignore the file for one run.

The listener fails closed: with no secret it stays disabled.  Every request
except health, including the WebSocket handshake, needs:

```
Authorization: Bearer <PIMON_HTTP_SECRET>
```

The token is compared via SHA-256 digests in constant time and is never logged.
`GET /api/v1/health` (alias `/healthz`) is deliberately unauthenticated so a
supervisor can check liveness without holding the token.

> **Security:** there is no TLS.  Keep the default loopback bind, or put the
> listener on a trusted LAN / behind an SSH tunnel (`ssh -L 8717:127.0.0.1:8717
> pi@host`).  Requests, including the token, are plaintext on the wire.

### REST

```sh
TOKEN=$(grep PIMON_HTTP_SECRET ~/.config/pimon.config | cut -d= -f2-)
BASE=http://127.0.0.1:8717/api/v1

curl $BASE/health                  # no token needed (alias: /healthz)
curl -H "Authorization: Bearer $TOKEN" $BASE/metrics

# inject a scalar into a gauge bound with bind_value="power.w"
curl -X POST -H "Authorization: Bearer $TOKEN" -H 'content-type: application/json' \
     -d '{"key":"power.w","value":12.5}' $BASE/data

# inject a sparkline series bound with bind_data="power.history"
curl -X POST -H "Authorization: Bearer $TOKEN" -H 'content-type: application/json' \
     -d '{"key":"power.history","value":[3,5,2,8,6,9]}' $BASE/data

# inject text into a bind_text label, set a checkbox, or dispatch an action
curl -X POST -H "Authorization: Bearer $TOKEN" -H 'content-type: application/json' \
     -d '{"key":"remote.status","value":"online"}' $BASE/data
curl -X POST -H "Authorization: Bearer $TOKEN" -H 'content-type: application/json' \
     -d '{"key":"demo.animate","value":false}' $BASE/data
curl -X POST -H "Authorization: Bearer $TOKEN" -H 'content-type: application/json' \
     -d '{"action":"reload_layout"}' $BASE/action
```

| method | path | meaning |
| --- | --- | --- |
| GET | `/api/v1/health` (alias `/healthz`) | `{"ok":true,"uptime_s":...,"clients":...}` — no token |
| GET | `/api/v1/metrics` | latest metrics snapshot (JSON) |
| POST | `/api/v1/data` | inject a number, boolean, string or numeric array |
| POST | `/api/v1/action` | dispatch `reload_layout`, `quit`, or a custom action |
| GET | `/api/v1/ws` | WebSocket upgrade |

Both a single value and a typed batch are accepted:

```json
{"key":"cpu.load_pct","value":42}
```

```json
{"agent":"win11","ts":1762000000123,
 "values":{"win.cpu.util_pct":23.4,"win.gpu.util_pct":12.0,
           "win.cpu.util_hist":[12,18,23]}}
```

The batch form is what the Windows agent (`agents/win11`) uses once per
interval.

`value` selects the binding kind: number -> float, boolean -> an already
registered checkbox, string -> text, array of numbers -> series.  Keys are limited to
`A-Za-z0-9._-` (max 128 bytes), series to 512 samples, request bodies to 64 KiB.
Injected values are copied into the layout bindings and validated against the
layout's `bind_type` declarations (a mismatch is dropped).  Keys published from
`/proc` (`cpu.load_pct`, `ram.used_pct`, ...) are refreshed every second and
therefore override injected values for those names.

### WebSocket

Connect to `ws://host:8717/api/v1/ws` with the bearer header.  Text frames use
the same JSON objects as `POST /api/v1/data` / `/action`; the server replies
`{"ok":true,"queued":true}` or a JSON error, and sends a `hello` frame first.
Frames up to 16 KiB are accepted, binary frames are rejected, and ping frames
get a pong.

```sh
websocat -H "Authorization: Bearer $TOKEN" ws://127.0.0.1:8717/api/v1/ws
```

Limits: 16 concurrent clients, a 64-event inbound queue (oldest dropped when
full) and 64 KiB HTTP bodies.  Events are drained by the render loop, so network
threads never touch DVUI state.

## Layout markup (`*.layout.zon`)

The UI can be **driven by a `.layout.zon` file instead of hard-coded Zig**, so
the widget tree lives in data and only the *schema* lives in code:

```
.layouts/dashboard.layout.zon   ← structure, text, order, bindings, actions
src/layout.zig                  ← schema (Node/Component) + parser + renderer
```

```sh
./zig-out/bin/pimon-fb --layout layouts/dashboard.layout.zon
./zig-out/bin/pimon-sdl --layout layouts/dashboard.layout.zon
```

Edit the file and press **Reload layout** (or restart) — rearranging,
adding/removing components, retitling and rebinding never needs a recompile.
Only adding a brand-new *component kind* or *property* touches `src/layout.zig`.

### Components

| `component` | Renders |
| --- | --- |
| `.vbox` / `.hbox` | vertical / horizontal box (`children`) |
| `.label` / `.title` / `.heading` | text at body / title / heading font |
| `.button` | button; `action` dispatched to the app on press |
| `.checkbox` | bound to a boolean via `bind` |
| `.separator` | divider |
| `.spacer` | fixed `width` / `height` gap |
| `.gauge` | radial arc meter (270° track + value arc + optional warning bands) with the value and unit centred |
| `.sparkline` | small line chart of a numeric series |

Common properties: `text`, `bind_text` (live text for
`label`/`title`/`heading`/`button`, wins over `text`), `bind_type`
(`.float`/`.series`/`.text`/`.boolean`; optional, inferred from the binding
field), `expand` (`.none`/`.horizontal`/`.vertical`/`.both`), `bind`, `action`,
`padding`, `width`, `height`, `color` (accent for gauges/sparklines, text colour
for labels/titles/headings/buttons), `text_larger` (extra points for text,
used by the Win11 clock), `children`.

### `gauge`

| property | meaning |
| --- | --- |
| `value` | static value |
| `bind_value` | **live** scalar key (wins over `value`) |
| `max` | full scale (default 100) |
| `unit` | suffix under the value (`%`, `°C`, `W`) |
| `color` | accent colour: `green`/`lime`/`red`/`yellow`/`orange`/`cyan`/`blue`/`white`/`gray`, or hex `rrggbb`/`aarrggbb` |
| `show_thresholds` | draw the yellow/red warning bands (default `false`) |
| `text` | gauge title, drawn above the ring |

The value arc turns **yellow near 78 %** and **red near 90 %** of `max`.  The
warning/danger bands on the track are optional and **off by default**; set
`.show_thresholds = true` on a gauge that wants them.

### `sparkline`

| property | meaning |
| --- | --- |
| `data` | static series: `.{ 3.0, 5.0, 2.0, ... }` |
| `bind_data` | **live** series key (wins over `data`) |
| `color` | accent colour (same names/hex as `gauge`) |

### Typed data API

Every binding has a kind: `.float`, `.series`, `.text`, or `.boolean`.
`bind_type` is optional and inferred from `bind_value` / `bind_data` /
`bind_text` / `bind`; the `pi-monitor` layout declares it explicitly.  Both
local `/proc` metrics (`dashboard.publishMetrics`) and HTTP/WebSocket
injections flow through the same `src/data.zig` API (`data.Value` +
`Bindings.publish` / `publishOwned`).  A publication whose kind does not match
the layout declaration is logged and dropped — e.g. a remote float cannot
overwrite the text binding `sys.host`.

### Live data keys

The app publishes metrics from `/proc` each frame, so a layout can bind to them
without any code change.  Everything below is `.float` except `cpu.load_hist`
(`.series`) and the `sys.*` keys (`.text`):

| key | meaning |
| --- | --- |
| `cpu.load_pct` | 1-min load average as % of CPU count |
| `cpu.load1` / `cpu.load5` / `cpu.load15` | raw load averages |
| `cpu.count` | logical CPU count |
| `cpu.util_pct` | actual CPU busy % since the previous sample |
| `cpu.temp` / `cpu.temp_max` | CPU temperature (°C) and its 80 °C scale hint |
| `ram.used_mb` / `ram.total_mb` / `ram.used_pct` | memory usage |
| `net.rx_kbs` / `net.tx_kbs` | default-interface throughput (KiB/s) |
| `net.rx_mbs` / `net.tx_mbs` | default-interface throughput (MiB/s) |
| `net.rx_total_mb` / `net.tx_total_mb` | bytes since boot (MiB) |
| `cpu.load_hist` | series: last 48 one-second load samples |
| `sys.host` / `sys.kernel` / `sys.cpu_model` / `sys.cpu` | text: hostname, kernel, CPU model, core count |
| `sys.uptime` / `sys.load` / `sys.mem` | text: uptime, load averages, memory use |
| `sys.net` / `sys.net_total` | text: interface + throughput / interface + totals |

```sh
./zig-out/bin/pimon-fb --layout layouts/pi-monitor.layout.zon   # Pi gauges + sparklines
./zig-out/bin/pimon-fb --layout layouts/win11-monitor.layout.zon # Win11 agent data
./zig-out/bin/pimon-fb --layout layouts/dashboard.layout.zon     # plain widgets
```

`layouts/win11-monitor.layout.zon` displays a Windows 11 machine fed by
`agents/win11` (CPU, RAM, network, GPU utilisation/VRAM/temperature, histories,
system information, plus a large colour-coded “Windows Time” date/time row
under the GPU/network gauges).
See `agents/win11/README.md` for building and running the agent.

`layouts/pi-monitor.layout.zon` is the full system monitor: CPU load, CPU
utilisation, temperature, RAM, network down/up gauges, load history, and a
system-information panel (hostname, kernel, CPU model, uptime, load, memory,
network totals).

### Reusable widgets (usable without the layout engine)

The custom drawing lives in its own module so both screens and your own code
can use it:

| API | What it does |
| --- | --- |
| `widgets.arc.arc(x, y, r, a0, a1, anticlockwise, thickness, color)` | Canvas-style arc, stroked once |
| `widgets.arc.arcWithCaps(...)` | the same, with round end caps |
| `widgets.arc.disc(x, y, r, color)` | filled circle |
| `widgets.gauge.cell(id_extra, title, opts, unit, w, h, opts)` | full gauge cell: title, ring, centred value + unit |
| `widgets.gauge.drawRing(rs, opts)` | just the ring, into a `RectScale` |
| `widgets.sparkline.draw(rs, series, color)` | line chart into a `RectScale` |
| `widgets.palette.parse("green" \| "ff8000")` | colour from a name or hex |

The gauge is built exactly as described: **draw the background arc first, then
lay the coloured value arc on top** — `arc.arcWithCaps` gives both round ends,
which is what makes a thick progress ring look finished.  The arc itself is a
port of a Canvas `arc()` re-implementation, normalised to a single turn and
subdivided to about one segment per two pixels.

### Adding your own custom component

That is exactly what `gauge` and `sparkline` are — three edits in one file
(`src/layout.zig`), then usable from any `.layout.zon`:

1. **Name it** — add a variant to `Component`:
   ```zig
   pub const Component = enum { vbox, hbox, label, ..., gauge, sparkline, battery };
   ```
2. **Give it properties** — add optional fields to `Node` (anything absent in
   the `.zon` stays `null`):
   ```zig
   /// Battery percentage, 0..100 (battery).
   level: ?f32 = null,
   bind_level: ?[]const u8 = null,
   ```
3. **Render it** — add a case in `renderNode`, using the per-component `opts`
   (which already carries `id_extra = <index within parent>`, so sibling
   instances of your component get distinct DVUI ids). Use
   `dvui.currentWindow().arena()` for any temporary path buffers:
   ```zig
   .battery => {
       const level = if (node.bind_level) |k| b.getFloat(k) orelse node.level orelse 0 else node.level orelse 0;
       var box = dvui.box(@src(), .{}, opts.override(.{ .min_size_content = .{ .w = 120, .h = 24 } }));
       defer box.deinit();
       // ... draw using box.data().rectScale() ...
   },
   ```
4. Optionally add a schema test next to the existing ones.

No recompile of the layout is needed for anything you *don't* change here —
rearranging, retitling, rebinding and reordering are all data-only edits.

```zig
.{
    .component = .hbox,
    .children = .{
        .{ .component = .checkbox, .bind = "settings.perf_mode", .text = " Performance mode" },
        .{ .component = .button, .text = "Apply", .action = "save" },
    },
}
```

A whole file is one such `.{ ... }` object — see `layouts/dashboard.layout.zon`.

### How it works

* **Parsing** uses Zig's built-in `std.zon` with a recursive typed schema — no
  third-party runtime ZON package. Unknown components fail loudly with the list
  of valid ones:
  ```
  error: unexpected enum literal 'sparkle'
  note: supported: 'vbox', 'hbox', 'label', 'title', 'heading', 'button', 'checkbox', 'separator', 'spacer'
  ```
* **Widget IDs**: DVUI derives ids from `@src()` + `Options.id_extra`. Each
  component kind has one fixed call site inside the interpreter, so
  same-kind siblings are disambiguated with `id_extra = <index within parent>`
  (DVUI's documented loop pattern).
* **Bindings**: every `bind` key in the tree is registered at load time so the
  map never rehashes while DVUI holds a `*bool` mid-frame.
* **Actions**: a pressed button sets the action; the main loop consumes it with
  `Bindings.takeAction()`. Built-in: `quit`, `reload_layout`.
* A load/parse failure is shown **in the UI** (red) and the app keeps running —
  an always-present Quit/Reload bar means a broken file can never strand you,
  even on a touchscreen with no keyboard.

## Touchscreen (official Raspberry Pi 7" panel)

SDL2's Linux evdev input requires `ABS_MT_PRESSURE` before it will register a
touchscreen.  The official 7" panel does not expose that axis, so SDL drops the
device and touch never reaches DVUI.  `pimon` detects this (SDL reports 0 touch
devices) and reads the evdev node directly, posting DVUI touch events.  The
software framebuffer backend always reads evdev directly and also synthesizes
press/release from `ABS_MT_TRACKING_ID`, so the same panel works there too
(it does not need `BTN_TOUCH`).

```sh
# automatic (default): use evdev touch when SDL has no touch device
./pimon-sdl

# force / disable the evdev reader
./pimon-sdl --touch
./pimon-sdl --no-touch

# pick a specific node
./pimon-sdl --touch-device /dev/input/event0

# if the panel is rotated / mirrored
./pimon-sdl --touch-swap --touch-invert-x     # 90/270 degree rotation
./pimon-sdl --touch-invert-x --touch-invert-y # 180 degree rotation
```

Touches are mapped from the kernel's absolute ranges to normalized window
coordinates, so they track the panel regardless of its resolution.  Autodetect
prefers a touchscreen over a relative mouse when both are present.  The `input`
group (or root) is required to read `/dev/input/event*`; if no device is found
`pimon` logs a warning telling you to check permissions or pass `--pointer`.
The `--touch-*` flags above apply to the SDL front-end; the fb front-end
autodetects the panel automatically.

## Running as a service (optional)

`/etc/systemd/system/pimon.service`:

```ini
[Unit]
Description=pimon dashboard
After=multi-user.target

[Service]
ExecStart=/usr/local/bin/pimon-sdl --fps 30
Restart=always
User=pi
SupplementaryGroups=video input

[Install]
WantedBy=multi-user.target
```

This works with the SDL2/KMSDRM backend as long as the service owns the DRM
device (it does when it starts on a free VT). If SDL cannot become DRM master,
add `--no-drm-master` and make sure no other compositor is running.

## Troubleshooting

* **`SDL_Init ... error=kmsdrm not available`** — SDL2 was built without the
  KMSDRM driver, or you are running under X/Wayland. On Raspberry Pi OS the
  packaged SDL2 has it; otherwise use `--video-driver x11` for a desktop test.
* **`AccessDenied` / no `/dev/dri/card0`** — add your user to the `video`
  group, or run with `sudo`.
* **Everything is black / instantly exits** — check the console output; make
  sure you are on a free VT. Disable console blanking with `consoleblank=0` in
  `/boot/firmware/cmdline.txt` (older images: `/boot/cmdline.txt`).
* **Tearing** — keep vsync on (the default). For a faster, tear-free present
  the KMSDRM driver can also use double buffering; SDL does this by default.
* **`-Dgui=fb` says "cannot use framebuffer"** — the file needs `--size WxH
  --bpp 32`, or you lack permission on `/dev/fb0` (be in the `video` group).

## Tests

```sh
zig build test -Dgui=fb        # unit tests for the framebuffer/software path
```
