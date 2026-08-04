#Requires -Version 5.1
# ============================================================
#  Turns the VPN off and on without uninstalling it.
#
#  Called by vpn-stop.cmd and vpn-start.cmd. Users double-click those.
#
#  Stopping has to Disable the task, not just Stop it. The task is registered
#  with -RestartCount 3 -RestartInterval 1m, so killing sing-box on its own
#  reads as a failed action and Task Scheduler brings it back within a minute.
#  Stop alone also leaves the boot trigger armed, so it would return on reboot.
# ============================================================
param(
    [ValidateSet('Start', 'Stop')]
    [string] $Action = 'Stop'
)

$ErrorActionPreference = 'Stop'
$TaskName = 'singbox-vpn'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell -Verb RunAs -ArgumentList `
        "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`" -Action $Action"
    exit
}

function Write-Ok   { param($m) Write-Host "    [OK] $m" -ForegroundColor Green }
function Write-Warn { param($m) Write-Host "    [!]  $m" -ForegroundColor Yellow }
function Write-Fail { param($m) Write-Host "    [X]  $m" -ForegroundColor Red }

# The TUN adapter carries 172.19.0.1/30, so its address is the honest signal that
# routing is actually up or down - more so than whether the process exists.
function Get-TunUp {
    [bool](Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue |
           Where-Object { $_.IPAddress -like '172.19.0.*' })
}

function Wait-Tun {
    param([bool]$Up, [int]$Seconds = 20)
    for ($i = 0; $i -lt ($Seconds * 2); $i++) {
        if ((Get-TunUp) -eq $Up) { return $true }
        Start-Sleep -Milliseconds 500
    }
    return ((Get-TunUp) -eq $Up)
}

Write-Host ''
Write-Host '  ===============================================' -ForegroundColor Magenta
Write-Host "   sing-box VPN - $($Action.ToUpper())" -ForegroundColor Magenta
Write-Host '  ===============================================' -ForegroundColor Magenta
Write-Host ''

$task = Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
if (-not $task) {
    Write-Fail "Scheduled task '$TaskName' not found - the VPN is not installed."
    Write-Host '      Run the installer line from the README first.' -ForegroundColor DarkGray
    Start-Sleep -Seconds 6
    exit 1
}

if ($Action -eq 'Stop') {
    Disable-ScheduledTask -TaskName $TaskName | Out-Null
    Write-Ok 'Autostart disabled (stays off across reboots)'

    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Get-Process 'sing-box' -ErrorAction SilentlyContinue | Stop-Process -Force -ErrorAction SilentlyContinue

    if (Wait-Tun -Up $false) {
        ipconfig /flushdns | Out-Null
        Write-Ok 'VPN is OFF - all traffic is going direct again'
    } else {
        Write-Fail 'TUN adapter is still up. Reboot to restore routing.'
        Start-Sleep -Seconds 8
        exit 1
    }
} else {
    Enable-ScheduledTask -TaskName $TaskName | Out-Null
    Start-ScheduledTask -TaskName $TaskName

    if (Wait-Tun -Up $true -Seconds 25) {
        Write-Ok 'VPN is ON - autostart re-enabled'
    } elseif (Get-Process 'sing-box' -ErrorAction SilentlyContinue) {
        Write-Warn 'sing-box is running but TUN did not come up'
        Write-Host '      Another VPN adapter may be active.' -ForegroundColor DarkGray
    } else {
        Write-Fail 'sing-box did not start - re-run the installer to rebuild the config'
        Start-Sleep -Seconds 8
        exit 1
    }
}

Write-Host ''
Start-Sleep -Seconds 4
