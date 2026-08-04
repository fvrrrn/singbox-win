# singbox-win

Zero-GUI sing-box bundle for Windows, deployed to ~30 non-technical users by one
pasteable Win+R line. `bootstrap.ps1` is fetched from `main`, downloads this repo at
`main`, fetches a hash-pinned sing-box from SagerNet, injects per-user credentials
parsed from a subscription URL, validates the generated config, and registers a
scheduled task that runs at boot as SYSTEM.

See `README.md` for the full design rationale and release process.

## Invariants — do not break these

- **`config.json` must have no BOM.** PS 5.1's `Set-Content -Encoding UTF8` writes one and
  sing-box's JSON decoder rejects it. Always use
  `[IO.File]::WriteAllText($p, $text, (New-Object Text.UTF8Encoding $false))`.
- **`.ps1` files stay ASCII-only.** PS 5.1 reads BOM-less files as the system codepage, so
  non-ASCII text would require a UTF-8 BOM to survive. Staying ASCII avoids the whole
  class of bug. Do not add Cyrillic or other non-ASCII strings.
- **Use forward slashes in JSON paths.** Avoids backslash escaping; sing-box accepts them
  on Windows.
- **`main` is the only ref. No tags, no releases.** Users install from `main` and
  re-installs pull `main` again, so anything pushed there ships immediately to everyone —
  there is no staging ref between you and ~30 machines. Land work on `main` only when it
  is ready to ship, and run `tools/test-config-gen.ps1` before pushing.
- **The sing-box binary is still pinned, and must stay that way.** `$SbSha256` in
  `bootstrap.ps1` is the one thing preventing an upstream change from reaching users
  unreviewed. Bumping `$SbVersion` means downloading the asset and pasting a hash you
  computed yourself — never one copied from a release page.
- **Never commit credentials.** `config.json`, `subscription.txt`, `cache.db` are
  gitignored and generated per user at install time. Subscription URLs are credentials —
  keep them out of committed files, test fixtures, and logs.
- **Config is a blocklist.** `route.final` is `hy2-out`: tunneled by default, and only
  private IPs, `.ru`/`.xn--p1ai`/`.su`, and `geosite-category-ru` go direct. It used to be
  the other way round; the allowlist lost because the blocked set grew faster than anyone
  wanted to maintain it. Two consequences to keep in mind when editing:
  - Every user's full traffic crosses the VPS, so an outage breaks everything rather than
    a handful of sites.
  - Russian services on `.com` or third-party CDNs fall through to the tunnel and will be
    reported as broken. Fix those by widening the direct rules, not by touching `final`.
- **`custom` force-tunnels and must stay above the direct rules.** It is the only way to
  send a Russian domain through the VPN. Reordering `route.rules` silently disables it.
- **`.ru` DNS goes to `local-dns`, not `doh-dns`.** Resolving Russian names through
  8.8.8.8 returns CDN nodes picked for Google's resolver. Sites still load, just slowly,
  which gets reported as "the VPN broke my internet".

## Testing

```powershell
.\tools\test-config-gen.ps1 -SubUrl 'https://HOST/PATH/TOKEN'
```

Fetches the subscription, renders `config.template.json`, runs `sing-box check`. Touches
nothing: no TUN, no service, no install. Run it against real accounts after any panel or
template change. Pass tokens as arguments — never hardcode them.

Do not bring up TUN to test without asking first; it rewrites the host's routing table.

## Domain gotchas

- **Xray-core cannot do Hysteria2** (QUIC-based, sing-box/hysteria only). Any client
  pinned to Xray silently offers VLESS only. This is the single most common cause of
  "Hysteria2 doesn't work" reports.
- **Subscriptions can emit `hysteria2://@host:443` with an empty password.** Hysteria2 has
  no anonymous mode, so such an entry can never authenticate. This is a panel-side
  per-user data bug, not a client limitation. `bootstrap.ps1` detects it, drops the
  outbound, warns, and still produces a working VLESS-only config. Preserve that
  graceful degradation.
- `initial_path` on rule-sets is sing-box **1.14+** and is rejected by the pinned 1.13.15.
- `auto_redirect` and `interface_name: tun0` are Linux-only; they do not belong in the
  Windows config.
- Subscription `sid`, `spx`, and `sni` values rotate per request. That is normal panel
  randomization, not a bug — don't chase it.
