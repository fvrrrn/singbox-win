#Requires -Version 5.1
#Requires -RunAsAdministrator
# Run this from the vpn folder as Administrator after manually copying all files there.
# It generates config.json, validates it, and registers the scheduled task.

$ErrorActionPreference = 'Stop'
$TaskName  = 'singbox-vpn'
$InstallDir = $PSScriptRoot

function Write-Step { param($m) Write-Host "`n[*] $m" -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "    [OK] $m" -ForegroundColor Green }
function Write-Fail { param($m) Write-Host "    [X]  $m" -ForegroundColor Red }

# ---- Subscription URL -------------------------------------------------------
$SubFile = Join-Path $InstallDir 'subscription.txt'
if (Test-Path $SubFile) {
    $SubUrl = (Get-Content $SubFile -Raw).Trim()
    Write-Ok "Using saved subscription: $SubUrl"
} else {
    do { $SubUrl = (Read-Host 'Subscription URL').Trim() }
    until ($SubUrl -match '^https?://')
}

# ---- Generate config.json ---------------------------------------------------
Write-Step 'Building configuration...'
$maker = Join-Path $InstallDir 'make-config.ps1'
$json  = & $maker -SubUrl $SubUrl -InstallDir $InstallDir
$noBom = New-Object Text.UTF8Encoding $false
[IO.File]::WriteAllText((Join-Path $InstallDir 'config.json'), $json, $noBom)
[IO.File]::WriteAllText($SubFile, $SubUrl, $noBom)
Write-Ok 'config.json written'

# ---- Validate ---------------------------------------------------------------
Write-Step 'Validating configuration...'
$Exe = Join-Path $InstallDir 'sing-box.exe'
$checkOut = & $Exe check -c (Join-Path $InstallDir 'config.json') 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Fail 'Configuration is invalid:'
    $checkOut | ForEach-Object { Write-Host "      $_" -ForegroundColor Red }
    Read-Host 'Press Enter to exit'
    exit 1
}
Write-Ok 'Configuration is valid'

# ---- Register scheduled task ------------------------------------------------
Write-Step 'Registering autostart...'
$cfgPath = Join-Path $InstallDir 'config.json'
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask  -TaskName $TaskName -ErrorAction SilentlyContinue
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}
Get-Process 'sing-box' -ErrorAction SilentlyContinue | Stop-Process -Force
$action    = New-ScheduledTaskAction -Execute $Exe `
                -Argument "run -c `"$cfgPath`" -D `"$InstallDir`"" -WorkingDirectory $InstallDir
$trigger   = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
                -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
                -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings | Out-Null
Write-Ok "Task '$TaskName' registered"

# ---- Start ------------------------------------------------------------------
Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 4
if (Get-Process 'sing-box' -ErrorAction SilentlyContinue) {
    Write-Ok 'sing-box is running'
} else {
    Write-Host '    [!]  Process not found - check log in the vpn folder' -ForegroundColor Yellow
}

Write-Host ''
Write-Host '  Done.' -ForegroundColor Green
Write-Host ''
Start-Sleep -Seconds 3
