#Requires -Version 5.1
<#
.SYNOPSIS
  Fetches a subscription URL and emits the rendered sing-box config as JSON on stdout.

.DESCRIPTION
  Does exactly one thing: URL in, config JSON out. Writes no files, touches no system
  state, registers nothing. Everything that is not the config itself goes to the warning
  and verbose streams, so stdout stays clean enough to pipe.

  This is the same parse-and-render logic bootstrap.ps1 uses in steps 1-4, factored out
  so it can be tested and reused on its own.

.PARAMETER SubUrl
  The subscription URL. Accepts pipeline input.

.PARAMETER InstallDir
  Where the running install will live. Only used to render experimental.cache_file.path.
  Defaults to the Desktop\vpn path bootstrap.ps1 installs to.

.EXAMPLE
  .\make-config.ps1 -SubUrl 'https://host/sub/TOKEN'

.EXAMPLE
  # Write it out (BOM-less, as sing-box requires)
  $json = .\make-config.ps1 -SubUrl 'https://host/sub/TOKEN'
  [IO.File]::WriteAllText('C:\vpn\config.json', $json, (New-Object Text.UTF8Encoding $false))

.EXAMPLE
  'https://host/sub/TOKEN' | .\make-config.ps1 | ConvertFrom-Json | Select-Object -Expand outbounds
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory, ValueFromPipeline)]
    [string] $SubUrl,

    [string] $InstallDir = (Join-Path ([Environment]::GetFolderPath('Desktop')) 'vpn'),

    [string] $Template = (Join-Path $PSScriptRoot 'config.template.json')
)

begin {
    $ErrorActionPreference = 'Stop'
    [Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
    try { [Net.ServicePointManager]::SecurityProtocol = `
            [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls13 } catch {}

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
}

process {
    if (-not (Test-Path $Template)) { throw "Template not found: $Template" }

    $raw = (Invoke-WebRequest -Uri $SubUrl -UseBasicParsing -UserAgent 'sing-box' -TimeoutSec 30).Content
    if ($raw -is [byte[]]) { $raw = [Text.Encoding]::UTF8.GetString($raw) }

    $compact = ($raw -replace '\s', '')
    try {
        $pad = (4 - ($compact.Length % 4)) % 4
        $decoded = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($compact + ('=' * $pad)))
    } catch {
        $decoded = $raw   # subscription is already plain text
    }

    $parsed = ($decoded -split "`r?`n" | Where-Object { $_.Trim() }) |
                ForEach-Object { ConvertFrom-ProxyUri $_ } | Where-Object { $_ }
    Write-Verbose "entries parsed: $(@($parsed).Count)"

    $vless = $parsed | Where-Object { $_.Scheme -eq 'vless' }     | Select-Object -First 1
    $hy2   = $parsed | Where-Object { $_.Scheme -eq 'hysteria2' } | Select-Object -First 1
    if (-not $vless) { throw 'No vless:// entry in subscription - contact your administrator' }
    Write-Verbose "vless: $($vless.Server):$($vless.Port) sni=$($vless.Params['sni'])"

    # Hysteria2 has no anonymous mode, so an empty password can never authenticate.
    # That is a panel-side per-user bug: drop the outbound, keep a working VLESS config.
    $useHy2 = $false
    if (-not $hy2) {
        Write-Warning 'No hysteria2:// entry in subscription - VLESS only'
    } elseif (-not $hy2.UserInfo) {
        Write-Warning 'Hysteria2 password is EMPTY - entry skipped (panel misconfiguration)'
    } else {
        $useHy2 = $true
        Write-Verbose "hysteria2: $($hy2.Server):$($hy2.Port)"
    }

    $cfg = Get-Content $Template -Raw | ConvertFrom-Json

    # Forward slashes in paths: avoids JSON backslash-escaping entirely
    $cfg.experimental.cache_file.path = ($InstallDir -replace '\\', '/') + '/cache.db'

    $vo = $cfg.outbounds | Where-Object { $_.tag -eq 'vless-out' }
    $vo.server                  = $vless.Server
    $vo.server_port             = $vless.Port
    $vo.uuid                    = $vless.UserInfo
    $vo.flow                    = if ($vless.Params['flow']) { $vless.Params['flow'] } else { '' }
    $vo.tls.server_name         = if ($vless.Params['sni'])  { $vless.Params['sni'] }  else { $vless.Server }
    $vo.tls.reality.public_key  = $vless.Params['pbk']
    $vo.tls.reality.short_id    = $vless.Params['sid']
    $vo.tls.utls.fingerprint    = if ($vless.Params['fp']) { $vless.Params['fp'] } else { 'randomized' }

    if ($useHy2) {
        $ho = $cfg.outbounds | Where-Object { $_.tag -eq 'hy2' }
        $ho.server          = $hy2.Server
        $ho.server_port     = $hy2.Port
        $ho.password        = $hy2.UserInfo
        $ho.tls.server_name = if ($hy2.Params['sni']) { $hy2.Params['sni'] } else { $hy2.Server }
    } else {
        # Drop hy2 from outbounds and from the urltest group
        $cfg.outbounds = @($cfg.outbounds | Where-Object { $_.tag -ne 'hy2' })
        $ut = $cfg.outbounds | Where-Object { $_.tag -eq 'hy2-out' }
        $ut.outbounds = @($ut.outbounds | Where-Object { $_ -ne 'hy2' })
    }

    # Sole stdout write. Callers that persist this must use a BOM-less UTF8 encoder:
    # PS 5.1's Set-Content -Encoding UTF8 emits a BOM and sing-box rejects it.
    $cfg | ConvertTo-Json -Depth 30
}
