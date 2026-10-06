# Ayanakoji tunnel stack

SSH-over-HTTP/TLS tunnel for a Debian or Ubuntu VPS: a Go proxy that completes
whatever handshake the client expects, behind an HAProxy frontend that
multiplexes port 443 between SSH, V2Ray and a decoy website.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/X-jelly18/Bella/main/vps/install.sh | sudo bash
```

This installs packages, builds the proxy and drops you in the setup menu.

Piping a remote script into a root shell runs whatever that URL serves at that
moment. To see it first:

```sh
curl -fsSL -o install.sh https://raw.githubusercontent.com/X-jelly18/Bella/main/vps/install.sh
less install.sh
sudo bash install.sh
```

For a repeatable install, pin to a commit instead of a branch:

```sh
REF=<commit-sha> curl -fsSL https://raw.githubusercontent.com/X-jelly18/Bella/<commit-sha>/vps/install.sh | sudo REF=<commit-sha> bash
```

### Installer options

| Variable | Effect |
|---|---|
| `REF` | branch, tag or commit to install from (default `main`) |
| `REPO` | `owner/name` to install from a fork |
| `INSTALL_DIR` | where to install (default `/opt/ayanakoji-proxy`) |
| `NONINTERACTIVE=1` | install only, do not open the setup menu |
| `SKIP_DEPS=1` | skip apt and Go setup, for re-runs |

The installer needs Go 1.21+. If the distro package is older it fetches the
official toolchain into `/usr/local/go`.

## Menu

```sh
sudo /opt/ayanakoji-proxy/menu.sh
```

* **[1] Complete Master Setup** — decoy site, proxy build, self-signed
  certificate, HAProxy 443 multiplexer. Asks for the SSH and V2Ray paths that
  HAProxy matches on.
* **[2] Configure transports** — add directly reachable CONNECT, payload or raw
  ports. See [USAGE.md](USAGE.md).
* **[3] Manage SSH users** — create tunnel-only (`nologin`) accounts with an
  expiry date, delete, list.
* **[4] View proxy logs**, **[5] Restart services**, **[99] Uninstall**.

## How traffic flows

```
client ──443/TLS──> HAProxy ──┬── /ssh path   ──> Go proxy :10080 ──> sshd :22
                              ├── /v2ray path ──> V2Ray :10086
                              └── anything else ─> decoy site :10081

client ──8888──────> Go proxy (HTTP CONNECT)  ──> sshd :22
client ──2053──────> Go proxy (custom payload)──> sshd :22
```

HAProxy inspects the first 100 bytes for the configured path, so a client whose
payload carries `/ssh` reaches the tunnel while a browser hitting the host sees
an ordinary website. Transports added from menu option 2 listen directly and do
not involve HAProxy.

## Layout

| File | Purpose |
|---|---|
| `install.sh` | installer, safe to re-run |
| `menu.sh` | main menu |
| `transport-setup.sh` | prompt-driven transport config, writes the systemd unit |
| `ayanakoji_proxy.go` | the proxy |
| `ssh-manager.sh` | tunnel user management |
| `uninstall.sh` | removal, asks for confirmation |

## Uninstall

```sh
sudo /opt/ayanakoji-proxy/uninstall.sh
```

Requires typing `yes`, asks separately before purging HAProxy, and leaves SSH
accounts alone.
