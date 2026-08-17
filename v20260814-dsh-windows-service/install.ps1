<#
.SYNOPSIS
    Install dsh web (DeepSeek Harness browser UI) as a REAL Windows service
    so it starts automatically at boot and can be managed manually
    (services.msc / net stop|start / Restart-Service).

.DESCRIPTION
    Mechanism: NSSM wraps node.exe running dsh's bin.js as a service named
    'dsh-web' under the LocalSystem account, with the user environment
    (USERPROFILE / HOME / DSH_HOME / PATH) injected explicitly so dsh finds
    your config and credentials. NSSM gives auto-restart on crash + log
    rotation. Requires elevation (the script self-elevates via UAC).

    Install order (as requested):
      1. stop anything currently listening on the port (kills the old
         instance, including a manual `dsh web` you may have running)
      2. cleanup: unregister the old at-logon scheduled task (previous
         approach), remove any existing 'dsh-web' service (idempotent)
      3. ensure global @deepseek-ai/dsh + NSSM
      4. install + configure the service (auto start at boot)
      5. start the service
      6. verify http://127.0.0.1:<port> answers

    Commands:  install | start | stop | restart | status | uninstall

.PARAMETER Command
    install (default) | start | stop | restart | status | uninstall

.PARAMETER Port
    Listen port (default 3080).

.PARAMETER HostAddr
    Bind host (default 127.0.0.1).

.PARAMETER NssmPath
    Path to an existing nssm.exe (skips download). Useful when offline.

.EXAMPLE
    .\install.ps1            # stop 3080 -> install service -> start -> verify
    .\install.ps1 status     # service state + port listener
    .\install.ps1 restart    # manual restart (same as: net stop dsh-web && net start dsh-web)
    .\install.ps1 uninstall
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateSet('install', 'start', 'stop', 'restart', 'status', 'uninstall')]
    [string]$Command = 'install',

    [int]$Port = 3080,
    [string]$HostAddr = '127.0.0.1',
    [string]$NssmPath = ''
)

$ErrorActionPreference = 'Stop'
$svcName = 'dsh-web'
$svcDir  = Join-Path $env:LOCALAPPDATA 'dsh-service'
$logFile = Join-Path $svcDir 'install.log'

