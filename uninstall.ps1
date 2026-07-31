#Requires -Version 5.1
# Full removal: stops the task, unregisters autostart, deletes the folder.
$ErrorActionPreference = 'SilentlyContinue'

if (-not ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
    Start-Process powershell -Verb RunAs -ArgumentList `
        "-NoProfile -ExecutionPolicy Bypass -File `"$PSCommandPath`""
    exit
}

$TaskName   = 'singbox-vpn'
$InstallDir = Join-Path ([Environment]::GetFolderPath('Desktop')) 'vpn'

Write-Host '[*] Stopping...' -ForegroundColor Cyan
Stop-ScheduledTask -TaskName $TaskName
Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
Get-Process 'sing-box' | Stop-Process -Force
Start-Sleep -Seconds 2

# The TUN adapter and routes go away with the process; flush DNS cache to be safe.
ipconfig /flushdns | Out-Null

Write-Host '[*] Removing files...' -ForegroundColor Cyan
Remove-Item $InstallDir -Recurse -Force

Write-Host '[OK] Removed.' -ForegroundColor Green
Start-Sleep -Seconds 2
