# aws-vpn: `vpn` wrapper for the AWS VPN Client 6.x CLI

Date: 2026-09-09
Status: approved design, awaiting implementation plan

## Goal

Keep the `vpn` command-line workflow from [jlars22/aws-vpn-cli](https://github.com/jlars22/aws-vpn-cli)
(fzf picker, `vpn <slug>` toggle, `vpn all`, `vpn status`, `vpn prompt` for the shell prompt) on top of
the official `aws-vpn-client` CLI shipped with AWS VPN Client 6.0 and later. The official client owns
the tunnel, SAML flow, DNS and profile storage; this tool only adds the ergonomics.

## Non-goals

- No tunnel handling of our own: no OpenVPN binary, no sudo, no sudoers rules, no PID files, no SAML
  listener, no DNS scripts. All of that is the daemon's job.
- No profile import/export beyond what `aws-vpn-client` does. `import-profile` is used directly and rarely.
- No config file. The daemon is the single source of truth for profiles and connections.
- No macOS or Windows support in the first version. Linux with systemd is what is tested. The script
  avoids Linux-only constructs where it costs nothing, so macOS can follow later.

## Dependencies

- `aws-vpn-client` 6.x (installed by the `awsvpnclient` package, symlinked at `/usr/local/bin/aws-vpn-client`)
  with its daemon `aws-client-vpn-daemon` running.
- `jq` (JSON parsing).
- `fzf`, optional. Without it the picker falls back to a numbered `select` menu.
- `bash` 4+, `coreutils` (`date`, `timeout`), `grep`, `tail`.

## Repository layout

Local `~/cardlay/aws-vpn`, GitHub `mmh/aws-vpn`, public, MIT license.

```
vpn                        main script (bash, set -euo pipefail)
vpn.bash                   bash completion: commands + slugs from list-profiles
test/run.sh                test runner, plain bash, no framework
test/stub/aws-vpn-client   stub CLI standing in for the daemon during tests
.github/workflows/ci.yml   shellcheck + bash test/run.sh on push and pull request
README.md                  install, usage, migration from aws-vpn-cli, observed daemon states
LICENSE                    MIT
docs/superpowers/specs/    this document
```

Install: `ln -sf ~/cardlay/aws-vpn/vpn ~/bin/vpn` and `source ~/cardlay/aws-vpn/vpn.bash` from `.bashrc`.

## Profiles and naming

Profile names in the daemon are the slugs the user types: `dev`, `stage`, `prod`, `prod-us`. No mapping
table. Profile order everywhere (picker, `status`, `list`, `all`, `prompt`) is import order, read from the
`imported-at` field of `list-profiles`. Importing in environment order (dev, stage, prod, prod-us) is
therefore all the configuration needed.

Region shown in `status` is derived from the profile's `remote` line via `get-config`, matching
`clientvpn\.([a-z0-9-]+)\.amazonaws\.com`. Unknown format prints no region.

## Commands

| Command | Behaviour |
|---|---|
| `vpn` | Picker over all profiles, `●` connected with uptime, `○` not connected. Enter toggles the picked profile. fzf when available, otherwise a numbered `select` menu. |
| `vpn <slug>` | Toggle: disconnect if connected, otherwise connect. Unknown slug: error listing valid slugs, exit 1. |
| `vpn all` | Connect every profile that is not connected, sequentially. Each one waits for its own browser round. |
| `vpn status` | One line per connected profile: `✓ Connected to dev (eu-central-1)  00:12:34`. `> Not connected` when none. |
| `vpn disconnect [slug\|all]`, alias `down` | No argument: if exactly one profile is connected, disconnect it; if several, picker; if none, message and exit 0. `all`: disconnect each connected profile. |
| `vpn list`, alias `ls` | Slugs in import order with connected marker. |
| `vpn prompt` | `🔒all` when every profile is connected, `🔒dev,stage` (import order) when some are, nothing when none. |
| `vpn logs [slug]` | `tail -F` the newest `/var/log/awsvpnclient/aws_vpn_client_daemon_*.log`, filtered with `grep --line-buffered 'profile=<slug>'` when a slug is given. |
| `vpn -v`, `--version` | Print version. |
| `vpn -h`, `--help` | Usage. |

Output style follows aws-vpn-cli: `==>` step lines, `✓` success, `!` warning, `✗` error, colours only
when stdout is a terminal.

## Internal structure

Small functions, each with one job:

- `cli <args>`: runs `aws-vpn-client`, captures stdout, validates JSON with `jq -e`, maps failures to
  the error cases in the next section. Every daemon interaction goes through it.
- `profiles`: slugs in import order.
- `active`: connected slugs with their `last-updated-at`.
- `is_active <slug>`.
- `region_of <slug>`, `uptime_of <slug>` (`MM:SS` under one hour, `HH:MM:SS` otherwise).
- `connect_profile <slug>`, `disconnect_profile <slug>`.
- `cmd_*` per command, dispatched from a `case` at the bottom.

Environment variables, mainly for tests: `VPN_CONNECT_TIMEOUT` (seconds, default 180),
`VPN_POLL_INTERVAL` (seconds, default 0.5), `NO_COLOR` disables colours.

## Connect state machine

`aws-vpn-client connect --profile-name <slug>` returns immediately, with `{"status":"WaitingForIdentity"}`
for SAML profiles. The tool then polls `get-connection-status --profile-name <slug>` every
`VPN_POLL_INTERVAL` seconds and acts on `connection-status`:

| Status | Action |
|---|---|
| `WaitingForIdentity` | print `Waiting for browser SSO…` once, keep polling |
| `Connecting` | print `Establishing tunnel` once, keep polling |
| `Connected` | print `✓ Connected to <slug> (<region>)`, exit 0 |
| anything else | print `✗ <status>` (and `message` if present), exit 1 |
| no `Connected` within `VPN_CONNECT_TIMEOUT` | run `disconnect --profile-name <slug>` to cancel the pending attempt, print timeout error, exit 1 |
| SIGINT while polling | same cancel, exit 130 |

Failure status names are not documented by AWS. They are discovered during implementation by aborting a
login and recorded in the README.

## Error handling

- `aws-vpn-client` not on `PATH`: `✗ aws-vpn-client not found, install AWS VPN Client 6.x`, exit 1.
- `jq` not on `PATH`: same pattern, exit 1.
- Daemon unreachable (CLI exits non-zero without JSON, or prints non-JSON):
  `✗ AWS VPN Client daemon not reachable: systemctl status aws-client-vpn-daemon`, exit 1.
- CLI error JSON (`{"status":"Error","message":"..."}`): `✗ <message>`, exit 1.
- Exit codes: 0 success, 1 error, 130 interrupted.

## Prompt safety

`vpn prompt` runs in every prompt render, so it must be fast and must never fail loudly. The daemon call
is wrapped in `timeout 1`, stderr is discarded, and any failure prints nothing and exits 0. One daemon
call when idle, two when something is connected (to decide `all`). Measured cost of one call: ~20 ms.

## Testing

`test/stub/aws-vpn-client` is a bash script placed first on `PATH` by the runner. State lives in
`$VPN_STUB_DIR`:

- `profiles.json`: what `list-profiles` returns.
- `connections.json`: what `list-connections` returns; `connect` and `disconnect` mutate it.
- `status-sequence`: statuses returned by successive `get-connection-status` calls, one per line,
  last line repeats (e.g. `WaitingForIdentity`, `Connecting`, `Connected`).
- `config-<slug>`: what `get-config` returns.
- `calls.log`: every invocation, for assertions.
- `fail`: when present, every call exits 1 with no output (daemon down).

`test/run.sh` sets `VPN_CONNECT_TIMEOUT=2`, `VPN_POLL_INTERVAL=0.05`, `NO_COLOR=1`, and runs these
cases with plain `assert_eq`/`assert_contains` helpers:

1. `vpn dev` when disconnected calls `connect`, polls to `Connected`, prints success.
2. `vpn dev` when connected calls `disconnect`.
3. Unknown slug exits 1 and lists valid slugs.
4. `vpn all` connects only profiles that are down, in import order.
5. `vpn disconnect all` disconnects every connected profile.
6. `vpn prompt`: nothing, `🔒dev,stage`, `🔒all`.
7. `vpn status` shows region and uptime for connected profiles, `Not connected` otherwise.
8. Connect timeout cancels via `disconnect` and exits 1.
9. Unknown status during polling exits 1 with the status in the message.
10. Daemon down prints the systemctl hint and exits 1; `vpn prompt` prints nothing and exits 0.
11. `vpn list` follows `imported-at` order, not the daemon's output order.

Implementation follows TDD: each case is written before the code it covers. CI runs shellcheck and the
test runner on every push and pull request. A final manual check connects a real profile.

## Migration from aws-vpn-cli

1. Disconnect all tunnels.
2. Re-import the four profiles under slug names, in order, as the normal user:
   ```
   aws-vpn-client delete-profile --profile-name NebulaDev
   aws-vpn-client import-profile --profile-name dev --config-path ~/.config/AWSVPNClient/OpenVpnConfigs/NebulaDev
   ```
   Repeat for `NebulaStage` → `stage`, `NebulaProduction` → `prod`, `NebulaProdUS` → `prod-us`.
3. `ln -sf ~/cardlay/aws-vpn/vpn ~/bin/vpn`; change the `.bashrc` completion line to
   `source ~/cardlay/aws-vpn/vpn.bash`.
4. The old tool in `~/temp/aws-vpn-cli` keeps working through the backed-up OpenVPN binary and can be
   removed later together with `~/.config/aws-vpn-cli`, `/usr/local/lib/aws-vpn-cli` and
   `/etc/sudoers.d/aws-vpn-cli` (the last two need sudo).

## Open points

- Exact failure status names from `get-connection-status` (found during implementation).
- Whether `connect` ever returns `Connected` directly for SAML profiles, or a non-zero exit for an
  unknown profile (the CLI documents `{"status":"Error"}` with exit 1 for other commands).
