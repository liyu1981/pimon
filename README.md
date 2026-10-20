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
src/dashboard.zig    shared dashboard UI and /proc sampling
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

Keyboard controls (both backends): `Tab`/`Shift-Tab` move focus, `Enter`/`Space`
activate, `Esc` or the Quit button exits.

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
