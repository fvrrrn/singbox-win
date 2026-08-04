# singbox-win

Zero-GUI sing-box bundle for Windows. One pasteable line installs it, injects per-user
credentials from a subscription URL, and registers autostart. No auto-updating client,
no version roulette.

## Install

Paste into Win+R (fits the 259-char limit):

```
powershell -c "$SubUrl='https://HOST/PATH/TOKEN'; irm https://raw.githubusercontent.com/fvrrrn/singbox-win/main/bootstrap.ps1|iex"
```

The script self-elevates (TUN needs administrator), creates `Desktop\vpn`, downloads
this repo at `main`, fetches the pinned sing-box build, generates `config.json`,
validates it, and starts sing-box via a scheduled task that runs at boot as SYSTEM.

Re-running **without** `$SubUrl` refreshes the config from the saved `subscription.txt`.

Uninstall: run `uninstall.ps1` from the install folder.

## Layout

| File | Purpose |
|---|---|
| `config.template.json` | Config with placeholder credentials; `make-config.ps1` fills them in. |
| `bootstrap.ps1` | Installer. Served from the tagged raw URL. |
| `make-config.ps1` | Subscription URL in, config JSON out on stdout. Writes nothing. |
| `uninstall.ps1` | Stops the task, unregisters it, deletes the folder. |
| `tools/test-config-gen.ps1` | Validates generated configs without touching the system. |

`sing-box.exe` and `libcronet.dll` are **not** in the repo — see below. They land in the
install folder at step 3, alongside a `sing-box.sha256` stamp file.

## Where the binaries come from

The repo tracks no binaries. `bootstrap.ps1` downloads
`sing-box-1.13.15-windows-amd64.zip` from SagerNet's own release and checks it against
`$SbSha256`, hardcoded in the script. That pins the bytes exactly as tightly as
committing them would, without adding ~22 MB of permanently unshrinkable blobs to git
history on every version bump.

Both files come from that one upstream zip; `libcronet.dll` is not a custom build.
`sing-box.exe` embeds the wintun driver, so there is nothing else to ship.

There is deliberately **no mirror**. A second source could only ever serve bytes that
pass the same hash check, so it would add somewhere else to keep in sync without adding
any trust. If SagerNet is unreachable the install stops, which is the honest outcome —
it does not fall back to something less pinned.

Re-running the installer skips the download when `sing-box.sha256` already matches the
pin, so a config refresh costs a few KB rather than 55 MB.

## Shipping

There are no tags and no releases. `main` is the single source of truth: the one-liner
fetches `bootstrap.ps1` from `main` and downloads the bundle from `main`, so **a push to
`main` ships to everyone the next time they install or refresh.** There is no staging ref
between a commit and ~30 machines.

That puts the whole burden on the push itself:

1. Run `tools/test-config-gen.ps1` against a couple of real accounts.
2. If sing-box is being bumped: set `$SbVersion`, download the new asset, and paste a
   SHA256 you computed yourself into `$SbSha256`. Never copy one off a release page.
3. Push to `main`.

The handout line never changes, which is the point — but it also means a bad push is
live immediately, and rolling back means pushing a fix, not moving a ref. The sing-box
binary is the one thing still pinned by hash, so an upstream change cannot reach users
without an edit to `$SbSha256`.

## Testing before you ship

```powershell
.\tools\test-config-gen.ps1 -SubUrl 'https://HOST/PATH/TOKEN'
```

Fetches the subscription, generates a config, runs `sing-box check`. No TUN, no service,
no install. Run it against a few real accounts after any panel change.

## Config design

Ported from a known-good Linux config. It is a **blocklist**: `route.final` is `hy2-out`,
so traffic is tunneled by default and only three things go direct — private IPs, the
`.ru`/`.xn--p1ai`/`.su` suffixes, and `geosite-category-ru`. Outbound selection is a
`urltest` group preferring Hysteria2 with VLESS-Reality as fallback.

It started as an allowlist driven by the Re-filter lists. That inverted once the blocked
set outgrew the effort of tracking it. The trade is real: all traffic now crosses the VPS,
an outage takes out everything instead of a few sites, and Russian services hosted on
`.com` or third-party CDNs fall through to the tunnel. Widen the direct rules when that
happens; don't touch `final`.

Two ordering constraints that aren't obvious from reading the JSON. The inline `custom`
list force-tunnels and sits **above** the `.ru` rules, so it can override them — move it
and it stops working. And `.ru` DNS goes to `local-dns` rather than the DoH server,
because resolving Russian names through 8.8.8.8 hands back CDN nodes chosen for Google's
resolver.

Windows-specific deviations from the Linux original:

- `auto_redirect` removed — Linux-only (nftables/eBPF); a no-op on Windows.
- `interface_name` removed — `tun0` is a Linux convention; let sing-box name the adapter.
- `cache_file.path` is absolute — relative paths resolve against CWD, which is wrong
  under Task Scheduler.
- Rule-sets stay `remote`. `initial_path` (a bundled snapshot fallback) is a sing-box
  1.14 field and is rejected by 1.13.15. What keeps remote safe is `download_detour:
  direct-out` on the rule-set itself, so the fetch never depends on a tunnel that isn't
  up yet; `cache_file` covers later starts. This mattered less when `final` was direct.
  Now it is the only thing preventing a first-run deadlock.

## Gotchas worth not rediscovering

- **No BOM in `config.json`.** PowerShell 5.1's `Set-Content -Encoding UTF8` writes a
  BOM and sing-box's JSON decoder rejects it (`invalid character 'ï'`). Use
  `[IO.File]::WriteAllText(path, text, (New-Object Text.UTF8Encoding $false))`.
- **Scripts are ASCII-only on purpose.** PS 5.1 reads BOM-less files as the system
  codepage, so non-ASCII text needs a UTF-8 BOM to survive. Staying ASCII removes the
  whole problem.
- **Forward slashes in JSON paths.** Sidesteps backslash escaping; sing-box accepts them
  on Windows.
- **Empty Hysteria2 passwords.** A subscription can emit `hysteria2://@host:443` with no
  password — the userinfo field is blank. Hysteria2 has no anonymous mode, so such an
  entry can never authenticate. `bootstrap.ps1` detects this, drops the outbound, warns,
  and still produces a working VLESS-only config. If users report "no Hysteria2", check
  the panel for a blank password before suspecting the client.
- **Xray-core cannot do Hysteria2.** Any client pinned to Xray will silently offer VLESS
  only. Hysteria2 requires the sing-box core.
- Credentials live in `config.json` and `subscription.txt`, both gitignored. Do not
  commit them; do not paste subscription URLs into shared logs.
