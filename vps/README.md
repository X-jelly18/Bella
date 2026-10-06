# Ayanakoji SSH tunnel

SSH tunnelling for a Debian or Ubuntu VPS. One Go proxy accepts tunnel clients,
completes whatever handshake they expect, and relays the stream to local sshd.

Each port is configured independently, so one server can serve several client
types at once:

| Mode | Client sends | Server replies |
|---|---|---|
| `direct` | nothing — raw SSH straight away | nothing |
| `connect` | `CONNECT host:port HTTP/1.1` | `200 Connection established` |
| `payload` | any HTTP request head | configurable status line, or nothing |
| `auto` | any of the above | sniffs the first bytes and matches |

Adding `:tls` terminates TLS on that port, and the handshake then happens
**inside** the TLS session. That composition is what tunnel clients call
*SSL + payload* or *SSL + proxy*:

```
443:direct:tls    SSH + SSL/TLS
8888:connect      HTTP proxy
2053:payload      payload over plain TCP
8443:auto:tls     payload, proxy or raw SSH, all inside TLS
```

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

Option **[1]** builds the listener list through prompts — pick a mode, give it a
port, say whether to wrap it in TLS — then asks for the certificate and SSH
backend, shows the resulting command, and writes the systemd unit. `[p]` loads a
preset of TLS on 443, proxy on 8888 and payload on 2053.

Certificates are either generated self-signed (most tunnel clients skip
verification) or taken from an existing pair. Certbot renewal needs a hook:

```sh
echo 'systemctl restart ayanakoji-proxy' | sudo tee /etc/letsencrypt/renewal-hooks/deploy/ayanakoji.sh
sudo chmod +x /etc/letsencrypt/renewal-hooks/deploy/ayanakoji.sh
```

## Connecting

In a tunnel app, pick the mode matching the port:

* **SSH + SSL/TLS** → a `direct:tls` port
* **SSH + Payload** → a `payload` port, with your payload in the client
* **SSH + HTTP Proxy** → a `connect` port as the client's proxy host and port
* **SSL + payload / SSL + proxy** → an `auto:tls` port

From OpenSSH against a `direct:tls` port:

```sh
ssh -o ProxyCommand='openssl s_client -quiet -verify_quiet -connect %h:443' user@your-server
```

Against a `connect` port, using an HTTP proxy directly:

```sh
ssh -o ProxyCommand='socat - PROXY:your-server:127.0.0.1:22,proxyport=8888' user@your-server
```

### Payload notes

`-payload-status` sets the reply (`200 OK` by default; empty replies nothing).
`-payload-match` requires a substring in the request head, which quietly drops
port scanners.

If your client sends a **split payload** — two request blocks rather than one —
set `-payload-extra-heads 1`. Without it the second block is forwarded to sshd
as protocol garbage and the connection fails.

## Proxy flags

```
-listen                  PORTS:MODE[:tls], repeatable (default 443:direct:tls)
-cert, -key              certificate chain and key, required by any :tls listener
-host                    bind address (default 0.0.0.0)
-ssh-host, -ssh-port     backend (default 127.0.0.1:22)
-connect-timeout-secs    backend dial timeout (default 5)
-handshake-timeout-secs  per-client handshake budget (default 10)
-payload-status          payload reply status line (default "200 OK")
-payload-match           required substring in a payload request head
-payload-extra-heads     extra request blocks to consume (default 0)
-max-conns               concurrent tunnel cap (0 = unlimited)
-shutdown-grace-secs     drain window on SIGTERM (default 10)
```

A bare port list (`-listen 443`) means `direct:tls`, so units written for the
TLS-only version keep working. TLS 1.2 is the floor.

In `connect` mode the host:port the client asks for is **ignored** — every
tunnel goes to the configured SSH backend. Honouring arbitrary targets would
make this an open relay and get the server's address blocklisted.

## Hardening worth doing

Once tunnels work, sshd no longer needs to be reachable from the internet. Set
`ListenAddress 127.0.0.1` in `/etc/ssh/sshd_config` and drop inbound 22 at the
firewall; the proxy reaches sshd over loopback, so clients are unaffected.

Tunnel accounts created from the menu get `/usr/sbin/nologin` and an expiry
date, so a leaked password grants a tunnel rather than a shell.

## Uninstall

```sh
sudo /opt/ayanakoji-proxy/uninstall.sh
```

Requires typing `yes`, asks separately before deleting certificates, and leaves
SSH accounts and sshd alone.
