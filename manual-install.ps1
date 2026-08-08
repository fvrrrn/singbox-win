#Requires -Version 5.1
# Run this from the vpn folder. It will request elevation if needed.

$ErrorActionPreference = 'Stop'
$TaskName   = 'singbox-vpn'

function Write-Step { param($m) Write-Host "`n[*] $m" -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "    [OK] $m" -ForegroundColor Green }
function Write-Fail { param($m) Write-Host "    [X]  $m" -ForegroundColor Red }

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# Self-elevate, keeping the install folder location
if (-not (Test-Admin)) {
    $self = $MyInvocation.MyCommand.Path
    Start-Process powershell -Verb RunAs `
        -ArgumentList "-NoProfile -ExecutionPolicy Bypass -File `"$self`""
    exit
}

try {
    $InstallDir = $PSScriptRoot

    # ---- Subscription URL ---------------------------------------------------
    $SubFile = Join-Path $InstallDir 'subscription.txt'
    if (Test-Path $SubFile) {
        $SubUrl = (Get-Content $SubFile -Raw).Trim()
        Write-Ok "Using saved subscription: $SubUrl"
    } else {
        do { $SubUrl = (Read-Host 'Subscription URL').Trim() }
        until ($SubUrl -match '^https?://')
    }

    # ---- Generate config.json -----------------------------------------------
    Write-Step 'Building configuration...'
    $maker = Join-Path $InstallDir 'make-config.ps1'
    $json  = & $maker -SubUrl $SubUrl -InstallDir $InstallDir
    $noBom = New-Object Text.UTF8Encoding $false
    [IO.File]::WriteAllText((Join-Path $InstallDir 'config.json'), $json, $noBom)
    [IO.File]::WriteAllText($SubFile, $SubUrl, $noBom)
    Write-Ok 'config.json written'

    # ---- Validate -----------------------------------------------------------
    Write-Step 'Validating configuration...'
    $Exe      = Join-Path $InstallDir 'sing-box.exe'
    $cfgPath  = Join-Path $InstallDir 'config.json'
    $checkOut = & $Exe check -c $cfgPath 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Fail 'Configuration is invalid:'
        $checkOut | ForEach-Object { Write-Host "      $_" -ForegroundColor Red }
        Read-Host "`nPress Enter to exit"
        exit 1
    }
    Write-Ok 'Configuration is valid'

    # ---- Register scheduled task --------------------------------------------
    Write-Step 'Registering autostart...'
    if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
        Stop-ScheduledTask       -TaskName $TaskName -ErrorAction SilentlyContinue
        Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
    }
    Get-Process 'sing-box' -ErrorAction SilentlyContinue | Stop-Process -Force
    Start-Sleep -Seconds 2

    $action    = New-ScheduledTaskAction -Execute $Exe `
                    -Argument "run -c `"$cfgPath`" -D `"$InstallDir`"" -WorkingDirectory $InstallDir
    $trigger   = New-ScheduledTaskTrigger -AtStartup
    $principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
    $settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
                    -DontStopIfGoingOnBatteries -RestartCount 3 `
                    -RestartInterval (New-TimeSpan -Minutes 1) `
                    -ExecutionTimeLimit ([TimeSpan]::Zero)
    Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
        -Principal $principal -Settings $settings | Out-Null
    Write-Ok "Task '$TaskName' registered"

    # ---- Start --------------------------------------------------------------
    Start-ScheduledTask -TaskName $TaskName
    Start-Sleep -Seconds 4
    if (Get-Process 'sing-box' -ErrorAction SilentlyContinue) {
        Write-Ok 'sing-box is running'
    } else {
        Write-Host '    [!]  Process not found - check log in the vpn folder' -ForegroundColor Yellow
    }

    Write-Host ''
    Write-Host '  Done.' -ForegroundColor Green

} catch {
    Write-Host ''
    Write-Fail "Fatal error: $_"
}

Write-Host ''
Read-Host 'Press Enter to close'
