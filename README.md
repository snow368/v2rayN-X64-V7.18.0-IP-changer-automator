# v2rayN 7.x — Automatic Fastest-IP Rotation

A standalone PowerShell script that **periodically switches v2rayN's outbound node to a different low-latency node**, keeping the exit IP seen by Google "fresh".

No scraper, no crawler project required — it works on any Windows machine that has v2rayN 7.x installed.

---

## What it does

Every interval (30 minutes by default), the script:

1. Reads v2rayN's node database and collects all fast nodes with latency ≤ 500 ms
2. Picks one that is **different from the current node** and not used in the last few rotations
3. Stops v2rayN → patches the config → relaunches → verifies the socks port and Google connectivity
4. On failure, automatically rolls back to the previous node

### Why "a different fast node" instead of literally "the fastest"

The currently active node is usually **already the fastest one** — so "pick the fastest" would be a no-op forever. The script therefore rotates the *exit identity* within the fast-node pool, rather than chasing a few milliseconds of latency.

> Switching IPs addresses "this exit IP has been flagged by Google", not "the connection is slow". It does not guarantee higher speed, nor does it eliminate CAPTCHAs — frequent switching can actually look more bot-like. Set the interval accordingly.

---

## Requirements

| Item | Requirement |
|---|---|
| OS | Windows + PowerShell 5.1 (built in) |
| Client | **v2rayN 7.x (xray core)** — not Clash/mihomo; they use a different switching mechanism |
| Python | **Python 3** (used to read the node sqlite DB; standard library only, no pip install needed) |

The script depends on these two v2rayN 7.x files:
- `guiConfigs\guiNDB.db` (node tables `ProfileItem` / `ProfileExItem`)
- `guiConfigs\guiNConfig.json` (current node `IndexId`)

---

## Quick start

### 1. Copy the script

Put `proxy-fastest-rotate.ps1` anywhere you like — logs are written next to the script itself.

### 2. Self-check (changes nothing)

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\proxy-fastest-rotate.ps1" -ProbeOnly
```

You should see output like this. If it ends with `READY.`, environment detection is fine:

```
ENV: v2rayN  = F:\v2rayN-windows-64\v2rayN-windows-64
ENV: python  = C:\Users\You\AppData\Local\Programs\Python\Python312\python.exe
POOL: 31 fast nodes (<=500ms)
  CUR 68ms CF-Premium-28 172.64.229.146:443
      90ms CF-Premium-13 172.64.229.135:2083
      ...
PROBE ONLY -> no change. READY.
```

`CUR` marks the current node. If paths are not detected, see "Path detection" below.

### 3. Dry run (no real switch)

```powershell
powershell.exe -NoProfile -ExecutionPolicy Bypass -File ".\proxy-fastest-rotate.ps1" -WhatIfOnly
```

It prints which node would be selected but **does not stop any process or modify any file**. Verify the logic before going further.

### 4. Register the scheduled task (real automation)

Run this in PowerShell (replace the path with your own):

```powershell
$script = "D:\your\path\proxy-fastest-rotate.ps1"
$action = New-ScheduledTaskAction -Execute 'powershell.exe' `
  -Argument ("-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$script`"")
$trigger = New-ScheduledTaskTrigger -Once -At (Get-Date).AddMinutes(2) `
  -RepetitionInterval (New-TimeSpan -Minutes 30) `
  -RepetitionDuration (New-TimeSpan -Days 3650)
$settings = New-ScheduledTaskSettingsSet -ExecutionTimeLimit (New-TimeSpan -Minutes 6) `
  -MultipleInstances IgnoreNew -StartWhenAvailable
$principal = New-ScheduledTaskPrincipal -UserId "$env:USERDOMAIN\$env:USERNAME" `
  -LogonType Interactive -RunLevel Limited
Register-ScheduledTask -TaskName 'V2rayN-Fastest-IP-Rotator' `
  -Action $action -Trigger $trigger -Settings $settings -Principal $principal -Force
```

> **Note**: In PowerShell 5.1 you must use the `-RepetitionInterval` form above to create a repeating trigger. Assigning `$trigger.Repetition.Interval` directly throws `PropertyNotFound`.

Check the task status:

```powershell
Get-ScheduledTaskInfo -TaskName 'V2rayN-Fastest-IP-Rotator'
```

`LastResult = 0` means the last run succeeded.

---

## Path detection

The script auto-detects v2rayN and Python in this order (no config needed normally):

| Target | Order |
|---|---|
| v2rayN | `-V2rayDir` param → `V2RAYN_DIR` env var → uninstall registry → common install paths |
| Python | `-PyExe` param → `PYTHON_EXE` env var → `python.exe` / `py.exe` on PATH |

If auto-detection fails, set an environment variable or pass a parameter:

```powershell
# Option 1: environment variables
$env:V2RAYN_DIR = "D:\v2rayN-windows-64\v2rayN-windows-64"
$env:PYTHON_EXE = "C:\Users\You\AppData\Local\Programs\Python\Python312\python.exe"

# Option 2: parameters
powershell.exe -File ".\proxy-fastest-rotate.ps1" -V2rayDir "D:\..." -PyExe "C:\..."
```

---

## Parameters

| Parameter | Default | Description |
|---|---|---|
| `-ProbeOnly` | off | Detect environment + list top 5 fast nodes; no cooldown check, no switch |
| `-WhatIfOnly` | off | Dry run: pick a node and print it, but touch no process or file |
| `-Force` | off | Ignore cooldown and run a full pass (for testing) |
| `-IntervalMin` | 30 | Minimum minutes between two rotations |
| `-RecentExclude` | 3 | Do not rotate back to any of the last N nodes |
| `-MaxLatencyMs` | 500 | Latency ceiling for candidate nodes (ms) |
| `-V2rayDir` / `-PyExe` | auto | Manually specify install paths |

---

## Files it creates

All files are written **next to the script**, nowhere else:

| File | Purpose |
|---|---|
| `_proxy_rotate.log` | Run log |
| `_proxy_rotate_state.json` | Last switch time + node history |
| `_proxy_rotate_backup\` | Config backup taken before each switch |
| `_proxy_rotate.lock` | Run lock (removed automatically when done) |

`guiNConfig.json` is backed up before switching. If verification fails (socks port down or Google 204 unreachable), the script restores the backup and relaunches the previous node.

---

## Notes

- Every switch **kills and restarts v2rayN — about 15 seconds offline**. Downloads or scrapes in progress will be interrupted.
- If another node-switching script runs on the same machine, the two may conflict. This script checks `_proxy_switch.lock` and skips the tick if another switch happened within 5 minutes.
- Switching IPs does not solve CAPTCHA itself; if your goal is bypassing Google's risk control, frequent switching may backfire.
- Only supports **v2rayN 7.x with the xray core**. Clash / mihomo / v2rayN 6.x are not supported.
