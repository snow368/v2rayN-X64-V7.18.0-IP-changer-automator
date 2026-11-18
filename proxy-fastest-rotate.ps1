# proxy-fastest-rotate.ps1   (ASCII only -- PS 5.1 reads BOM-less files as ANSI/936)
# ===========================================================================
# PERIODIC outbound rotation for v2rayN (xray core, v2rayN 7.x).
# Different job from proxy-node-switcher.ps1 (that one is a captcha RESCUE).
# This one simply rotates to a DIFFERENT low-latency node on a timer, so the
# Google exit IP stays "fresh". Never touches scraper / Chrome / guardian.
#
# WHY "different fast node" and not literally "the fastest":
#   the active node is often already the fastest in the pool, so "pick the
#   fastest" would be a no-op forever. We rotate identity among the fastest
#   nodes, excluding the current one + the last 3 used (see $RecentExclude).
#
# PATHS / AGE CHECKS are all parameters -> portable to another Windows box
# with v2rayN 7.x (xray core) + same guiNDB.db schema.
#
# Usage:
#   ... -WhatIfOnly                      # dry run: read + pick, change nothing
#   ...                                  # real run: rotate if cooldown elapsed
#   ... -Force -WhatIfOnly               # force dry run (ignore cooldown)
# ===========================================================================
param(
  [string]$V2rayDir   = "",   # empty = auto-detect v2rayN 7.x install
  [string]$GuiConfig  = "",
  [string]$DbPath     = "",
  [string]$PyExe      = "",   # empty = auto-detect Python 3
  [int]$IntervalMin   = 30,      # rotate at most once per this many minutes
  [int]$RecentExclude = 3,       # do not rotate back to any of last N nodes
  [int]$MaxLatencyMs  = 500,     # candidate must be faster than this
  [switch]$ProbeOnly,            # detect env + show pool, change NOTHING
  [switch]$WhatIfOnly,
  [switch]$Force
)

$ErrorActionPreference = 'Continue'
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss'

# v2rayN auto-detect: explicit -V2rayDir > env V2RAYN_DIR > common install paths
# (works on a machine that does NOT run the scraper at all)
function Find-V2rayDir {
  if ($V2rayDir -and (Test-Path -LiteralPath (Join-Path $V2rayDir 'v2rayN.exe'))) { return $V2rayDir }
  if ($env:V2RAYN_DIR -and (Test-Path -LiteralPath (Join-Path $env:V2RAYN_DIR 'v2rayN.exe'))) { return $env:V2RAYN_DIR }
  $cands = @()
  foreach ($k in @('HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*','HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*','HKCU:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*')) {
    try { Get-ItemProperty $k -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -match 'v2rayN' -and $_.InstallLocation } | ForEach-Object { $cands += $_.InstallLocation } } catch { }
  }
  $cands += @(
    (Join-Path $env:LOCALAPPDATA 'v2rayN'),
    (Join-Path $env:ProgramFiles 'v2rayN'),
    (Join-Path $env:USERPROFILE 'v2rayN-windows-64\v2rayN-windows-64'),
    'F:\v2rayN-windows-64\v2rayN-windows-64','C:\v2rayN-windows-64\v2rayN-windows-64'
  )
  foreach ($c in $cands) { if ($c -and (Test-Path -LiteralPath (Join-Path $c 'v2rayN.exe'))) { return $c } }
  return $null
}
$detectedDir = Find-V2rayDir
if (-not $detectedDir) { Write-Host "FATAL: v2rayN not found. Pass -V2rayDir <path> or set V2RAYN_DIR env var."; exit 1 }
$V2rayDir = $detectedDir
if (-not $GuiConfig) { $GuiConfig = Join-Path $V2rayDir 'guiConfigs\guiNConfig.json' }
if (-not $DbPath)    { $DbPath    = Join-Path $V2rayDir 'guiConfigs\guiNDB.db' }

# python auto-detect: explicit -PyExe > env PYTHON_EXE > py launcher > python on PATH
function Find-Py {
  if ($PyExe -and (Test-Path -LiteralPath $PyExe)) { return $PyExe }
  if ($env:PYTHON_EXE -and (Test-Path -LiteralPath $env:PYTHON_EXE)) { return $env:PYTHON_EXE }
  try { $c = Get-Command python.exe -ErrorAction SilentlyContinue; if ($c) { return $c.Source } } catch { }
  try { $c = Get-Command py.exe -ErrorAction SilentlyContinue; if ($c) { return $c.Source } } catch { }
  return $null
}
$detectedPy = Find-Py
if (-not $detectedPy) { Write-Host "FATAL: Python 3 not found. Pass -PyExe <path> or set PYTHON_EXE env var."; exit 1 }
$PyExe = $detectedPy

