# WEPWAWET-CORE ground-station dashboard server (live + replay).
# Launch from <WORKDIR>:
#   powershell -ExecutionPolicy Bypass -File .\dashboard\wcore_dash.ps1
# Serves http://localhost:8088/ . Replay reads 05_RESULTS (read-only).
# Live starts only when the page switches to LIVE: one ssh per board running board_probe.sh,
# which is read-only (reads /proc, the F' hw-stats CSV, process list; never starts/stops anything).
# Stop with Ctrl+C (this also closes the two ssh sessions).
param([int]$Port = 8088, [string]$Root = "", [switch]$NoBrowser)
$ErrorActionPreference = "Stop"
$Here = Split-Path -Parent $MyInvocation.MyCommand.Path
if (-not $Root) { $Root = Split-Path -Parent $Here }
$Res = Join-Path $Root "05_RESULTS"
if (-not (Test-Path $Res)) { $Res = Join-Path $Root "results" }   # repository layout
$LiveDir = Join-Path $env:TEMP "wcore_dash_live"
New-Item -ItemType Directory -Force -Path $LiveDir | Out-Null
$Boards = [ordered]@{ aup1 = "xilinx@aup1"; aup2 = "xilinx@aup2" }
$script:Procs = @{}
$Mime = @{ ".html"="text/html; charset=utf-8"; ".js"="application/javascript; charset=utf-8"; ".css"="text/css; charset=utf-8";
           ".png"="image/png"; ".json"="application/json; charset=utf-8"; ".svg"="image/svg+xml" }

