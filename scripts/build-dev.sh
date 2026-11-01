#!/usr/bin/env bash
# Build development binaries for the host + Windows agent.
set -euo pipefail
cd "$(dirname "$0")/.."

ZIG="${ZIG:-zig}"
OUT="dist/dev"
rm -rf "$OUT"
mkdir -p "$OUT"

echo "==> host SDL2 backend (Debug)"
"$ZIG" build

echo "==> host framebuffer backend (Debug)"
"$ZIG" build -Dgui=fb

echo "==> Windows 11 agent (Debug)"
"$ZIG" build win

cp -f zig-out/bin/pimon-sdl "$OUT/"
cp -f zig-out/bin/pimon-fb "$OUT/"
cp -f zig-out/bin/pimon-agent-win11.exe "$OUT/"

echo
echo "development binaries:"
ls -lh "$OUT"
