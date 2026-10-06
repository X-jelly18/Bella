# Ayanakoji — SSH over SSL/TLS

Direct SSH inside TLS for a Debian or Ubuntu VPS. A client opens a TLS
connection to the server and speaks SSH inside it immediately.

There is no HTTP request, no websocket upgrade and no payload: TLS is the only
wrapper, so to anything watching the connection it is an ordinary TLS session on
whichever port you choose.

## Install

```sh
curl -fsSL https://raw.githubusercontent.com/X-jelly18/Bella/main/vps/install.sh | sudo bash
```

Installs `openssl` and a Go toolchain, builds the proxy, and opens the setup
menu.

Piping a remote script into a root shell runs whatever that URL serves at that
moment. To read it first:

```sh
curl -fsSL -o install.sh https://raw.githubusercontent.com/X-jelly18/Bella/main/vps/install.sh
less install.sh
sudo bash install.sh
```

### Installer options

| Variable | Effect |
|---|---|
| `REF` | branch, tag or commit to install from (default `main`) |
| `REPO` | `owner/name` to install from a fork |
| `INSTALL_DIR` | install location (default `/opt/ayanakoji-proxy`) |
| `NONINTERACTIVE=1` | install only, do not open the menu |
| `SKIP_DEPS=1` | skip apt and Go setup, for re-runs |

Needs Go 1.21+. If the distro package is older, the official toolchain is
fetched into `/usr/local/go`.

## Setup

```sh
sudo /opt/ayanakoji-proxy/menu.sh
```

Option **[1]** asks for the TLS port (default 443), whether to generate a
self-signed certificate or use an existing one, and the SSH backend, then writes
and starts the systemd service.

* **Self-signed** works with tunnel clients that skip verification, which is
  most of them.
* **Existing certificate** takes a Let's Encrypt `fullchain.pem` / `privkey.pem`
  pair, for clients that do verify. Certbot renewal needs a reload hook:

  ```sh
  echo 'systemctl restart ayanakoji-proxy' | sudo tee /etc/letsencrypt/renewal-hooks/deploy/ayanakoji.sh
  sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/ayanakoji.sh
  ```

The other options manage SSH users, tail logs, restart the service, show the
certificate, and uninstall.

## Connecting

In a tunnel app: host is the server, port is what you chose, mode is **SSH +
SSL/TLS** (sometimes called *direct SSL* or *stunnel*). No payload or custom
host field is used.

From OpenSSH, wrapping the connection in TLS yourself:

```sh
ssh -o ProxyCommand='openssl s_client -quiet -verify_quiet -connect %h:443' user@your-server
```

Or with stunnel on the client, pointing a local port at the server's TLS port
and then `ssh -p <local-port> user@127.0.0.1`.

## How it works

```
client ──TLS──> ayanakoji_proxy :443 ──plain TCP──> sshd 127.0.0.1:22
```

The proxy terminates TLS, dials sshd, and copies bytes in both directions. It
never parses or rewrites the stream.

## Proxy flags

```
-listen                  comma-separated TLS ports (default 443)
-cert, -key              TLS certificate chain and private key (required)
-host                    bind address (default 0.0.0.0)
-ssh-host, -ssh-port     backend (default 127.0.0.1:22)
-connect-timeout-secs    backend dial timeout (default 5)
-handshake-timeout-secs  TLS handshake budget per client (default 10)
-max-conns               concurrent tunnel cap (0 = unlimited)
-shutdown-grace-secs     drain window on SIGTERM (default 10)
```

TLS 1.2 is the floor; older clients are refused.

## Hardening worth doing

Once tunnels work, sshd no longer needs to be reachable from the internet. Bind
it to localhost in `/etc/ssh/sshd_config`:

```
ListenAddress 127.0.0.1
```

and drop inbound port 22 at the firewall. The proxy reaches sshd over loopback,
so tunnel clients are unaffected while direct SSH scanning stops.

Tunnel accounts created from the menu get `/usr/sbin/nologin` and an expiry
date, so a leaked password grants a tunnel rather than a shell.

## Uninstall

```sh
sudo /opt/ayanakoji-proxy/uninstall.sh
```

Requires typing `yes`, asks separately before deleting certificates, and leaves
SSH accounts and sshd alone.
