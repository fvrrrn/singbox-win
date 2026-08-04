#Requires -Version 5.1
<#
.SYNOPSIS
  Validates that bootstrap.ps1's config generation produces a config sing-box accepts.

.DESCRIPTION
  Fetches one or more subscription URLs, parses them the same way bootstrap.ps1 does,
  renders config.template.json, and runs `sing-box.exe check` on the result.
  Touches nothing on the system: no TUN, no service, no install.

.EXAMPLE
  .\tools\test-config-gen.ps1 -SubUrl 'https://host/sub/TOKEN'

.EXAMPLE
  .\tools\test-config-gen.ps1 -SubUrl (Get-Content .\subs.txt)
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, ValueFromPipeline)]
    [string[]] $SubUrl,

    [string] $RepoRoot = (Split-Path $PSScriptRoot -Parent),

    # The installed binary. bootstrap.ps1 put it there after checking it against
    # $SbSha256, so it is the exact build users run - which is the one worth
    # validating against. The repo tracks no binaries and never will.
    [string] $Exe = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'vpn\sing-box.exe')
)

$ErrorActionPreference = 'Stop'
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

if (-not (Test-Path $Exe)) {
    throw "sing-box.exe not found at $Exe - run bootstrap.ps1 to install it, or pass -Exe <path>."
}

$Tpl = Join-Path $RepoRoot 'config.template.json'
if (-not (Test-Path $Tpl)) { throw "Not found: $Tpl" }

Write-Host ("sing-box : {0}" -f $Exe) -ForegroundColor DarkGray
Write-Host ("           {0}" -f ((& $Exe version 2>&1 | Select-Object -First 1))) -ForegroundColor DarkGray

function ConvertFrom-ProxyUri([string]$uri) {
    if ($uri -notmatch '^(?<scheme>[a-z0-9]+)://(?<userinfo>[^@]*)@(?<host>[^:/?#]+):(?<port>\d+)/?\?(?<query>[^#]*)#?(?<tag>.*)$') {
        return $null
    }
    $m = $Matches
    $p = @{}
    foreach ($kv in ($m.query -split '&')) {
        if ($kv -match '^([^=]+)=(.*)$') { $p[$Matches[1]] = [Uri]::UnescapeDataString($Matches[2]) }
    }
    [pscustomobject]@{
        Scheme   = $m.scheme
        UserInfo = [Uri]::UnescapeDataString($m.userinfo)
        Server   = $m.host
        Port     = [int]$m.port
        Params   = $p
        Tag      = [Uri]::UnescapeDataString($m.tag)
    }
}

$failed = 0
foreach ($url in $SubUrl) {
    # Never print the token itself
    $label = ($url -split '/')[-1]
    $label = if ($label.Length -gt 4) { '...' + $label.Substring($label.Length - 4) } else { $label }
    Write-Host "`n===== subscription $label =====" -ForegroundColor Cyan

    $raw = (Invoke-WebRequest -Uri $url -UseBasicParsing -UserAgent 'sing-box' -TimeoutSec 30).Content
    if ($raw -is [byte[]]) { $raw = [Text.Encoding]::UTF8.GetString($raw) }
    $c = ($raw -replace '\s', '')
    try {
        $pad = (4 - ($c.Length % 4)) % 4
        $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($c + ('=' * $pad)))
    } catch { $decoded = $raw }

    $parsed = ($decoded -split "`r?`n" | Where-Object { $_.Trim() }) |
                ForEach-Object { ConvertFrom-ProxyUri $_ } | Where-Object { $_ }
    $vless = $parsed | Where-Object { $_.Scheme -eq 'vless' }     | Select-Object -First 1
    $hy2   = $parsed | Where-Object { $_.Scheme -eq 'hysteria2' } | Select-Object -First 1

    Write-Host ("  entries parsed : {0}" -f @($parsed).Count)
    if (-not $vless) { Write-Host '  NO vless:// entry' -ForegroundColor Red; $failed++; continue }
    Write-Host ("  vless          : sni={0} sid={1} fp={2}" -f `
        $vless.Params['sni'], $vless.Params['sid'], $vless.Params['fp'])

    $useHy2 = $false
    if (-not $hy2)               { Write-Host '  hysteria2      : ABSENT'      -ForegroundColor Yellow }
    elseif (-not $hy2.UserInfo)  { Write-Host '  hysteria2      : EMPTY PASSWORD -> will be skipped' -ForegroundColor Yellow }
    else                         { $useHy2 = $true; Write-Host ("  hysteria2      : {0}:{1}" -f $hy2.Server, $hy2.Port) }

    $cfg = Get-Content $Tpl -Raw | ConvertFrom-Json
    $cfg.experimental.cache_file.path = 'C:/vpn/cache.db'

    $vo = $cfg.outbounds | Where-Object { $_.tag -eq 'vless-out' }
    $vo.server = $vless.Server; $vo.server_port = $vless.Port; $vo.uuid = $vless.UserInfo
    $vo.flow = if ($vless.Params['flow']) { $vless.Params['flow'] } else { '' }
    $vo.tls.server_name        = if ($vless.Params['sni']) { $vless.Params['sni'] } else { $vless.Server }
    $vo.tls.reality.public_key = $vless.Params['pbk']
    $vo.tls.reality.short_id   = $vless.Params['sid']
    $vo.tls.utls.fingerprint   = if ($vless.Params['fp']) { $vless.Params['fp'] } else { 'randomized' }

    if ($useHy2) {
        $ho = $cfg.outbounds | Where-Object { $_.tag -eq 'hy2' }
        $ho.server = $hy2.Server; $ho.server_port = $hy2.Port; $ho.password = $hy2.UserInfo
        $ho.tls.server_name = if ($hy2.Params['sni']) { $hy2.Params['sni'] } else { $hy2.Server }
    } else {
        $cfg.outbounds = @($cfg.outbounds | Where-Object { $_.tag -ne 'hy2' })
        $ut = $cfg.outbounds | Where-Object { $_.tag -eq 'hy2-out' }
        $ut.outbounds = @($ut.outbounds | Where-Object { $_ -ne 'hy2' })
    }

    # No BOM: sing-box's JSON decoder rejects it.
    $out = Join-Path $env:TEMP ('singbox-test-{0}.json' -f [guid]::NewGuid())
    [IO.File]::WriteAllText($out, ($cfg | ConvertTo-Json -Depth 30), (New-Object Text.UTF8Encoding $false))

    $res = & $Exe check -c $out 2>&1
    if ($LASTEXITCODE -eq 0) {
        Write-Host ("  hy2 included   : {0}" -f $useHy2)
        Write-Host '  sing-box check : OK' -ForegroundColor Green
    } else {
        Write-Host '  sing-box check : FAILED' -ForegroundColor Red
        $res | ForEach-Object { Write-Host "      $_" -ForegroundColor Red }
        $failed++
    }
    Remove-Item $out -Force -ErrorAction SilentlyContinue
}

Write-Host ''
if ($failed) { Write-Host "$failed subscription(s) FAILED" -ForegroundColor Red; exit 1 }
Write-Host 'All subscriptions produced a valid config.' -ForegroundColor Green
