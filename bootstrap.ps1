#Requires -Version 5.1
# ============================================================
#  sing-box VPN - one-line installer
#
#  Usage (Win+R):
#    powershell -c "$SubUrl='https://host/sub/TOKEN'; irm https://gist.githubusercontent.com/USER/ID/raw/SHA/bootstrap.ps1 | iex"
#
#  Re-running without $SubUrl refreshes the config from the saved subscription.
# ============================================================

$ErrorActionPreference = 'Stop'

# ---- Deployment settings -----------------------------------
$RepoOwner  = 'fvrrrn'
$RepoName   = 'singbox-win'
$RepoTag    = 'v1'                    # PINNED. Never 'latest'.
$InstallDir = Join-Path ([Environment]::GetFolderPath('Desktop')) 'vpn'
$TaskName   = 'singbox-vpn'

# ---- sing-box binaries -------------------------------------
# Not committed to this repo. They are fetched from SagerNet's own release and
# checked against the hash below, so the bytes are pinned as tightly as a commit
# would pin them - without carrying 55 MB in git history on every release.
# To bump: change $SbVersion, download the asset, and paste its real SHA256 here.
$SbVersion = '1.13.15'
$SbAsset   = "sing-box-$SbVersion-windows-amd64.zip"
$SbSha256  = '599B296F6E57511D36D2A6F3011AED1A86FA98418578BBB06BD6DC241B5D8877'

# ---- Output ------------------------------------------------
function Write-Step { param($m) Write-Host "`n[*] $m" -ForegroundColor Cyan }
function Write-Ok   { param($m) Write-Host "    [OK] $m" -ForegroundColor Green }
function Write-Warn { param($m) Write-Host "    [!]  $m" -ForegroundColor Yellow }
function Write-Fail { param($m) Write-Host "    [X]  $m" -ForegroundColor Red }

function Test-Admin {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()
    ).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---- Step 0: elevate (TUN requires administrator) ----------
if (-not (Test-Admin)) {
    Write-Host 'Administrator rights required. Requesting elevation...' -ForegroundColor Yellow
    $tmp = Join-Path $env:TEMP 'singbox-bootstrap.ps1'
    $prefix = if ($SubUrl) { "`$SubUrl = @'`n$SubUrl`n'@`n" } else { '' }
    $body = if ($PSCommandPath -and (Test-Path $PSCommandPath)) {
        Get-Content $PSCommandPath -Raw
    } else {
        $MyInvocation.MyCommand.ScriptBlock.ToString()
    }
    ($prefix + $body) | Out-File $tmp -Encoding UTF8 -Force
    Start-Process powershell -Verb RunAs -ArgumentList `
        "-NoProfile -ExecutionPolicy Bypass -File `"$tmp`""
    exit
}