# self-contained layout: logs/state live NEXT TO THIS SCRIPT (portable, no engine root)
$root      = if ($PSScriptRoot) { $PSScriptRoot } else { Split-Path -Parent $MyInvocation.MyCommand.Path }
$logFile   = Join-Path $root '_proxy_rotate.log'
$stateFile = Join-Path $root '_proxy_rotate_state.json'
$backupDir = Join-Path $root '_proxy_rotate_backup'
$lockFile  = Join-Path $root '_proxy_rotate.lock'

function Say($m) {
  Write-Host $m
  if ($WhatIfOnly) { return }
  try { Add-Content -LiteralPath $logFile -Value ("[" + (Get-Date -Format 'HH:mm:ss') + "] " + $m) -ErrorAction SilentlyContinue } catch { }
}

# ---- 0) sanity + cross-script lock -----------------------------------------
if (-not (Test-Path -LiteralPath $GuiConfig)) { Say "FATAL: guiNConfig.json missing: $GuiConfig"; exit 1 }
if (-not (Test-Path -LiteralPath $DbPath))    { Say "FATAL: guiNDB.db missing: $DbPath"; exit 1 }
if (-not (Test-Path -LiteralPath $PyExe))     { Say "FATAL: python missing: $PyExe"; exit 1 }

# mutual exclusion with the captcha-rescue script proxy-node-switcher.ps1:
# both kill/relaunch v2rayN, so they must never run at the same time.
# The rescue script does NOT write a .lock file -- it writes
# _proxy_switch_state.json (last_switch) and logs to _proxy_switch.log.
# Detect it via (a) a rescue switch in the last 5 min, and (b) a live rescue process.
$engineRoot = Split-Path -Parent $root
if (-not $Force) {
  $rescueStatePath = Join-Path $engineRoot '_proxy_switch_state.json'
  if (Test-Path -LiteralPath $rescueStatePath) {
    try {
      $rs = Get-Content -LiteralPath $rescueStatePath -Raw | ConvertFrom-Json
      if ($rs.last_switch) {
        $rl = [datetime]$rs.last_switch
        if (((Get-Date) - $rl).TotalMinutes -lt 5) { Say "LOCKED: captcha-rescue switched $([math]::Round(((Get-Date)-$rl).TotalMinutes,1))min ago -> skip"; exit 0 }
      }
    } catch { }
  }
  try {
    $rescueProc = Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
      $_.Name -match 'powershell' -and $_.CommandLine -match 'proxy-node-switcher'
    }
    if ($rescueProc) { Say "LOCKED: captcha-rescue process running -> skip"; exit 0 }
  } catch { }
}

Say "===== proxy-fastest-rotate $stamp ====="

# ---- ProbeOnly: report environment + fast-node pool, change NOTHING ---------
if ($ProbeOnly) {
  Say ("ENV: v2rayN  = " + $V2rayDir)
  Say ("ENV: config  = " + $GuiConfig)
  Say ("ENV: db      = " + $DbPath)
  Say ("ENV: python  = " + $PyExe)
  $probeCode = @'
import sqlite3, json, sys
c=sqlite3.connect('file:'+sys.argv[1].replace('\\','/')+'?mode=ro',uri=True); c.row_factory=sqlite3.Row
g=json.load(open(sys.argv[2],encoding='utf-8')); cur=str(g.get('IndexId',''))
q='''select p.Remarks,p.Address,p.Port,e.Delay,p.IndexId from ProfileItem p join ProfileExItem e on p.IndexId=e.IndexId where e.Delay>0 and e.Delay<=? and p.Address not like '127.%' order by e.Delay asc'''
rows=[dict(r) for r in c.execute(q,(int(sys.argv[3]),))]
out=[]
for i,r in enumerate(rows[:5]):
    out.append(('CUR ' if str(r['IndexId'])==cur else '    ')+str(r['Delay'])+'ms '+str(r['Remarks'])+' '+str(r['Address'])+':'+str(r['Port']))
print(json.dumps({'pool':len(rows),'top':out},ensure_ascii=True))
'@
  $pr = & $PyExe -c $probeCode $DbPath $GuiConfig ([string]$MaxLatencyMs) 2>&1
  if ($LASTEXITCODE -eq 0) {
    try {
      $pj = ($pr | Out-String | ConvertFrom-Json)
      Say ("POOL: " + $pj.pool + " fast nodes (<=" + $MaxLatencyMs + "ms)")
      foreach ($line in $pj.top) { Say ("  " + $line) }
    } catch { Say ("probe query parse failed: " + $pr) }
  } else { Say ("probe query failed: " + $pr) }
  Say "PROBE ONLY -> no change. READY."
  Say "===== done (probe) ====="
  exit 0
}