# ---- self-elevate via UAC -------------------------------------------------
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent())
    .IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', ('"{0}"' -f $PSCommandPath), $Command)
    if ($PSBoundParameters.ContainsKey('Port'))     { $argList += @('-Port', "$Port") }
    if ($PSBoundParameters.ContainsKey('HostAddr')) { $argList += @('-HostAddr', $HostAddr) }
    if ($PSBoundParameters.ContainsKey('NssmPath')) { $argList += @('-NssmPath', $NssmPath) }
    Write-Host '需要管理员权限，正在弹出 UAC 确认窗口...'
    Start-Process -FilePath "$env:WINDIR\System32\WindowsPowerShell\v1.0\powershell.exe" `
        -ArgumentList $argList -Verb RunAs -Wait
    exit $LASTEXITCODE
}

# ---- helpers ---------------------------------------------------------------
function Write-Log {
    param([string]$Message)
    $line = "{0}  {1}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Message
    try { Add-Content -LiteralPath $logFile -Value $line -Encoding UTF8 -ErrorAction SilentlyContinue } catch { }
    Write-Host $line
}

function Get-PortOwner {
    param([int]$P)
    $c = Get-NetTCPConnection -LocalPort $P -State Listen -ErrorAction SilentlyContinue
    if ($c) { return $c[0].OwningProcess }
    return $null
}

function Get-Nssm {
    $binDir = Join-Path $svcDir 'bin'
    $cached = Join-Path $binDir 'nssm.exe'
    if (Test-Path -LiteralPath $cached) { return $cached }
    if ($NssmPath -and (Test-Path -LiteralPath $NssmPath)) { return (Resolve-Path $NssmPath).Path }

    New-Item -ItemType Directory -Force -Path $binDir | Out-Null
    $zip = Join-Path $binDir 'nssm-2.24.zip'
    Write-Log 'downloading NSSM 2.24 from nssm.cc ...'
    Invoke-WebRequest -Uri 'https://nssm.cc/release/nssm-2.24.zip' -OutFile $zip -UseBasicParsing -TimeoutSec 90
    if (-not (Test-Path -LiteralPath $zip)) {
        throw 'NSSM 下载失败。请手动下载 nssm-2.24 (https://nssm.cc/download) 并将 nssm.exe 用 -NssmPath 传入'
    }
    Expand-Archive -LiteralPath $zip -DestinationPath $binDir -Force
    $exe = Get-ChildItem -Path $binDir -Recurse -Filter 'nssm.exe' | Where-Object { $_.FullName -match 'win64' } | Select-Object -First 1
    if (-not $exe) { throw '压缩包中未找到 win64/nssm.exe' }
    Move-Item -LiteralPath $exe.FullName -Destination $cached -Force
    Remove-Item -LiteralPath $zip -Force -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath (Join-Path $binDir 'nssm-2.24') -Recurse -Force -ErrorAction SilentlyContinue
    return $cached
}

# ---- commands --------------------------------------------------------------
function Invoke-Install {
    Write-Log "=== dsh-web service install (${HostAddr}:$Port, service='$svcName') ==="

    # 1) stop whatever listens on the port (required by design)
    $owner = Get-PortOwner -P $Port
    if ($owner) {
        Write-Log "stopping existing listener on port $Port (pid $owner)..."
        Stop-Process -Id $owner -Force -ErrorAction SilentlyContinue
        Start-Sleep -Seconds 1
    } else {
        Write-Log "port $Port is free."
    }

    # 2) cleanup the old at-logon scheduled task (previous approach) and any old service
    Unregister-ScheduledTask -TaskName 'dsh-web-autostart' -Confirm:$false -ErrorAction SilentlyContinue
    if (Get-Service -Name $svcName -ErrorAction SilentlyContinue) {
        Write-Log "removing existing service '$svcName' (reinstall)..."
        sc.exe stop $svcName 2>$null | Out-Null
        sc.exe delete $svcName 2>$null | Out-Null
        Start-Sleep -Seconds 1
    }

    # 3) ensure global dsh CLI + resolve node/bin.js
    $nodeCmd = Get-Command node -ErrorAction Stop | Select-Object -First 1
    $nodePath = $nodeCmd.Source
    $nodeDir  = Split-Path $nodePath -Parent
    $npmBin   = Join-Path $nodeDir 'dsh.cmd'
    if (-not (Test-Path -LiteralPath $npmBin)) {
        Write-Log 'global dsh not found; running: npm install -g @deepseek-ai/dsh'
        & npm install -g @deepseek-ai/dsh
        if ($LASTEXITCODE -ne 0) { throw "npm install -g @deepseek-ai/dsh failed (exit $LASTEXITCODE)" }
    }
    $binJs = Join-Path ((& npm root -g).Trim()) '@deepseek-ai\dsh\lib\bin.js'
    if (-not (Test-Path -LiteralPath $binJs)) { throw "dsh bin.js not found: $binJs" }
    Write-Log "node : $nodePath"
    Write-Log "dsh  : $binJs"

    # 4) ensure NSSM
    $nssm = Get-Nssm
    Write-Log "nssm : $nssm"

    # 5) install + configure the service
    Write-Log 'installing service...'
    & $nssm install $svcName $nodePath "$binJs web --host $HostAddr --port $Port"
    if ($LASTEXITCODE -ne 0) { throw "nssm install failed (exit $LASTEXITCODE)" }

    $dshHome = Join-Path $env:USERPROFILE '.dsh'
    $logsDir = Join-Path $svcDir 'logs'
    New-Item -ItemType Directory -Force -Path $logsDir | Out-Null

    & $nssm set $svcName AppDirectory $svcDir | Out-Null
    & $nssm set $svcName AppEnvironmentExtra `
        "USERPROFILE=$env:USERPROFILE" `
        "HOME=$env:USERPROFILE" `
        "DSH_HOME=$dshHome" `
        "PATH=C:\Windows\System32;C:\Windows;$nodeDir" | Out-Null
    & $nssm set $svcName AppStdout (Join-Path $logsDir 'dsh-web.out.log') | Out-Null
    & $nssm set $svcName AppStderr (Join-Path $logsDir 'dsh-web.err.log') | Out-Null
    & $nssm set $svcName AppRotateFiles 1 | Out-Null
    & $nssm set $svcName AppRotateBytes 10485760 | Out-Null   # 10 MB per log
    & $nssm set $svcName AppRestartDelay 5000 | Out-Null      # 5s before restart after crash
    & $nssm set $svcName Description 'DeepSeek Harness web UI (dsh web) auto-start service' | Out-Null
    & $nssm set $svcName Start SERVICE_AUTO_START | Out-Null
    Write-Log 'service configured (auto start at boot, crash auto-restart, log rotation).'

    # 6) start + verify
    Write-Log 'starting service...'
    & $nssm start $svcName
    if ($LASTEXITCODE -ne 0) { throw "nssm start failed (exit $LASTEXITCODE); check $logsDir\dsh-web.err.log" }

    $ok = $false
    for ($i = 1; $i -le 30; $i++) {
        Start-Sleep -Seconds 1
        try {
            $r = Invoke-WebRequest -Uri "http://${HostAddr}:$Port" -UseBasicParsing -TimeoutSec 2
            if ($r.StatusCode -lt 400) { Write-Log "OK: HTTP $($r.StatusCode) after ${i}s -- dsh web is up"; $ok = $true; break }
        } catch { }
    }
    if (-not $ok) {
        Write-Log "WARNING: no HTTP response on ${HostAddr}:$Port within 30s; see $logsDir\dsh-web.err.log"
        exit 1
    }

    Write-Host ''
    Write-Host '安装完成 ✅  服务名: dsh-web  (开机自动启动)'
    Write-Host '  手动重启 : net stop dsh-web && net start dsh-web'
    Write-Host '            或 services.msc 中找到 "dsh-web" 右键重启'
    Write-Host '            或 Restart-Service dsh-web'
    Write-Host "  日志     : $logsDir"
}

function Invoke-Start {
    if (-not (Get-Service -Name $svcName -ErrorAction SilentlyContinue)) { throw "service '$svcName' not installed; run install first" }
    sc.exe start $svcName | Out-Null
    Write-Log 'service started.'
}

function Invoke-Stop {
    if (Get-Service -Name $svcName -ErrorAction SilentlyContinue) { sc.exe stop $svcName 2>$null | Out-Null }
    $owner = Get-PortOwner -P $Port
    if ($owner) { Stop-Process -Id $owner -Force -ErrorAction SilentlyContinue }
    Write-Log 'stopped.'
}

function Invoke-Restart {
    if (Get-Service -Name $svcName -ErrorAction SilentlyContinue) { sc.exe stop $svcName 2>$null | Out-Null }
    Start-Sleep -Seconds 1
    if (Get-Service -Name $svcName -ErrorAction SilentlyContinue) { sc.exe start $svcName | Out-Null }
    Write-Log 'restarted.'
}

function Invoke-Status {
    $svc = Get-Service -Name $svcName -ErrorAction SilentlyContinue
    if ($svc) { Write-Host ("service '{0}': {1}  (StartType={2})" -f $svcName, $svc.Status, $svc.StartType) }
    else      { Write-Host "service '$svcName': NOT installed" }
    $owner = Get-PortOwner -P $Port
    if ($owner) { Write-Host "port $Port : listening (pid $owner)" }
    else        { Write-Host "port $Port : free" }
    $logsDir = Join-Path $svcDir 'logs'
    if (Test-Path (Join-Path $logsDir 'dsh-web.out.log')) { Write-Host "logs: $logsDir" }
}

function Invoke-Uninstall {
    Write-Log 'uninstalling dsh-web service...'
    if (Get-Service -Name $svcName -ErrorAction SilentlyContinue) {
        sc.exe stop $svcName 2>$null | Out-Null
        sc.exe delete $svcName 2>$null | Out-Null
    }
    $owner = Get-PortOwner -P $Port
    if ($owner) { Stop-Process -Id $owner -Force -ErrorAction SilentlyContinue }
    Write-Log 'service removed. Files under %LOCALAPPDATA%\dsh-service kept (logs); delete manually if unwanted.'
}

# ---- dispatch --------------------------------------------------------------
switch ($Command) {
    'install'   { Invoke-Install; if ($Host.UI.RawUI) { Read-Host '按回车关闭窗口' } }
    'start'     { Invoke-Start }
    'stop'      { Invoke-Stop }
    'restart'   { Invoke-Restart }
    'status'    { Invoke-Status }
    'uninstall' { Invoke-Uninstall }
}
