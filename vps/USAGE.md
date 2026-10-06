# ayanakoji_proxy — transport modes

Run `sudo ./transport-setup.sh` to pick your transports through prompts; it
writes the systemd unit for you. Pass `--dry-run` to preview the unit without
touching anything. The flag reference below is what it generates.

Each port is configured independently with `-listen PORTS:MODE[:tls]`, repeatable.

| Mode      | Client sends                   | Server replies                            | Use for |
|-----------|--------------------------------|-------------------------------------------|---------|
| `connect` | `CONNECT host:port HTTP/1.1`   | `HTTP/1.1 200 Connection established`     | HTTP-proxy clients, SSH `ProxyCommand`, "HTTP proxy" app mode |
| `payload` | any HTTP-ish request head      | `HTTP/1.1 200 OK` (`-payload-status`)     | custom payload on a custom port |
| `direct`  | nothing — raw SSH immediately  | nothing                                   | plain SSH / stunnel front end |
| `ws`      | HTTP head with Upgrade         | `HTTP/1.1 101 …` (`-ws-status`)           | existing websocket clients (unchanged default) |
| `auto`    | any of the above               | sniffs the first bytes and matches        | one port serving mixed clients |

`auto` detection: `CONNECT ` prefix → connect; `SSH-` prefix → direct; an
`Upgrade: websocket` header → ws; anything else → payload.

## Examples

HTTP CONNECT proxy on 8888, custom payload on 2053, websocket kept on 10080:

    ayanakoji_proxy \
      -listen 10080:ws \
      -listen 8888:connect \
      -listen 2053:payload \
      -ssh-host 127.0.0.1 -ssh-port 22

One TLS port that accepts every client type:

    ayanakoji_proxy -listen 443:auto:tls \
      -cert /etc/haproxy/certs/cert.pem -key /etc/haproxy/certs/key.pem

Reply with nothing at all (some payload clients expect silence):

    ayanakoji_proxy -listen 2053:payload -payload-status ""

Only accept clients whose payload carries a tag, so port scanners are dropped:

    ayanakoji_proxy -listen 2053:payload -payload-match "X-Tunnel-Key: s3cret"

## Connecting

HTTP CONNECT mode, straight from OpenSSH:

    ssh -o ProxyCommand='socat - PROXY:VPS_IP:127.0.0.1:22,proxyport=8888' user@VPS_IP

Direct mode needs no handshake:

    ssh -p 1194 user@VPS_IP

## Notes

* `-ports` and `-tls-ports` still work and mean `ws` mode, so the existing
  systemd unit needs no change.
* In `connect` mode the host:port the client asks for is **ignored** — every
  tunnel goes to `-ssh-host`/`-ssh-port`. Honouring arbitrary targets would make
  this an open relay and get the VPS IP blocklisted.
* `-max-conns` caps concurrent tunnels (0 = unlimited). `-handshake-timeout-secs`
  bounds the handshake only; established tunnels have no idle deadline.

## Other flags

    -host                      bind address (default 0.0.0.0)
    -ssh-host, -ssh-port       backend (default 127.0.0.1:22)
    -connect-timeout-secs      backend dial timeout (default 5)
    -handshake-timeout-secs    client handshake budget (default 10)
    -shutdown-grace-secs       tunnel drain window on SIGTERM (default 10)
    -cert, -key                TLS key pair, required by any :tls listener

## transport-setup.sh

Prompt-driven configuration, styled like `menu.sh`:

    sudo ./transport-setup.sh             # configure and restart the service
    ./transport-setup.sh --dry-run        # print the unit, change nothing

* `[1]`–`[5]` add a listener of each mode, asking for the port and whether to
  wrap it in TLS.
* `[p]` loads a preset: websocket on 10080, CONNECT on 8888, payload on 2053.
* `[r]` removes a listener, `[d]` reviews and saves, `[q]` exits without saving.

It rejects out-of-range ports and ports already assigned to another listener,
warns when a port is already bound on the host, shows the exact resulting command
for review before writing, and generates a hardened unit (`NoNewPrivileges`,
`ProtectSystem=strict`, `After=network-online.target`, `RestartSec=2`).

Override the paths for testing:

    INSTALL_DIR=/tmp/x SERVICE_FILE=/tmp/x.service ./transport-setup.sh --dry-run