# ---- 1) cooldown ------------------------------------------------------------
$state = $null
if (Test-Path -LiteralPath $stateFile) { try { $state = Get-Content -LiteralPath $stateFile -Raw | ConvertFrom-Json } catch { } }
$recent = @()
if ($state -and $state.history) { $recent = @($state.history | Select-Object -First $RecentExclude | ForEach-Object { [string]$_.idx }) }
$last = $null
if ($state -and $state.last_switch) { try { $last = [datetime]$state.last_switch } catch { $last = $null } }
if (-not $Force -and $last -ne $null) {
  $cool = ((Get-Date) - $last).TotalMinutes
  if ($cool -lt $IntervalMin) {
    Say ("cooldown: last rotate " + [math]::Round($cool,1) + "min ago < " + $IntervalMin + "min -> no action")
    Say "===== done (cooldown) ====="
    exit 0
  }
}

# ---- 2) pick a different fast node via python/sqlite ------------------------
$code = @'
import sqlite3, json, sys
db=sys.argv[1]; cfg=sys.argv[2]; maxms=int(sys.argv[3])
recent=set([x for x in sys.argv[4].split(',') if x]) if len(sys.argv)>4 else set()
c=sqlite3.connect('file:'+db.replace('\\','/')+'?mode=ro',uri=True); c.row_factory=sqlite3.Row
g=json.load(open(cfg,encoding='utf-8'))
cur=str(g.get('IndexId',''))
q='''select p.IndexId,p.Remarks,p.Address,p.Port,e.Delay
     from ProfileItem p join ProfileExItem e on p.IndexId=e.IndexId
     where e.Delay>0 and e.Delay<=? and p.Address not like '127.%' order by e.Delay asc'''
rows=[dict(r) for r in c.execute(q,(maxms,))]
cur_row=next((r for r in rows if str(r['IndexId'])==cur),None)
cands=[r for r in rows if str(r['IndexId'])!=cur and str(r['IndexId']) not in recent]
if not cands: cands=[r for r in rows if str(r['IndexId'])!=cur]
tgt=cands[0] if cands else None
print(json.dumps({'current':cur_row,'target':tgt,'pool_size':len(rows)},ensure_ascii=True))
'@
$pyArgs=@('-c',$code,$DbPath,$GuiConfig,[string]$MaxLatencyMs,($recent -join ','))
$raw=& $PyExe @pyArgs 2>&1
if ($LASTEXITCODE -ne 0) { Say "FATAL: python node query failed: $raw"; exit 1 }
try { $pick=($raw|Out-String|ConvertFrom-Json) } catch { Say "FATAL: parse node query failed: $raw"; exit 1 }
if (-not $pick.target) { Say "FATAL: no candidate fast node"; exit 1 }
$cRemarks=if($pick.current){$pick.current.Remarks}else{'(unknown)'}
$cIdx=if($pick.current){[string]$pick.current.IndexId}else{''}
$t=$pick.target
Say ("node: current=" + $cRemarks + " idx=" + $cIdx)
Say ("node: target =" + $t.Remarks + " " + $t.Address + ":" + $t.Port + " delay=" + $t.Delay + "ms idx=" + $t.IndexId + "  (pool=" + $pick.pool_size + " fast nodes)")
if ($cIdx -eq [string]$t.IndexId) { Say "target == current -> no action"; exit 0 }

if ($WhatIfOnly) {
  Say "WhatIfOnly -> WOULD rotate v2rayN to '$($t.Remarks)' ($($t.Address):$($t.Port)); nothing changed."
  Say "===== done (dry run) ====="
  exit 0
}

