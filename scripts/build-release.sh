#!/usr/bin/env bash
# Build release binaries: Raspberry Pi 2, host, and Windows agent.
set -euo pipefail
cd "$(dirname "$0")/.."

ZIG="${ZIG:-zig}"
OUT="dist/release"
rm -rf "$OUT"
mkdir -p "$OUT"

echo "==> Raspberry Pi 2 ARMv7 (ReleaseFast: SDL2 + framebuffer)"
"$ZIG" build pi2

echo "==> host SDL2 backend (ReleaseFast)"
"$ZIG" build -Doptimize=ReleaseFast

echo "==> host framebuffer backend (ReleaseFast)"
"$ZIG" build -Doptimize=ReleaseFast -Dgui=fb

echo "==> Windows 11 agent (ReleaseSafe)"
"$ZIG" build win -Doptimize=ReleaseSafe
"$ZIG" build win-ui -Doptimize=ReleaseSafe

cp -f zig-out/bin/pimon-pi2-sdl "$OUT/"
cp -f zig-out/bin/pimon-pi2-fb "$OUT/"
cp -f zig-out/bin/pimon-sdl "$OUT/"
cp -f zig-out/bin/pimon-fb "$OUT/"
cp -f zig-out/bin/pimon-agent-win11.exe "$OUT/"
cp -f zig-out/bin/pimon-agent-win11-ui.exe "$OUT/"

echo
echo "release binaries:"
ls -lh "$OUT"
