# pimon Win11 agent

Headless Windows 11 metrics agent for a pimon server on a Raspberry Pi.

It samples local CPU, memory, network, system information and GPU metrics and
pushes typed JSON batches to pimon over `POST /api/v1/data`.  There is no UI on
Windows.

## Build

```sh
zig build win -Doptimize=ReleaseSafe
# → zig-out/bin/pimon-agent-win11.exe  (x86_64-windows-gnu)
```

The agent uses only Win32/PDH/DXGI APIs; it does not depend on DVUI or SDL.
NVML (`nvml.dll`) is loaded dynamically when an NVIDIA adapter is present.

## Config

Create the config and open it in Notepad:

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

Use `--config PATH` to point elsewhere.  CLI overrides:

```text
pimon-agent-win11 --url http://pi:8717 --token ... --interval-ms 1000 --once
```

- `--once` samples once, posts, and exits (useful for smoke tests).
- `--no-gpu` disables GPU collection.
- `--verbose` prints the JSON batch.

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
win.sys.uptime  win.sys.mem  win.sys.net
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

## Running

```text
pimon-agent-win11.exe --once -v
pimon-agent-win11.exe
```

For automatic startup use Task Scheduler ("At log on") or a service wrapper
such as NSSM.  A native Windows service mode is not implemented yet; GPU
performance counters may require the `Performance Monitor Users` group for a
service account.

## Security

The pimon server has no TLS.  Use a trusted LAN or an SSH/VPN tunnel, and keep
`PIMON_HTTP_SECRET` private.  The agent never logs the token.