function Send($ctx, [int]$code, [byte[]]$bytes, [string]$type) {
  $r = $ctx.Response; $r.StatusCode = $code; $r.ContentType = $type
  $r.Headers.Add("Cache-Control", "no-store")
  $r.ContentLength64 = $bytes.Length; $r.OutputStream.Write($bytes, 0, $bytes.Length); $r.OutputStream.Close()
}
function SendText($ctx, [int]$code, [string]$text, [string]$type = "application/json; charset=utf-8") {
  Send $ctx $code ([Text.Encoding]::UTF8.GetBytes($text)) $type
}
function SafePath([string]$base, [string]$rel) {
  $rel = [Uri]::UnescapeDataString($rel).TrimStart('/') -replace '/', '\'
  $b = [IO.Path]::GetFullPath($base).TrimEnd('\') + '\'
  $full = [IO.Path]::GetFullPath((Join-Path $base $rel))
  if (-not $full.StartsWith($b, [StringComparison]::OrdinalIgnoreCase)) { return $null }
  return $full
}
function ReadTail([string]$path, [long]$max) {
  $fs = [IO.File]::Open($path, 'Open', 'Read', 'ReadWrite')
  try {
    $len = $fs.Length; $start = [Math]::Max(0, $len - $max); [void]$fs.Seek($start, 'Begin')
    $buf = New-Object byte[] ([int]($len - $start)); $n = 0
    while ($n -lt $buf.Length) { $k = $fs.Read($buf, $n, $buf.Length - $n); if ($k -le 0) { break }; $n += $k }
    return [Text.Encoding]::UTF8.GetString($buf, 0, $n)
  } finally { $fs.Close() }
}
function NodeTime([string]$name) { return [datetime]::ParseExact($name.Substring(5), 'yyyyMMdd_HHmmss', $null) }
function RunEpoch([string]$name) { if ($name.Length -lt 15) { return $null }; try { return [datetime]::ParseExact($name.Substring(0, 15), 'yyyyMMdd_HHmmss', $null) } catch { return $null } }
function FileEpoch([string]$path) { return ([DateTimeOffset]((Get-Item $path).LastWriteTimeUtc)).ToUnixTimeMilliseconds() / 1000.0 }

function RunsJson {
  $list = @()
  $mr = Join-Path $Res "mission_runs"; if (-not (Test-Path $mr)) { $mr = Join-Path $Res "mission_runs_v7_sweep" }
  if (Test-Path $mr) {
    foreach ($d in (Get-ChildItem $mr -Directory | Sort-Object Name)) {
      $fsw = Join-Path $d.FullName "fsw.log"
      $crash = $false
      if (Test-Path $fsw) { $crash = [bool](Select-String -Path $fsw -Pattern 'Assert:' -SimpleMatch -Quiet) }
      $list += [pscustomobject]@{ name = $d.Name; crashed = $crash; files = @(Get-ChildItem $d.FullName -File | ForEach-Object { $_.Name }) }
    }
  }
  $nodes = @()
  $n1 = Join-Path $Res "board_logs\aup1\wepwawet-core\logs"; $n2 = Join-Path $Res "board_logs\aup2\wepwawet-core\logs"
  if ((Test-Path $n1) -and (Test-Path $n2)) {
    $cand2 = @(Get-ChildItem $n2 -Directory -Filter "node_*")
    foreach ($a in (Get-ChildItem $n1 -Directory -Filter "node_*" | Sort-Object Name)) {
      if (-not (Test-Path (Join-Path $a.FullName "fsw.log"))) { continue }
      $ta = NodeTime $a.Name; $best = $null; $bd = 1e9
      foreach ($c in $cand2) { $dd = [Math]::Abs(((NodeTime $c.Name) - $ta).TotalSeconds); if ($dd -lt $bd) { $bd = $dd; $best = $c } }
      if ($best -and $bd -le 120 -and (Test-Path (Join-Path $best.FullName "fsw.log"))) {
        $nodes += [pscustomobject]@{ aup1 = $a.Name; aup2 = $best.Name }
      }
    }
  }
  $aup2hw = Test-Path (Join-Path $n2 "fprime_hw_stats.csv")
  # duplex pairs: the same mission run recorded on both boards (names within 5 s, same suffix)
  $dup = @()
  $m1 = Join-Path $n1 "mission_runs"; $m2 = Join-Path $n2 "mission_runs"
  if ((Test-Path $m1) -and (Test-Path $m2)) {
    $c2 = @(Get-ChildItem $m2 -Directory)
    foreach ($a in (Get-ChildItem $m1 -Directory | Sort-Object Name)) {
      $ta = RunEpoch $a.Name; if (-not $ta) { continue }
      foreach ($c in $c2) {
        $tb = RunEpoch $c.Name; if (-not $tb) { continue }
        if ($a.Name.Substring(15) -eq $c.Name.Substring(15) -and [Math]::Abs(($ta - $tb).TotalSeconds) -le 5) {
          $crash = $false
          foreach ($f in @((Join-Path $a.FullName "fsw.log"), (Join-Path $c.FullName "fsw.log"))) {
            if ((Test-Path $f) -and (Select-String -Path $f -Pattern 'Assert:' -SimpleMatch -Quiet)) { $crash = $true }
          }
          $dup += [pscustomobject]@{ aup1 = $a.Name; aup2 = $c.Name; crashed = $crash }
          break
        }
      }
    }
  }
  # runs excluded for a documented reason (07_DASHBOARD\excluded_runs.json)
  $excl = @(); $ef = Join-Path $Here "excluded_runs.json"
  if (Test-Path $ef) { try { $excl = (Get-Content $ef -Raw -Encoding UTF8 | ConvertFrom-Json) } catch { $excl = @() } }
  # certificate-check evidence: saved console output of wcore_cert_check (cert_check*.log); public data only
  $checks = [ordered]@{}
  foreach ($b in @("aup1", "aup2")) {
    $files = @()
    $pats = @((Join-Path $Res ("ground_ca\evidence\cert_check*" + $b + "*.log")),
              (Join-Path $Res ("board_logs\" + $b + "\wepwawet-core\logs\cert_check*.log")),
              (Join-Path $Res ("board_logs\" + $b + "\aup_kit_v8_duplex\cert_check*.log")))
    foreach ($pt in $pats) { $files += @(Get-ChildItem -Path $pt -File -ErrorAction SilentlyContinue) }
    $lst = @()
    foreach ($f in ($files | Sort-Object FullName)) {
      $lst += [pscustomobject]@{ file = ($f.FullName.Substring($Res.Length + 1) -replace '\\', '/'); mtime = (FileEpoch $f.FullName); text = (ReadTail $f.FullName 4000) }
    }
    $checks[$b] = $lst
  }
  $issued = @(Get-ChildItem -Path $(if (Test-Path (Join-Path $Res "ground_ca")) { Join-Path $Res "ground_ca\*.cert" } else { Join-Path $Res "certificates\*.cert" }) -File -ErrorAction SilentlyContinue | ForEach-Object { [pscustomobject]@{ file = $_.Name; mtime = (FileEpoch $_.FullName) } })
  # hashes of the exported PUBLIC keys (05_RESULTS\aupN_node_pk_v8.bin); the files themselves are never served
  $pk = [ordered]@{}
  foreach ($b in @("aup1", "aup2")) {
    $f = Join-Path $Res ($b + "_node_pk_v8.bin"); if (-not (Test-Path $f)) { $f = Join-Path $Res ("certificates\" + $b + "_node_pk_v8.bin") }
    if (Test-Path $f -PathType Leaf) {
      $pk[$b] = [pscustomobject]@{ file = (Split-Path $f -Leaf); sha256 = (Get-FileHash $f -Algorithm SHA256).Hash.ToLower(); mtime = (FileEpoch $f); bytes = (Get-Item $f).Length }
    }
  }
  $cert = [pscustomobject]@{ checks = $checks; issued = $issued }
  return ([pscustomobject]@{ mission = $list; node = $nodes; aup2_hw = $aup2hw; duplex = $dup; excluded = $excl; cert = $cert; pk = $pk } | ConvertTo-Json -Depth 6 -Compress)
}

function StartLive {
  $probe = [IO.File]::ReadAllText((Join-Path $Here "board_probe.sh")) -replace "`r`n", "`n"
  $b64 = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($probe))
  foreach ($k in $Boards.Keys) {
    $p = $script:Procs[$k]
    if ($p -and -not $p.HasExited) { continue }
    $out = Join-Path $LiveDir "$k.jsonl"; $err = Join-Path $LiveDir "$k.err"
    $argv = @("-T", "-o", "BatchMode=yes", "-o", "ConnectTimeout=8", "-o", "ServerAliveInterval=5", $Boards[$k], "echo $b64 | base64 -d | bash")
    $script:Procs[$k] = Start-Process -FilePath "ssh.exe" -ArgumentList $argv -RedirectStandardOutput $out -RedirectStandardError $err -NoNewWindow -PassThru
    Write-Host "[live] ssh probe started for $k (pid $($script:Procs[$k].Id))" -ForegroundColor DarkCyan
  }
}
function StopLive {
  foreach ($k in @($script:Procs.Keys)) {
    $p = $script:Procs[$k]
    if ($p -and -not $p.HasExited) { try { Stop-Process -Id $p.Id -Force } catch {} ; Write-Host "[live] stopped $k" -ForegroundColor DarkCyan }
  }
  $script:Procs = @{}
}
function LiveJson {
  StartLive
  $parts = @()
  foreach ($k in $Boards.Keys) {
    $out = Join-Path $LiveDir "$k.jsonl"; $err = Join-Path $LiveDir "$k.err"
    $lines = @(); $errText = ""
    if (Test-Path $out) {
      $txt = ReadTail $out 65536
      $lines = @($txt -split "`n" | ForEach-Object { $_.Trim() } | Where-Object { $_.StartsWith("{") -and $_.EndsWith("}") } | Select-Object -Last 15)
    }
    if (Test-Path $err) { $errText = (ReadTail $err 600).Trim() }
    $p = $script:Procs[$k]; $alive = [bool]($p -and -not $p.HasExited)
    $obj = [pscustomobject]@{ alive = $alive; lines = $lines; err = $errText; now = [DateTimeOffset]::UtcNow.ToUnixTimeMilliseconds() / 1000.0 }
    $parts += ('"' + $k + '":' + ($obj | ConvertTo-Json -Depth 4 -Compress))
  }
  return "{" + ($parts -join ",") + "}"
}

function Handle($ctx) {
  $path = $ctx.Request.Url.AbsolutePath
  if ($path -eq "/") { $path = "/index.html" }
  switch -Regex ($path) {
    '^/api/runs$'      { SendText $ctx 200 (RunsJson); return }
    '^/api/live$'      { SendText $ctx 200 (LiveJson); return }
    '^/api/live/stop$' { StopLive; SendText $ctx 200 '{"stopped":true}'; return }
    '^/data/(.+)$' {
      $rel = $Matches[1]
      if ($rel -match '(?i)identity|node_sk|ground_sk|\.bin$|\.bit$|\.tgz$') { SendText $ctx 403 '{"error":"blocked"}'; return }
      $f = SafePath $Res $rel
      if (-not $f -or -not (Test-Path $f -PathType Leaf)) { SendText $ctx 404 '{"error":"not found"}'; return }
      $fs = [IO.File]::Open($f, 'Open', 'Read', 'ReadWrite'); try { $ms = New-Object IO.MemoryStream; $fs.CopyTo($ms); $b = $ms.ToArray() } finally { $fs.Close() }
      Send $ctx 200 $b "text/plain; charset=utf-8"; return
    }
    default {
      $f = SafePath $Here $path
      if (-not $f -or -not (Test-Path $f -PathType Leaf) -or $f -match '\.ps1$|\.sh$') { SendText $ctx 404 "not found" "text/plain"; return }
      $ext = [IO.Path]::GetExtension($f).ToLower(); $type = $Mime[$ext]; if (-not $type) { $type = "application/octet-stream" }
      Send $ctx 200 ([IO.File]::ReadAllBytes($f)) $type; return
    }
  }
}

$listener = New-Object Net.HttpListener
$listener.Prefixes.Add("http://localhost:$Port/")
$listener.Start()
Write-Host "WEPWAWET-CORE dashboard: http://localhost:$Port/   (results: $Res)   Ctrl+C to stop" -ForegroundColor Yellow
if (-not $NoBrowser) { Start-Process "http://localhost:$Port/" }
try {
  while ($listener.IsListening) {
    $task = $listener.GetContextAsync()
    while (-not $task.AsyncWaitHandle.WaitOne(250)) { }
    $ctx = $task.GetAwaiter().GetResult()
    try { Handle $ctx }
    catch {
      $m = ($_.Exception.Message -replace '["\\]', "'")
      Write-Host "[err] $($ctx.Request.Url.AbsolutePath): $m" -ForegroundColor Red
      try { SendText $ctx 500 ('{"error":"' + $m + '"}') } catch { }
    }
  }
} finally {
  StopLive
  $listener.Stop()
  Write-Host "dashboard stopped" -ForegroundColor Yellow
}
