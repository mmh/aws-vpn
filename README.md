# aws-vpn

`vpn`: an fzf picker, connect/disconnect toggle and shell-prompt indicator on top of the
official `aws-vpn-client` CLI that ships with AWS VPN Client 6.0 and later. The official
client owns the tunnel, SAML login, DNS and profile storage. This script only adds the
ergonomics of [jlars22/aws-vpn-cli](https://github.com/jlars22/aws-vpn-cli), which needed the
OpenVPN binary that 6.x no longer ships.

Linux only for now. No sudo needed: the daemon runs as root, the CLI talks to it over a socket.

## Requirements

- [AWS VPN Client](https://docs.aws.amazon.com/vpn/latest/clientvpn-user/client-vpn-connect-linux.html) 6.0.1 or later, daemon `aws-client-vpn-daemon` running
- `jq`
- `fzf` (optional, for the picker; falls back to a numbered menu)

## Install

```bash
git clone https://github.com/mmh/aws-vpn.git ~/cardlay/aws-vpn
ln -sf ~/cardlay/aws-vpn/vpn ~/bin/vpn          # any directory on your PATH
echo 'source ~/cardlay/aws-vpn/vpn.bash' >> ~/.bashrc
```

Profile names are whatever `aws-vpn-client list-profiles` shows, in import order. Short names
make the tool pleasant, so import your `.ovpn` files under slugs:

```bash
aws-vpn-client import-profile --profile-name dev   --config-path ~/Downloads/dev.ovpn
aws-vpn-client import-profile --profile-name stage --config-path ~/Downloads/stage.ovpn
```

Import in the order you want them listed; `imported-at` has one-second resolution, so leave a
second between imports.

## Usage

```console
$ vpn                       # picker: ● connected (uptime) / ○ not connected, Enter toggles
$ vpn dev                   # connect, or disconnect if already connected
$ vpn all                   # connect everything that is down, one browser login each
$ vpn status                # ✓ Connected to dev (eu-central-1) 12:34
$ vpn disconnect [dev|all]  # one, all, or a picker when several are up   (alias: down)
$ vpn list                  # profiles in import order                     (alias: ls)
$ vpn logs [dev]            # tail the daemon log, filtered by profile
$ vpn prompt                # 🔒all / 🔒dev,stage / nothing
```

Shell prompt example (bash):

```bash
vpn_info=$(vpn prompt 2>/dev/null)
[[ -n $vpn_info ]] && PS1+=" \[\e[1;32m\]${vpn_info}\[\e[0m\]"
```

Environment: `VPN_CONNECT_TIMEOUT` (seconds to wait for a connection, default 180),
`VPN_POLL_INTERVAL` (default 0.5), `VPN_LOG_DIR` (default `/var/log/awsvpnclient`),
`VPN_NO_FZF=1` (force the numbered menu), `NO_COLOR`.

## How it works

`connect` in the 6.x CLI returns immediately with `{"status":"WaitingForIdentity"}` while the
browser login runs in the daemon. `vpn` polls `get-connection-status` and reports:

| `connection-status` | meaning |
|---|---|
| `NotConnected` | idle |
| `WaitingForIdentity` | browser SSO pending |
| `Connecting` | tunnel coming up |
| `Connected` | done |

Anything else is treated as a failure. On timeout or Ctrl-C the pending attempt is cancelled
with `disconnect`. CLI errors arrive as `{"status":"Error","message":"..."}` on stderr with exit 1
and are shown as `✗ message`; a CLI that fails without JSON is reported as the daemon being down.

DNS: the daemon sets the pushed DNS server on the tunnel interface. Per-environment routing
domains (so `*.example.internal` goes to the right tunnel when several are up) are not pushed by
AWS Client VPN; a NetworkManager dispatcher script that calls `resolvectl domain` per interface
does that job and is out of scope here.

## Migrating from aws-vpn-cli

1. Disconnect everything.
2. Re-import the profiles under short names, in the order you want (one second apart).
   The `.ovpn` files saved by the old client (`~/.config/AWSVPNClient/OpenVpnConfigs/`) lack
   the `auth-federate` line for SAML endpoints; the old client kept that flag in its own
   profile store. Without it the daemon types the profile as username/password (`auth-type: ad`)
   and `connect` prompts for a username instead of opening the browser. Append the line first:
   ```bash
   cd ~/.config/AWSVPNClient/OpenVpnConfigs
   { cat NebulaDev; echo; echo auth-federate; } | grep -v '^$' > dev.ovpn
   aws-vpn-client delete-profile --profile-name NebulaDev
   aws-vpn-client import-profile --profile-name dev --config-path dev.ovpn
   aws-vpn-client list-profiles | jq -r '.[] | "\(.["profile-name"]) \(.["auth-type"])"'   # expect saml
   ```
3. Point `~/bin/vpn` and the `.bashrc` `source` line at this repo.
4. `vpn setup-sudo` artefacts are no longer needed: `/etc/sudoers.d/aws-vpn-cli`,
   `/usr/local/lib/aws-vpn-cli`, `~/.config/aws-vpn-cli`.

## Development

```bash
bash test/run.sh                                     # runs against test/stub/aws-vpn-client
shellcheck vpn vpn.bash test/run.sh test/stub/aws-vpn-client
```

## License

MIT
