# pimon Win11 agent

Windows 11 tray application for monitoring a pimon server on a Raspberry Pi.

It samples local CPU, memory, network, system information and GPU metrics and
pushes typed JSON batches to pimon over `POST /api/v1/data`.  The app starts with its window visible; use `--hidden` to start minimised to the
system tray.  Double-click the tray icon (or right-click → Open) to bring the
window back.

## Build

```sh
zig build win -Doptimize=ReleaseSafe
# → zig-out/bin/pimon-agent-win11.exe  (x86_64-windows-gnu)
```

Two Windows UIs are available:

```sh
zig build win -Doptimize=ReleaseSafe       # native Win32 controls
zig build win-ui -Doptimize=ReleaseSafe    # DVUI + DX11 UI
zig build win-ui-debug -Doptimize=Debug    # console diagnostic version
```

The native build is the fallback for machines without D3D11 (some RDP/VM
sessions).  The DVUI build has a real multiline config editor, a scrolling
coloured log view, themed buttons and the same tray/worker behaviour.  Both
load NVML dynamically when an NVIDIA adapter is present.

## First run

If `%APPDATA%\pimon\agent.config` does not exist, the app opens its window
with a template you can edit directly.  Fill in `PIMON_URL` and
`PIMON_HTTP_SECRET`, click **Save Config**, then **Start**.

You can also create the file and open it in Notepad:

```powershell
.\pimon-agent-win11.exe install-config
```

This writes `%APPDATA%\pimon\agent.config` if it does not already exist
(never overwrites) and launches Notepad.  Use `--config PATH` for another
location:

```powershell
.\pimon-agent-win11.exe install-config --config C:\pimon\agent.config
```

The file uses env-file syntax:

```ini
PIMON_URL=http://192.168.1.50:8717
PIMON_HTTP_SECRET=<pimon bearer token>
PIMON_INTERVAL_MS=1000
PIMON_AGENT_NAME=win11
PIMON_ENABLE_GPU=1
```

## Running

Native UI:

```text
pimon-agent-win11.exe ...
```

DVUI UI:

```text
pimon-agent-win11-ui.exe ...
```

Both accept the same flags:

```text
--hidden        start minimised in the system tray
--config PATH   alternate config
--once          one sample + upload, result in a message box
install-config  create config and open Notepad
```

The native UI is the default; use `-ui` for the themed editor/log window.

Window controls:

- **Start / Stop** — control the sampling worker.
- **Save Config** — write the editor contents to `agent.config`.
- **Reload** — discard edits and reload the file.
- **Hide** — return to the tray.
- **Exit** — stop the worker and quit.  Closing the window only hides it.

The tray menu also has Open, Start, Stop and Exit.

Startup diagnostics are appended to `%TEMP%\pimon-agent-win11.log` (for example
`C:\Users\<you>\AppData\Local\Temp\pimon-agent-win11.log`).  The DVUI build
uses `%TEMP%\pimon-agent-win11-ui.log`.  If the window never appears, send the
relevant file.

For terminal diagnostics build the console variant:

```sh
zig build win-debug -Doptimize=Debug
# → zig-out/bin/pimon-agent-win11-debug.exe
```

Running `pimon-agent-win11-debug.exe` in PowerShell prints the same startup
stages to the terminal and writes the log file.

## Keys

Floats:

```text
win.cpu.util_pct        win.cpu.queue
win.ram.used_pct        win.ram.used_mb       win.ram.total_mb
win.net.rx_mbs          win.net.tx_mbs
win.net.rx_total_mb     win.net.tx_total_mb
win.gpu.util_pct        win.gpu.mem_pct
win.gpu.mem_used_mb     win.gpu.mem_total_mb
win.gpu.temp_c          win.gpu.power_w      (when the provider exposes them)
```

Series:

```text
win.cpu.util_hist       48-sample CPU history
win.gpu.util_hist       48-sample GPU history
```

Text:

```text
win.sys.host  win.sys.os  win.sys.cpu_model  win.sys.cpu
win.sys.uptime  win.sys.mem  win.sys.net  win.sys.updated
win.sys.updated.weekday  win.sys.updated.year  win.sys.updated.month
win.sys.updated.day      win.sys.updated.hour  win.sys.updated.minute
win.sys.updated.second
win.net.name  win.gpu.name  win.gpu.provider
```

Boolean: `win.online`.

## GPU providers

- **DXGI** — adapter name, dedicated VRAM, live local memory usage.
- **PDH** — `\GPU Engine(*)\Utilization Percentage`, works for NVIDIA, AMD and
  Intel.  The maximum engine instance is reported as GPU utilisation.
- **NVML** — loaded dynamically for NVIDIA adapters; adds utilisation, VRAM,
  temperature and power.

AMD ADL/ADLX and LibreHardwareMonitor are not bundled in this version.  AMD
utilisation/VRAM already work through PDH/DXGI; add ADL only if GPU temperature
or power is needed on a specific AMD machine.

Each upload uses a fresh HTTP connection.  After Windows sleep/hibernate the
agent detects the elapsed-time gap, recreates its HTTP client, and retries a
failed upload once.  The `win.sys.updated` text key carries the Windows local
sample time, so `win11-monitor` shows the last successful update.

For automatic startup use Task Scheduler ("At log on") or a service wrapper
such as NSSM.  A native Windows service mode is not implemented yet; GPU
performance counters may require the `Performance Monitor Users` group for a
service account.

## Security

The pimon server has no TLS.  Use a trusted LAN or an SSH/VPN tunnel, and keep
`PIMON_HTTP_SECRET` private.  The agent never logs the token.
