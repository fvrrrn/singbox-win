# singbox-win

Zero-GUI sing-box bundle for Windows. One pasteable line installs it, injects per-user
credentials from a subscription URL, and registers autostart. No auto-updating client,
no version roulette.

## Install

Paste into Win+R (fits the 259-char limit):

```
powershell -c "$SubUrl='https://HOST/PATH/TOKEN'; irm https://raw.githubusercontent.com/OWNER/singbox-win/v1/bootstrap.ps1|iex"
```

The script self-elevates (TUN needs administrator), creates `Desktop\vpn`, downloads
this repo at the pinned tag, generates `config.json`, validates it, and starts sing-box
via a scheduled task that runs at boot as SYSTEM.

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

If upstream is unreachable, the script falls back to the same asset re-uploaded to this
repo's release for the pinned tag. The mirror faces the same hash check — a mirror that
cannot match the pin is not trusted either. Upload it once per tag; installs work
without it as long as upstream is up.

Re-running the installer skips the download when `sing-box.sha256` already matches the
pin, so a config refresh costs a few KB rather than 55 MB.

## Releasing

One tag pins the scripts, the config template and the binary hash, because
`bootstrap.ps1` is fetched from the same tag it downloads the bundle from. To cut a
release:

1. Update `$RepoTag` in `bootstrap.ps1` to the tag you are about to create.
2. If sing-box is being bumped: set `$SbVersion`, download the new asset, and paste its
   real SHA256 into `$SbSha256`. Never copy a hash you have not computed yourself.
3. Commit, `git tag v2`, push the tag.
4. Create the GitHub release for `v2` and attach `sing-box-<ver>-windows-amd64.zip` as
   the mirror asset.
5. Hand out the one-liner with `/v2/` in the URL.

Never point the one-liner at a branch or at `latest` — that reintroduces exactly the
auto-update failure this bundle exists to avoid.

## Testing before you ship

```powershell
.\tools\test-config-gen.ps1 -SubUrl 'https://HOST/PATH/TOKEN'
```

Fetches the subscription, generates a config, runs `sing-box check`. No TUN, no service,
no install. Run it against a few real accounts after any panel change.

## Config design

Ported from a known-good Linux config. It is an **allowlist**: `route.final` is
`direct-out`, so traffic goes direct by default and only Re-filter list matches plus the
inline `custom` domain list are tunneled. Outbound selection is a `urltest` group
preferring Hysteria2 with VLESS-Reality as fallback.

Windows-specific deviations from the Linux original:

- `auto_redirect` removed — Linux-only (nftables/eBPF); a no-op on Windows.
- `interface_name` removed — `tun0` is a Linux convention; let sing-box name the adapter.
- `cache_file.path` is absolute — relative paths resolve against CWD, which is wrong
  under Task Scheduler.
- Rule-sets stay `remote`. `initial_path` (a bundled snapshot fallback) is a sing-box
  1.14 field and is rejected by 1.13.15. Remote is safe here anyway: `final` is direct,
  so the download works before any tunnel exists, and `cache_file` covers later starts.

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