# TLS: certificate validation is NOT disabled.
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
try { [Net.ServicePointManager]::SecurityProtocol = `
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls13 } catch {}

Clear-Host
Write-Host ''
Write-Host '  ===============================================' -ForegroundColor Magenta
Write-Host '        sing-box VPN - installer' -ForegroundColor Magenta
Write-Host '  ===============================================' -ForegroundColor Magenta

# ---- Step 1: subscription ----------------------------------
$SubFile = Join-Path $InstallDir 'subscription.txt'

if (-not $SubUrl) {
    if (Test-Path $SubFile) {
        $SubUrl = (Get-Content $SubFile -Raw).Trim()
        Write-Ok 'Using saved subscription URL'
    } else {
        while ($SubUrl -notmatch '^https?://') {
            $SubUrl = (Read-Host '  Subscription URL').Trim()
        }
    }
}

# ---- Step 2: download the bundle ---------------------------
Write-Step "Downloading bundle ($RepoTag)..."
New-Item -ItemType Directory -Path $InstallDir -Force | Out-Null
$zip     = Join-Path $env:TEMP "$RepoName-$RepoTag.zip"
$zipUrl  = "https://github.com/$RepoOwner/$RepoName/archive/refs/tags/$RepoTag.zip"
$staging = Join-Path $env:TEMP "$RepoName-staging"

$ProgressPreference = 'SilentlyContinue'
Invoke-WebRequest $zipUrl -OutFile $zip -UseBasicParsing
$ProgressPreference = 'Continue'

if (Test-Path $staging) { Remove-Item $staging -Recurse -Force }
Expand-Archive $zip -DestinationPath $staging -Force
$inner = Get-ChildItem $staging -Directory | Select-Object -First 1

# Stop the task before overwriting the binary
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Stop-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
}
Get-Process 'sing-box' -ErrorAction SilentlyContinue | Stop-Process -Force
Start-Sleep -Seconds 1

Copy-Item (Join-Path $inner.FullName '*') $InstallDir -Recurse -Force
Remove-Item $zip, $staging -Recurse -Force
Write-Ok "Extracted to $InstallDir"

# ---- Step 3: sing-box binaries -----------------------------
# Upstream first, this repo's release as a mirror if upstream is unreachable.
# The mirror is the same bytes re-uploaded, and it faces the same hash check:
# a mirror that cannot match the pinned hash is not trusted either.
$Exe   = Join-Path $InstallDir 'sing-box.exe'
$Dll   = Join-Path $InstallDir 'libcronet.dll'
$Stamp = Join-Path $InstallDir 'sing-box.sha256'

$havePinned = (Test-Path $Exe) -and (Test-Path $Dll) -and (Test-Path $Stamp) -and
              ((Get-Content $Stamp -Raw).Trim() -eq $SbSha256)

if ($havePinned) {
    Write-Step "sing-box $SbVersion..."
    Write-Ok 'Already present and pinned - skipping download'
} else {
    Write-Step "Fetching sing-box $SbVersion..."
    $sbZip = Join-Path $env:TEMP $SbAsset
    $verified = $false
    foreach ($u in @(
        "https://github.com/SagerNet/sing-box/releases/download/v$SbVersion/$SbAsset"
        "https://github.com/$RepoOwner/$RepoName/releases/download/$RepoTag/$SbAsset"
    )) {
        try {
            Write-Host "      $u" -ForegroundColor DarkGray
            $ProgressPreference = 'SilentlyContinue'
            Invoke-WebRequest $u -OutFile $sbZip -UseBasicParsing
            $ProgressPreference = 'Continue'
        } catch {
            Write-Warn "unreachable: $($_.Exception.Message)"
            continue
        }
        $got = (Get-FileHash $sbZip -Algorithm SHA256).Hash
        if ($got -ne $SbSha256) {
            Write-Fail "SHA256 mismatch - rejected"
            Write-Host "      expected $SbSha256" -ForegroundColor Red
            Write-Host "      got      $got"      -ForegroundColor Red
            Remove-Item $sbZip -Force -ErrorAction SilentlyContinue
            continue
        }
        $verified = $true
        break
    }
    if (-not $verified) {
        throw "No verified copy of $SbAsset could be obtained from upstream or the mirror"
    }
    Write-Ok 'SHA256 verified'

    $sbStage = Join-Path $env:TEMP "singbox-bin-$SbVersion"
    if (Test-Path $sbStage) { Remove-Item $sbStage -Recurse -Force }
    Expand-Archive $sbZip -DestinationPath $sbStage -Force
    Get-ChildItem $sbStage -Recurse -Include 'sing-box.exe', 'libcronet.dll' |
        ForEach-Object { Copy-Item $_.FullName $InstallDir -Force }
    Remove-Item $sbZip, $sbStage -Recurse -Force

    if (-not ((Test-Path $Exe) -and (Test-Path $Dll))) {
        throw "$SbAsset did not contain sing-box.exe and libcronet.dll"
    }
    [IO.File]::WriteAllText($Stamp, $SbSha256, (New-Object Text.UTF8Encoding $false))
    Write-Ok "sing-box $SbVersion installed"
}

# ---- Step 4: generate config.json --------------------------
# Fetching, parsing and rendering all live in make-config.ps1, which ships in this
# same tagged bundle. It writes nothing: it emits the config JSON on stdout.
Write-Step 'Building configuration...'
$maker = Join-Path $InstallDir 'make-config.ps1'
if (-not (Test-Path $maker)) {
    throw "make-config.ps1 missing from bundle - `$RepoTag '$RepoTag' predates it, bump the tag"
}
$json = & $maker -SubUrl $SubUrl -InstallDir $InstallDir

