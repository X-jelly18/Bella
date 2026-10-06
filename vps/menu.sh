#!/bin/bash
# SSH-over-TLS setup and management.
set -u

C_RESET='\033[0m'; C_BOLD='\033[1m'; C_DIM='\033[2m'
C_RED='\033[31m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'; C_CYAN='\033[36m'; C_PURPLE='\033[35m'

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
INSTALL_DIR="${INSTALL_DIR:-/opt/ayanakoji-proxy}"
SERVICE_FILE="${SERVICE_FILE:-/etc/systemd/system/ayanakoji-proxy.service}"
SERVICE_NAME="$(basename "$SERVICE_FILE" .service)"
CERT_DIR="${CERT_DIR:-/etc/ayanakoji}"
BIN="$INSTALL_DIR/ayanakoji_proxy"

[ "$(id -u)" -eq 0 ] || { echo -e "${C_RED}Run as root (sudo menu.sh)${C_RESET}"; exit 1; }

ask() {
    local __ask_var="$1" __ask_prompt="$2" __ask_default="${3:-}" __ask_reply=""
    if [ -n "$__ask_default" ]; then
        read -rp "$(echo -e "👉 ${__ask_prompt} ${C_DIM}[${__ask_default}]${C_RESET}: ")" __ask_reply
    else
        read -rp "$(echo -e "👉 ${__ask_prompt}: ")" __ask_reply
    fi
    printf -v "$__ask_var" '%s' "${__ask_reply:-$__ask_default}"
}

ask_yn() {
    local __p="$1" __d="${2:-n}" __r="" __hint
    [ "$__d" = "y" ] && __hint="Y/n" || __hint="y/N"
    while true; do
        read -rp "$(echo -e "👉 ${__p} ${C_DIM}[${__hint}]${C_RESET}: ")" __r
        case "${__r:-$__d}" in
            y | Y | yes) return 0 ;;
            n | N | no) return 1 ;;
            *) echo -e "${C_RED}  ✗ Answer y or n.${C_RESET}" ;;
        esac
    done
}

