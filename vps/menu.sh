#!/bin/bash
set -u
C_RESET='\033[0m'; C_BOLD='\033[1m'; C_DIM='\033[2m'
C_RED='\033[31m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'; C_CYAN='\033[36m'; C_PURPLE='\033[35m'
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${INSTALL_DIR:-/opt/ayanakoji-proxy}"
SERVICE_FILE="${SERVICE_FILE:-/etc/systemd/system/ayanakoji-proxy.service}"
DUMMY_DIR="${DUMMY_DIR:-/var/www/dummy}"
CERT_DIR="${CERT_DIR:-/etc/haproxy/certs}"
CERT_PEM="$CERT_DIR/ayanakoji.pem"

[ "$(id -u)" -eq 0 ] || { echo -e "${C_RED}Run as root (sudo menu.sh)${C_RESET}"; exit 1; }

setup_all() {
    clear; echo -e "${C_BOLD}${C_PURPLE}=== Complete Master Setup ===${C_RESET}\n"
    read -rp "👉 Enter path for SSH Tunnel [default: /ssh]: " SSH_PATH; SSH_PATH=${SSH_PATH:-/ssh}
    read -rp "👉 Enter path for V2Ray [default: /v2ray]: " V2RAY_PATH; V2RAY_PATH=${V2RAY_PATH:-/v2ray}
    read -rp "👉 Enter a website to clone (e.g. example.com) [Enter for random]: " DUMMY_SITE

    mkdir -p "$DUMMY_DIR"
    if [ -z "$DUMMY_SITE" ]; then
        SITES=("example.com" "gnu.org" "neverssl.com"); DUMMY_SITE=${SITES[$RANDOM % ${#SITES[@]}]}
    fi
    wget -qO "$DUMMY_DIR/index.html" "http://$DUMMY_SITE" \
        || echo "<h1>System Maintenance</h1>" > "$DUMMY_DIR/index.html"

    cat > /etc/systemd/system/ayanakoji-dummy.service <<UNIT
[Unit]
Description=Ayanakoji Dummy Website
After=network-online.target
Wants=network-online.target

[Service]
User=nobody
WorkingDirectory=$DUMMY_DIR
ExecStart=/usr/bin/python3 -m http.server 10081 --bind 127.0.0.1
Restart=always
RestartSec=2
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=true

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable ayanakoji-dummy --now > /dev/null 2>&1
    echo -e "${C_GREEN}  ✓ dummy site serving $DUMMY_SITE on 127.0.0.1:10081${C_RESET}"

    echo -e "\n${C_BOLD}Building the Go proxy...${C_RESET}"
    cd "$SCRIPT_DIR" || return 1
    export PATH="/usr/local/go/bin:$PATH"
    if ! GOFLAGS=-mod=mod GOCACHE=/tmp/ayanakoji-gocache \
        go build -ldflags "-s -w" -o "$INSTALL_DIR/ayanakoji_proxy" . ; then
        echo -e "${C_RED}  ✗ build failed${C_RESET}"; read -rp "Press Enter..." _; return 1
    fi
    chmod +x "$INSTALL_DIR/ayanakoji_proxy"
    echo -e "${C_GREEN}  ✓ built${C_RESET}"

    # Internal ws listener that HAProxy routes to. Extra, directly reachable
    # ports (CONNECT, payload, direct) are added from menu option 2.
    cat > "$SERVICE_FILE" <<UNIT
[Unit]
Description=Ayanakoji Go Proxy Backend
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$INSTALL_DIR/ayanakoji_proxy "-host" "127.0.0.1" "-listen" "10080:auto" "-ssh-host" "127.0.0.1" "-ssh-port" "22"
Restart=always
RestartSec=2
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only

[Install]
WantedBy=multi-user.target
UNIT
    systemctl daemon-reload
    systemctl enable ayanakoji-proxy.service > /dev/null 2>&1
    systemctl restart ayanakoji-proxy.service
    echo -e "${C_GREEN}  ✓ ayanakoji-proxy running on 127.0.0.1:10080 (auto-detect)${C_RESET}"

    echo -e "\n${C_BOLD}Configuring SSL and HAProxy...${C_RESET}"
    mkdir -p "$CERT_DIR"
    if [ ! -f "$CERT_PEM" ]; then
        # The key and certificate MUST be written to separate files and then
        # concatenated. Passing the same path to -keyout and -out makes the
        # certificate truncate the file the key was just written to, leaving a
        # PEM with no private key that HAProxy refuses to load.
        openssl req -x509 -newkey rsa:2048 -nodes \
            -keyout "$CERT_DIR/ayanakoji.key" \
            -out "$CERT_DIR/ayanakoji.crt" \
            -days 3650 -subj "/CN=ayanakoji" > /dev/null 2>&1
        cat "$CERT_DIR/ayanakoji.key" "$CERT_DIR/ayanakoji.crt" > "$CERT_PEM"
        rm -f "$CERT_DIR/ayanakoji.key" "$CERT_DIR/ayanakoji.crt"
        chmod 600 "$CERT_PEM"
        echo -e "${C_GREEN}  ✓ self-signed certificate at $CERT_PEM${C_RESET}"
    else
        echo -e "${C_DIM}  • keeping existing $CERT_PEM${C_RESET}"
    fi

    cat > /etc/haproxy/haproxy.cfg <<CFG
global
    log /dev/log local0
    daemon
    maxconn 100000
defaults
    mode tcp
    option tcplog
    log global
    timeout connect 5s
    timeout client  1h
    timeout server  1h
frontend multiplexer_443
    bind *:443 ssl crt $CERT_PEM
    mode tcp
    tcp-request inspect-delay 5s
    acl is_ssh req.payload(0,100) -m sub $SSH_PATH
    acl is_v2ray req.payload(0,100) -m sub $V2RAY_PATH
    tcp-request content accept if is_ssh
    tcp-request content accept if is_v2ray
    use_backend ssh_backend if is_ssh
    use_backend v2ray_backend if is_v2ray
    default_backend dummy_backend
backend ssh_backend
    server local_go_proxy 127.0.0.1:10080
backend v2ray_backend
    server local_v2ray 127.0.0.1:10086
backend dummy_backend
    server local_dummy 127.0.0.1:10081
CFG

    if ! haproxy -c -f /etc/haproxy/haproxy.cfg > /tmp/ayanakoji-haproxy.log 2>&1; then
        echo -e "${C_RED}  ✗ HAProxy config is invalid:${C_RESET}"
        sed 's/^/    /' /tmp/ayanakoji-haproxy.log
        read -rp "Press Enter..." _; return 1
    fi
    systemctl enable haproxy > /dev/null 2>&1
    systemctl restart haproxy
    echo -e "${C_GREEN}  ✓ HAProxy listening on :443${C_RESET}"

    echo -e "\n${C_BOLD}${C_GREEN}Setup complete.${C_RESET}"
    echo -e "${C_DIM}  SSH path: $SSH_PATH    V2Ray path: $V2RAY_PATH${C_RESET}"
    echo; read -rp "Press Enter to continue..." _
}

service_status() {
    local s
    for s in ayanakoji-proxy ayanakoji-dummy haproxy; do
        if systemctl is-active --quiet "$s" 2>/dev/null; then
            echo -e "  ${C_GREEN}●${C_RESET} $s"
        else
            echo -e "  ${C_RED}○${C_RESET} $s ${C_DIM}(stopped)${C_RESET}"
        fi
    done
}

while true; do
    clear
    echo -e "${C_BOLD}${C_PURPLE}=== Ayanakoji Master Edition ===${C_RESET}\n"
    service_status
    echo
    echo -e "  ${C_GREEN}[1]${C_RESET} Run Complete Master Setup"
    echo -e "  ${C_CYAN}[2]${C_RESET} Configure transports ${C_DIM}(CONNECT / payload / direct ports)${C_RESET}"
    echo -e "  ${C_GREEN}[3]${C_RESET} Manage SSH Users"
    echo -e "  ${C_GREEN}[4]${C_RESET} View Proxy Logs"
    echo -e "  ${C_GREEN}[5]${C_RESET} Restart Services"
    echo -e "  ${C_RED}[99] FULL UNINSTALL${C_RESET}"
    echo -e "  ${C_YELLOW}[0]${C_RESET} Exit"
    echo
    read -rp "👉 Choice: " choice
    case "$choice" in
        1) setup_all ;;
        2) bash "$SCRIPT_DIR/transport-setup.sh" ;;
        3) bash "$SCRIPT_DIR/ssh-manager.sh" ;;
        4) journalctl -u ayanakoji-proxy -n 50 -f ;;
        5) systemctl restart ayanakoji-proxy ayanakoji-dummy haproxy 2>&1 | sed 's/^/  /'
           echo -e "${C_GREEN}  ✓ restarted${C_RESET}"; read -rp "Press Enter..." _ ;;
        99) bash "$SCRIPT_DIR/uninstall.sh"; exit 0 ;;
        0) exit 0 ;;
        *) sleep 1 ;;
    esac
done