# ---- 3) lock + patch config (kill v2rayN -> edit -> relaunch -> verify) -----
try { Set-Content -LiteralPath $lockFile -Value $stamp -Encoding ASCII -ErrorAction Stop } catch { }
try {
  if (-not (Test-Path -LiteralPath $backupDir)) { New-Item -ItemType Directory -Path $backupDir -Force | Out-Null }
  $backup=Join-Path $backupDir ("guiNConfig."+$stamp+".json")
  Copy-Item -LiteralPath $GuiConfig -Destination $backup -Force
  Say "backup: $backup"

  $cfgText=Get-Content -LiteralPath $GuiConfig -Raw -Encoding UTF8
  if ($cfgText -notmatch '"IndexId"\s*:\s*"\d+"') { throw "IndexId not found in guiNConfig.json" }
  $newCfg=[regex]::Replace($cfgText,'"IndexId"\s*:\s*"\d+"','"IndexId": "'+[string]$t.IndexId+'"',1)
  if ($newCfg -eq $cfgText) { throw "config patch produced no change" }

  $toKill=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object {
    $_.ExecutablePath -and $_.ExecutablePath.StartsWith($V2rayDir,[StringComparison]::OrdinalIgnoreCase) -and
    $_.Name -match '^(v2rayN|xray)\.exe$'
  })
  foreach($p in $toKill){ try{ Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; Say ("stopped "+$p.Name+" pid="+$p.ProcessId) }catch{ Say ("stop failed pid="+$p.ProcessId+": "+$_.Exception.Message) } }
  Start-Sleep -Seconds 3
  Set-Content -LiteralPath $GuiConfig -Value $newCfg -Encoding UTF8 -ErrorAction Stop
  Say ("patched IndexId -> "+$t.IndexId)

  $exeN=Join-Path $V2rayDir 'v2rayN.exe'
  Start-Process -FilePath $exeN -WorkingDirectory $V2rayDir -ErrorAction Stop
  Say "relaunched v2rayN"

  # verify socks port + Google 204 through system proxy
  $ok=$false; $proxyPort=10808
  try { $wi=Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings'; if($wi.ProxyServer -match '(\d{2,5})\s*$'){ $proxyPort=[int]$Matches[1] } } catch { }
  for($i=0;$i -lt 12;$i++){
    Start-Sleep -Seconds 3
    $tcp=$false
    try{ $cl=New-Object Net.Sockets.TcpClient; $a=$cl.BeginConnect('127.0.0.1',$proxyPort,$null,$null); $tcp=$a.AsyncWaitHandle.WaitOne(1500,$false) -and $cl.Connected; $cl.Close() }catch{ }
    if($tcp){ Say ("socks "+$proxyPort+" UP after "+(3*($i+1))+"s"); $ok=$true; break }
  }
  if($ok){
    $g=$false
    try{ $r=Invoke-WebRequest -Uri 'https://www.google.com/generate_204' -TimeoutSec 12 -UseBasicParsing; $g=($r.StatusCode -eq 204) }catch{ }
    Say ("google_204="+$g)
    if(-not $g){ $ok=$false; Say "WARN: socks up but Google 204 failed" }
  }
  if(-not $ok){ throw "verify failed" }

  # record state
  $hist=@(); if($state -and $state.history){ $hist=@($state.history) }
  $entry=[ordered]@{idx=[string]$t.IndexId;remarks=[string]$t.Remarks;at=(Get-Date -Format 'o');reason='periodic_rotate delay='+$t.Delay+'ms'}
  $hist=@($entry)+$hist; if($hist.Count -gt 10){ $hist=$hist[0..9] }
  $o=[ordered]@{last_switch=(Get-Date -Format 'o');current_idx=[string]$t.IndexId;history=$hist;updated=(Get-Date -Format 'o')}
  try{ ($o|ConvertTo-Json -Depth 4)|Set-Content -LiteralPath $stateFile -Encoding UTF8 }catch{ Say "WARN: state save failed" }
  Say ("ROTATED to '$($t.Remarks)' "+$t.Address+":"+$t.Port+" -- scraper will retry any dropped page")
  Say "===== done (rotated) ====="
} catch {
  Say ("ERROR: "+$_.Exception.Message+" -> rollback")
  try{
    $kill2=@(Get-CimInstance Win32_Process -ErrorAction SilentlyContinue | Where-Object { $_.ExecutablePath -and $_.ExecutablePath.StartsWith($V2rayDir,[StringComparison]::OrdinalIgnoreCase) -and $_.Name -match '^(v2rayN|xray)\.exe$' })
    foreach($p in $kill2){ Stop-Process -Id $p.ProcessId -Force -ErrorAction SilentlyContinue }
  }catch{ }
  Start-Sleep -Seconds 3
  if($backup){ Copy-Item -LiteralPath $backup -Destination $GuiConfig -Force }
  try{ Start-Process -FilePath (Join-Path $V2rayDir 'v2rayN.exe') -WorkingDirectory $V2rayDir }catch{ }
  Say "rolled back config + relaunched v2rayN (previous node)"
  Say "===== done (rollback) ====="
} finally {
  try{ Remove-Item -LiteralPath $lockFile -Force -ErrorAction SilentlyContinue }catch{ }
}
exit 0