valid_ports() {
    local p
    for p in ${1//,/ }; do
        [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || return 1
    done
    [ -n "$1" ]
}

make_self_signed() {
    local cn="$1"
    mkdir -p "$CERT_DIR"
    # The key and certificate must go to separate files. Passing one path to
    # both -keyout and -out makes the certificate truncate the key.
    openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$CERT_DIR/key.pem" -out "$CERT_DIR/cert.pem" \
        -days 3650 -subj "/CN=$cn" > /dev/null 2>&1 || return 1
    chmod 600 "$CERT_DIR/key.pem"
    chmod 644 "$CERT_DIR/cert.pem"
    CERT="$CERT_DIR/cert.pem"
    KEY="$CERT_DIR/key.pem"
}

setup() {
    clear
    echo -e "${C_BOLD}${C_PURPLE}=== SSH over SSL/TLS — setup ===${C_RESET}"
    echo -e "${C_DIM}Clients open a TLS connection and speak SSH inside it. No HTTP,"
    echo -e "no websocket, no payload.${C_RESET}\n"

    local PORTS SSH_HOST SSH_PORT MAX_CONNS CN
    CERT=""; KEY=""

    while true; do
        ask PORTS "TLS port(s), comma-separated" "443"
        valid_ports "$PORTS" && break
        echo -e "${C_RED}  ✗ Ports must be numbers from 1 to 65535.${C_RESET}"
    done

    echo
    echo -e "  ${C_GREEN}[1]${C_RESET} Generate a self-signed certificate ${C_DIM}(works with most tunnel clients)${C_RESET}"
    echo -e "  ${C_GREEN}[2]${C_RESET} Use an existing certificate ${C_DIM}(Let's Encrypt, or your own)${C_RESET}"
    echo
    local certchoice
    ask certchoice "Certificate" "1"

    if [ "$certchoice" = "2" ]; then
        while true; do
            ask CERT "Certificate (fullchain) path" "/etc/letsencrypt/live/example.com/fullchain.pem"
            ask KEY "Private key path" "/etc/letsencrypt/live/example.com/privkey.pem"
            if [ -f "$CERT" ] && [ -f "$KEY" ]; then break; fi
            echo -e "${C_RED}  ✗ Both files must exist. Not found:${C_RESET}"
            [ -f "$CERT" ] || echo -e "${C_RED}      $CERT${C_RESET}"
            [ -f "$KEY" ] || echo -e "${C_RED}      $KEY${C_RESET}"
            ask_yn "  Try again" "y" || return 1
        done
    else
        ask CN "Common name for the certificate" "$(hostname -f 2>/dev/null || hostname)"
        if ! make_self_signed "$CN"; then
            echo -e "${C_RED}  ✗ Could not generate the certificate.${C_RESET}"
            read -rp "Press Enter..." _; return 1
        fi
        echo -e "${C_GREEN}  ✓ self-signed certificate in $CERT_DIR${C_RESET}"
    fi

    echo
    ask SSH_HOST "SSH backend host" "127.0.0.1"
    ask SSH_PORT "SSH backend port" "22"
    MAX_CONNS="0"
    if ask_yn "Cap concurrent tunnels" "n"; then
        ask MAX_CONNS "Maximum concurrent tunnels" "2000"
    fi

    local args="\"-listen\" \"$PORTS\" \"-cert\" \"$CERT\" \"-key\" \"$KEY\""
    args="$args \"-ssh-host\" \"$SSH_HOST\" \"-ssh-port\" \"$SSH_PORT\""
    [ "$MAX_CONNS" != "0" ] && args="$args \"-max-conns\" \"$MAX_CONNS\""

    echo
    echo -e "${C_BOLD}${C_PURPLE}=== Review ===${C_RESET}\n"
    echo -e "  ${C_BOLD}Listening:${C_RESET}  TLS on $PORTS"
    echo -e "  ${C_BOLD}Backend:${C_RESET}    $SSH_HOST:$SSH_PORT"
    echo -e "  ${C_BOLD}Certificate:${C_RESET} $CERT"
    echo -e "  ${C_BOLD}Key:${C_RESET}        $KEY"
    [ "$MAX_CONNS" != "0" ] && echo -e "  ${C_BOLD}Max tunnels:${C_RESET} $MAX_CONNS"
    echo -e "\n  ${C_DIM}$BIN $(echo "$args" | tr -d '"')${C_RESET}\n"

    ask_yn "Write the service and start it" "y" || { echo -e "\n${C_YELLOW}Nothing changed.${C_RESET}"; read -rp "Press Enter..." _; return 0; }

    cat > "$SERVICE_FILE" <<UNIT
[Unit]
Description=Ayanakoji SSH-over-TLS proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN $args
Restart=always
RestartSec=2
LimitNOFILE=1048576

# The proxy only reads its certificate and opens sockets.
NoNewPrivileges=true
PrivateTmp=true
ProtectSystem=strict
ProtectHome=read-only
ProtectKernelTunables=true
ProtectControlGroups=true
RestrictSUIDSGID=true
ReadOnlyPaths=$CERT_DIR

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" > /dev/null 2>&1
    if systemctl restart "$SERVICE_NAME"; then
        echo -e "\n${C_GREEN}${C_BOLD}  ✓ $SERVICE_NAME is running.${C_RESET}"
        local first_port="${PORTS%%,*}"
        echo -e "\n${C_BOLD}Connect from a client:${C_RESET}"
        echo -e "${C_DIM}  Tunnel apps: host = this server, port = $first_port, mode = SSH + SSL/TLS (direct)${C_RESET}"
        echo -e "${C_DIM}  OpenSSH via stunnel/socat:${C_RESET}"
        echo -e "${C_DIM}    ssh -o ProxyCommand='openssl s_client -quiet -verify_quiet -connect %h:$first_port' user@this-server${C_RESET}"
    else
        echo -e "\n${C_RED}  ✗ Failed to start. journalctl -u $SERVICE_NAME -n 30${C_RESET}"
    fi
    echo; read -rp "Press Enter to continue..." _
}

status_line() {
    if systemctl is-active --quiet "$SERVICE_NAME" 2> /dev/null; then
        echo -e "  ${C_GREEN}●${C_RESET} $SERVICE_NAME  ${C_DIM}$(systemctl show -p ExecStart --value "$SERVICE_NAME" 2>/dev/null | grep -o '\-listen[^-]*' | head -1)${C_RESET}"
    elif [ -f "$SERVICE_FILE" ]; then
        echo -e "  ${C_RED}○${C_RESET} $SERVICE_NAME ${C_DIM}(configured but stopped)${C_RESET}"
    else
        echo -e "  ${C_YELLOW}○${C_RESET} $SERVICE_NAME ${C_DIM}(not configured — run setup)${C_RESET}"
    fi
}

while true; do
    clear
    echo -e "${C_BOLD}${C_PURPLE}=== Ayanakoji — SSH over SSL/TLS ===${C_RESET}\n"
    status_line
    echo
    echo -e "  ${C_GREEN}[1]${C_RESET} Setup / reconfigure"
    echo -e "  ${C_GREEN}[2]${C_RESET} Manage SSH users"
    echo -e "  ${C_GREEN}[3]${C_RESET} View logs"
    echo -e "  ${C_GREEN}[4]${C_RESET} Restart service"
    echo -e "  ${C_CYAN}[5]${C_RESET} Show certificate details"
    echo -e "  ${C_RED}[99] Uninstall${C_RESET}"
    echo -e "  ${C_YELLOW}[0]${C_RESET} Exit"
    echo
    read -rp "$(echo -e "👉 Choice: ")" choice
    case "$choice" in
        1) setup ;;
        2) bash "$SCRIPT_DIR/ssh-manager.sh" ;;
        3) journalctl -u "$SERVICE_NAME" -n 50 -f ;;
        4) systemctl restart "$SERVICE_NAME" && echo -e "${C_GREEN}  ✓ restarted${C_RESET}" \
               || echo -e "${C_RED}  ✗ failed${C_RESET}"; read -rp "Press Enter..." _ ;;
        5) echo
           if [ -f "$CERT_DIR/cert.pem" ]; then
               openssl x509 -in "$CERT_DIR/cert.pem" -noout -subject -issuer -dates 2>&1 | sed 's/^/  /'
           else
               echo -e "  ${C_DIM}No certificate at $CERT_DIR/cert.pem${C_RESET}"
           fi
           echo; read -rp "Press Enter..." _ ;;
        99) bash "$SCRIPT_DIR/uninstall.sh"; exit 0 ;;
        0) exit 0 ;;
        *) sleep 1 ;;
    esac
done
