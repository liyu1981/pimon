# Agent Notes

## Git commit rule

- **Do not commit unless the user explicitly asks.**
- If the user asks to commit, make **exactly one commit** with:
  - a **concise title** (imperative, <= ~72 chars, no trailing period),
  - a **detail body** explaining what changed and why (wrap ~72 chars).
- After committing, **return to the state of waiting for a commit ask** — do not
  commit again until the user asks.

Do not run `git add -A` / `git commit` as part of ordinary work. Only stage and
commit when the user requests it.

## Build / verify

- `zig build` — SDL2 (KMSDRM) backend, built from vendored source.
- `zig build -Dgui=fb` — software `/dev/fb0` backend; `zig build test -Dgui=fb`
  runs its unit tests.
- `zig build pi2` — both ARMv7 binaries (`pimon-pi2-sdl`, `pimon-pi2-fb`).
- `zig fmt --check build.zig src/*.zig vendor/sdl2/build.zig` before committing.