# PS 5.1 '-Encoding UTF8' writes a BOM, which sing-box's JSON decoder rejects.
$noBom   = New-Object Text.UTF8Encoding $false
$cfgPath = Join-Path $InstallDir 'config.json'
[IO.File]::WriteAllText($cfgPath, $json, $noBom)
[IO.File]::WriteAllText($SubFile, $SubUrl, $noBom)
Write-Ok 'config.json written'

# make-config.ps1 drops the hysteria2 outbound when the panel gives it no password.
$cfg    = $json | ConvertFrom-Json
$useHy2 = [bool]($cfg.outbounds | Where-Object { $_.tag -eq 'hy2' })
$vo     = $cfg.outbounds | Where-Object { $_.tag -eq 'vless-out' }
Write-Ok "VLESS: $($vo.server):$($vo.server_port)  sni=$($vo.tls.server_name)"
if ($useHy2) {
    $ho = $cfg.outbounds | Where-Object { $_.tag -eq 'hy2' }
    Write-Ok "Hysteria2: $($ho.server):$($ho.server_port)"
} else {
    Write-Warn 'Hysteria2 unavailable - VLESS only (see the warning above)'
}

# ---- Step 5: validate before starting ----------------------
Write-Step 'Validating configuration...'
$checkOut = & $Exe check -c $cfgPath 2>&1
if ($LASTEXITCODE -ne 0) {
    Write-Fail 'Configuration is invalid:'
    $checkOut | ForEach-Object { Write-Host "      $_" -ForegroundColor Red }
    Read-Host 'Press Enter'
    exit 1
}
Write-Ok 'Configuration is valid'

# ---- Step 6: autostart via Task Scheduler ------------------
Write-Step 'Registering autostart...'
if (Get-ScheduledTask -TaskName $TaskName -ErrorAction SilentlyContinue) {
    Unregister-ScheduledTask -TaskName $TaskName -Confirm:$false
}
$action    = New-ScheduledTaskAction -Execute $Exe `
                -Argument "run -c `"$cfgPath`" -D `"$InstallDir`"" -WorkingDirectory $InstallDir
$trigger   = New-ScheduledTaskTrigger -AtStartup
$principal = New-ScheduledTaskPrincipal -UserId 'SYSTEM' -LogonType ServiceAccount -RunLevel Highest
$settings  = New-ScheduledTaskSettingsSet -AllowStartIfOnBatteries `
                -DontStopIfGoingOnBatteries -RestartCount 3 -RestartInterval (New-TimeSpan -Minutes 1) `
                -ExecutionTimeLimit ([TimeSpan]::Zero)
Register-ScheduledTask -TaskName $TaskName -Action $action -Trigger $trigger `
    -Principal $principal -Settings $settings | Out-Null
Write-Ok "Task '$TaskName' registered (starts at boot)"

Start-ScheduledTask -TaskName $TaskName
Start-Sleep -Seconds 4
if (Get-Process 'sing-box' -ErrorAction SilentlyContinue) {
    Write-Ok 'sing-box is running'
} else {
    Write-Warn 'Process not found - check log output in the install folder'
}

Write-Host ''
Write-Host '  ===============================================' -ForegroundColor Green
Write-Host "   Done. Folder: $InstallDir" -ForegroundColor Green
if (-not $useHy2) {
    Write-Host '   NOTE: VLESS only (no hysteria2 password)' -ForegroundColor Yellow
}
Write-Host '  ===============================================' -ForegroundColor Green
Write-Host ''
Start-Sleep -Seconds 3
