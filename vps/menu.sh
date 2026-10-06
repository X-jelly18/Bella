#!/bin/bash
# SSH tunnel setup and management.
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

# Internals are prefixed per function: a bare `local __reply` would shadow a
# caller's variable of the same name and printf -v would write to the wrong scope.
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
    local __yn_p="$1" __yn_d="${2:-n}" __yn_r="" __yn_hint
    [ "$__yn_d" = "y" ] && __yn_hint="Y/n" || __yn_hint="y/N"
    while true; do
        read -rp "$(echo -e "👉 ${__yn_p} ${C_DIM}[${__yn_hint}]${C_RESET}: ")" __yn_r \
            || { [ "$__yn_d" = "y" ] && return 0 || return 1; }
        case "${__yn_r:-$__yn_d}" in
            y | Y | yes) return 0 ;;
            n | N | no) return 1 ;;
            *) echo -e "${C_RED}  ✗ Answer y or n.${C_RESET}" ;;
        esac
    done
}

L_PORT=(); L_MODE=(); L_TLS=()
CERT=""; KEY=""
DEFAULT_STATUS="200 <font color='red'>@Official_Kiyotaka</font>"
PAYLOAD_STATUS="$DEFAULT_STATUS"; PAYLOAD_MATCH=""; EXTRA_HEADS="0"; TUNNEL_PATH=""
PAYLOAD_ASKED=0
SSH_HOST="127.0.0.1"; SSH_PORT="22"; MAX_CONNS="0"

mode_label() {
    case "$1" in
        direct) echo "SSH + SSL/TLS" ;;
        connect) echo "We act as the HTTP proxy" ;;
        payload) echo "Payload sent to us" ;;
        auto) echo "Any of the above (auto)" ;;
    esac
}

port_taken() {
    local i
    for ((i = 0; i < ${#L_PORT[@]}; i++)); do
        [ "${L_PORT[i]}" = "$1" ] && return 0
    done
    return 1
}

ask_port() {
    local __p_var="$1" __p_default="$2" __p_reply=""
    while true; do
        ask __p_reply "Port" "$__p_default"
        if ! [[ "$__p_reply" =~ ^[0-9]+$ ]] || [ "$__p_reply" -lt 1 ] || [ "$__p_reply" -gt 65535 ]; then
            echo -e "${C_RED}  ✗ A port is a number from 1 to 65535.${C_RESET}"; continue
        fi
        if port_taken "$__p_reply"; then
            echo -e "${C_RED}  ✗ Port $__p_reply is already assigned here.${C_RESET}"; continue
        fi
        printf -v "$__p_var" '%s' "$__p_reply"
        return 0
    done
}

ask_payload_options() {
    [ "$PAYLOAD_ASKED" = "1" ] && return 0
    PAYLOAD_ASKED=1
    if ask_yn "Require a path in the client's request (like /ssh)" "y"; then
        while true; do
            ask TUNNEL_PATH "Path" "/ssh"
            case "$TUNNEL_PATH" in
                /*) break ;;
                *) echo -e "${C_RED}  ✗ A path must start with /${C_RESET}" ;;
            esac
        done
        echo -e "${C_DIM}    Requests to any other path get 404 Not Found.${C_RESET}"
    fi
    # Asked as a yes/no because an empty answer to `ask` takes the default, so
    # a blank status line would otherwise be unreachable.
    if ask_yn "Reply to payload clients with a status line" "y"; then
        ask PAYLOAD_STATUS "Status line" "$DEFAULT_STATUS"
    else
        PAYLOAD_STATUS=""
        echo -e "${C_GREEN}  ✓ payload clients get no reply at all${C_RESET}"
    fi
    if ask_yn "Require a secret tag in the payload (drops port scanners)" "n"; then
        ask PAYLOAD_MATCH "Required substring" "X-Tunnel-Key: change-me"
    fi
    if ask_yn "Does your client send a split payload (two request blocks)" "n"; then
        ask EXTRA_HEADS "Extra request blocks to consume" "1"
    fi
}

add_listener() {
    local m="$1" default_port="$2" force_tls="$3" tls_default="${4:-n}" port tls=0
    echo -e "\n${C_BOLD}${C_CYAN}$(mode_label "$m")${C_RESET}"
    case "$m" in
        direct) echo -e "  ${C_DIM}The client opens TLS and speaks SSH inside it. This is the mode that works${C_RESET}"
                echo -e "  ${C_DIM}when the client sends its payload to its OWN proxy: that proxy consumes${C_RESET}"
                echo -e "  ${C_DIM}the payload and CONNECT, and only TLS reaches us.${C_RESET}" ;;
        connect) echo -e "  ${C_DIM}The client points its app at US as the HTTP proxy and sends CONNECT here.${C_RESET}" ;;
        payload) echo -e "  ${C_DIM}The client sends its payload straight to US, with no proxy in between.${C_RESET}" ;;
        auto) echo -e "  ${C_DIM}Sniffs the first bytes: CONNECT, a payload, or raw SSH.${C_RESET}"
              echo -e "  ${C_YELLOW}  Note: a required path only gates payload requests. CONNECT and raw${C_RESET}"
              echo -e "  ${C_YELLOW}  SSH carry no path, so they reach the tunnel regardless. Use${C_RESET}"
              echo -e "  ${C_YELLOW}  \"Payload sent to us\" if the path must be mandatory.${C_RESET}" ;;
    esac

    ask_port port "$default_port"

    if [ "$force_tls" = "1" ]; then
        tls=1
        echo -e "  ${C_DIM}TLS: yes (this mode is TLS by definition)${C_RESET}"
    elif ask_yn "Wrap this port in SSL/TLS" "$tls_default"; then
        tls=1
    fi

    if [ "$tls" = "1" ] && [ -z "$CERT" ]; then
        choose_certificate || return 1
    fi
    case "$m" in payload | auto) ask_payload_options ;; esac

    L_PORT+=("$port"); L_MODE+=("$m"); L_TLS+=("$tls")
    echo -e "${C_GREEN}  ✓ added $(mode_label "$m") on port $port$([ "$tls" = "1" ] && echo " over TLS")${C_RESET}"
    if [ "$tls" = "1" ] && [ "$port" != "443" ]; then
        echo -e "${C_YELLOW}  ! Most ISP and corporate proxies only allow CONNECT to 443, and answer${C_RESET}"
        echo -e "${C_YELLOW}    403 for anything else. If clients reach this server through their own${C_RESET}"
        echo -e "${C_YELLOW}    proxy, add a TLS listener on 443 as well.${C_RESET}"
    fi
}

choose_certificate() {
    echo
    echo -e "  ${C_GREEN}[1]${C_RESET} Generate a self-signed certificate ${C_DIM}(most tunnel clients skip verification)${C_RESET}"
    echo -e "  ${C_GREEN}[2]${C_RESET} Use an existing certificate ${C_DIM}(Let's Encrypt, or your own)${C_RESET}"
    local choice cn
    ask choice "Certificate" "1"
    if [ "$choice" = "2" ]; then
        while true; do
            ask CERT "Certificate (fullchain) path" "/etc/letsencrypt/live/example.com/fullchain.pem"
            ask KEY "Private key path" "/etc/letsencrypt/live/example.com/privkey.pem"
            [ -f "$CERT" ] && [ -f "$KEY" ] && return 0
            echo -e "${C_RED}  ✗ Both files must exist.${C_RESET}"
            [ -f "$CERT" ] || echo -e "${C_RED}      missing: $CERT${C_RESET}"
            [ -f "$KEY" ] || echo -e "${C_RED}      missing: $KEY${C_RESET}"
            ask_yn "  Try again" "y" || { CERT=""; KEY=""; return 1; }
        done
    fi
    ask cn "Common name" "$(hostname -f 2> /dev/null || hostname)"
    mkdir -p "$CERT_DIR"
    # Key and certificate must go to separate files: one path for both -keyout
    # and -out makes the certificate truncate the key.
    if ! openssl req -x509 -newkey rsa:2048 -nodes \
        -keyout "$CERT_DIR/key.pem" -out "$CERT_DIR/cert.pem" \
        -days 3650 -subj "/CN=$cn" > /dev/null 2>&1; then
        echo -e "${C_RED}  ✗ Could not generate the certificate.${C_RESET}"
        return 1
    fi
    chmod 600 "$CERT_DIR/key.pem"; chmod 644 "$CERT_DIR/cert.pem"
    CERT="$CERT_DIR/cert.pem"; KEY="$CERT_DIR/key.pem"
    echo -e "${C_GREEN}  ✓ self-signed certificate in $CERT_DIR${C_RESET}"
}

show_listeners() {
    echo -e "${C_BOLD}Ways clients may connect:${C_RESET}"
    if [ "${#L_PORT[@]}" -eq 0 ]; then
        echo -e "  ${C_DIM}(none yet — add at least one)${C_RESET}"; return
    fi
    local i note
    for ((i = 0; i < ${#L_PORT[@]}; i++)); do
        [ "${L_TLS[i]}" = "1" ] && note=" ${C_CYAN}+SSL/TLS${C_RESET}" || note=""
        printf "  ${C_GREEN}%2d.${C_RESET} port ${C_BOLD}%-6s${C_RESET} %-26s%b\n" \
            "$((i + 1))" "${L_PORT[i]}" "$(mode_label "${L_MODE[i]}")" "$note"
    done
}

build_args() {
    local -n out="$1"
    out=(); local i spec
    for ((i = 0; i < ${#L_PORT[@]}; i++)); do
        spec="${L_PORT[i]}:${L_MODE[i]}"
        [ "${L_TLS[i]}" = "1" ] && spec="$spec:tls"
        out+=(-listen "$spec")
    done
    out+=(-ssh-host "$SSH_HOST" -ssh-port "$SSH_PORT")
    [ -n "$CERT" ] && out+=(-cert "$CERT" -key "$KEY")
    if needs_payload; then
        out+=(-payload-status "$PAYLOAD_STATUS")
        [ -n "$TUNNEL_PATH" ] && out+=(-path "$TUNNEL_PATH")
        [ -n "$PAYLOAD_MATCH" ] && out+=(-payload-match "$PAYLOAD_MATCH")
        [ "$EXTRA_HEADS" != "0" ] && out+=(-payload-extra-heads "$EXTRA_HEADS")
    fi
    [ "$MAX_CONNS" != "0" ] && out+=(-max-conns "$MAX_CONNS")
    return 0
}

needs_payload() {
    local i
    for ((i = 0; i < ${#L_MODE[@]}; i++)); do
        case "${L_MODE[i]}" in payload | auto) return 0 ;; esac
    done
    return 1
}

# systemd splits ExecStart on whitespace and expands %, so each argument is
# quoted with embedded quotes, backslashes and % escaped.
sd_quote() {
    local s="$1"; s="${s//\\/\\\\}"; s="${s//\"/\\\"}"; s="${s//%/%%}"
    printf '"%s"' "$s"
}

write_service() {
    local args=() quoted="" a
    build_args args
    for a in "${args[@]}"; do quoted="$quoted $(sd_quote "$a")"; done
    local ro=""
    [ -n "$CERT" ] && ro="ReadOnlyPaths=$(dirname "$CERT")"

    cat > "$SERVICE_FILE" <<UNIT
[Unit]
Description=Ayanakoji SSH tunnel proxy
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
ExecStart=$BIN$quoted
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
$ro

[Install]
WantedBy=multi-user.target
UNIT

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" > /dev/null 2>&1
    if systemctl restart "$SERVICE_NAME"; then
        echo -e "\n${C_GREEN}${C_BOLD}  ✓ $SERVICE_NAME is running.${C_RESET}"
        client_hints
    else
        echo -e "\n${C_RED}  ✗ Failed to start. journalctl -u $SERVICE_NAME -n 30${C_RESET}"
    fi
}

client_hints() {
    echo -e "\n${C_BOLD}In your tunnel client:${C_RESET}"
    local i
    for ((i = 0; i < ${#L_PORT[@]}; i++)); do
        local tlsnote=""
        [ "${L_TLS[i]}" = "1" ] && tlsnote=" + SSL/TLS"
        case "${L_MODE[i]}" in
            direct)  echo -e "  ${C_DIM}port ${L_PORT[i]}: mode \"SSH${tlsnote:- direct}\" — put your payload/proxy in the client${C_RESET}" ;;
            connect) echo -e "  ${C_DIM}port ${L_PORT[i]}: HTTP proxy = this host:${L_PORT[i]}${tlsnote}${C_RESET}" ;;
            payload) echo -e "  ${C_DIM}port ${L_PORT[i]}: send your payload to this host:${L_PORT[i]}${tlsnote}${TUNNEL_PATH:+, path $TUNNEL_PATH}${C_RESET}" ;;
            auto)    echo -e "  ${C_DIM}port ${L_PORT[i]}: payload, HTTP proxy or plain SSH all work${tlsnote}${C_RESET}" ;;
        esac
    done
}

setup() {
    L_PORT=(); L_MODE=(); L_TLS=(); CERT=""; KEY=""; PAYLOAD_ASKED=0
    PAYLOAD_STATUS="$DEFAULT_STATUS"; PAYLOAD_MATCH=""; EXTRA_HEADS="0"; MAX_CONNS="0"; TUNNEL_PATH=""

    while true; do
        clear
        echo -e "${C_BOLD}${C_PURPLE}=== Tunnel setup ===${C_RESET}\n"
        show_listeners
        echo
        echo -e "${C_DIM}  Where the payload goes decides the mode. If the client sends its payload${C_RESET}"
        echo -e "${C_DIM}  to its own proxy, that proxy eats it and we only ever see TLS -> pick [1].${C_RESET}\n"
        echo -e "  ${C_GREEN}[1]${C_RESET} SSH + SSL/TLS ${C_DIM}— works behind the client's own proxy/payload (usual choice)${C_RESET}"
        echo -e "  ${C_GREEN}[2]${C_RESET} We act as the HTTP proxy ${C_DIM}— client sends CONNECT to us${C_RESET}"
        echo -e "  ${C_GREEN}[3]${C_RESET} Payload sent to us ${C_DIM}— asks for a TLS port and a path${C_RESET}"
        echo -e "  ${C_GREEN}[4]${C_RESET} Accept any of the above ${C_DIM}(auto-detect)${C_RESET}"
        echo
        echo -e "  ${C_CYAN}[p]${C_RESET} Preset: TLS on 443 only ${C_DIM}(for clients using their own proxy)${C_RESET}"
        echo -e "  ${C_YELLOW}[r]${C_RESET} Remove a listener"
        echo -e "  ${C_BOLD}[d]${C_RESET} Done — review and save"
        echo -e "  ${C_RED}[q]${C_RESET} Cancel"
        echo
        local choice
        # A failed read means EOF or a closed stdin. Without this the default
        # branch below would loop forever instead of ending.
        read -rp "$(echo -e "👉 Choice: ")" choice \
            || { echo -e "\n${C_YELLOW}Input ended, nothing changed.${C_RESET}"; return 0; }
        case "${choice,,}" in
            1) add_listener direct 443 1 ;;
            2) add_listener connect 8888 0 n ;;
            3) add_listener payload 443 0 y ;;
            4) add_listener auto 443 0 y ;;
            p) L_PORT=(443); L_MODE=(direct); L_TLS=(1)
               choose_certificate \
                   && echo -e "${C_GREEN}  ✓ preset loaded: SSH + SSL/TLS on 443${C_RESET}" ;;
            r) if [ "${#L_PORT[@]}" -eq 0 ]; then echo -e "${C_YELLOW}  ! nothing to remove${C_RESET}"; else
                   local n; ask n "Number to remove" ""
                   if [[ "$n" =~ ^[0-9]+$ ]] && [ "$n" -ge 1 ] && [ "$n" -le "${#L_PORT[@]}" ]; then
                       local x=$((n - 1))
                       echo -e "${C_GREEN}  ✓ removed port ${L_PORT[x]}${C_RESET}"
                       L_PORT=("${L_PORT[@]:0:x}" "${L_PORT[@]:$((x + 1))}")
                       L_MODE=("${L_MODE[@]:0:x}" "${L_MODE[@]:$((x + 1))}")
                       L_TLS=("${L_TLS[@]:0:x}" "${L_TLS[@]:$((x + 1))}")
                   else echo -e "${C_RED}  ✗ no listener numbered '$n'${C_RESET}"; fi
               fi ;;
            d) if [ "${#L_PORT[@]}" -eq 0 ]; then
                   echo -e "${C_RED}  ✗ Add at least one listener first.${C_RESET}"; sleep 1.5; continue
               fi; break ;;
            q) echo -e "\n${C_YELLOW}Cancelled, nothing changed.${C_RESET}"; sleep 1; return 0 ;;
            *) continue ;;
        esac
        echo; read -rp "$(echo -e "${C_DIM}Press Enter to continue...${C_RESET}")" _
    done

    echo
    ask SSH_HOST "SSH backend host" "$SSH_HOST"
    ask SSH_PORT "SSH backend port" "$SSH_PORT"
    ask_yn "Cap concurrent tunnels" "n" && ask MAX_CONNS "Maximum concurrent tunnels" "2000"

    local args=() a
    build_args args
    echo -e "\n${C_BOLD}${C_PURPLE}=== Review ===${C_RESET}\n"
    show_listeners
    echo -e "\n  ${C_BOLD}Backend:${C_RESET}  $SSH_HOST:$SSH_PORT"
    [ -n "$CERT" ] && echo -e "  ${C_BOLD}Cert:${C_RESET}     $CERT"
    [ -n "$CERT" ] && echo -e "  ${C_BOLD}Key:${C_RESET}      $KEY"
    needs_payload && echo -e "  ${C_BOLD}Payload:${C_RESET}  reply \"${PAYLOAD_STATUS:-(nothing)}\"${PAYLOAD_MATCH:+, must contain \"$PAYLOAD_MATCH\"}"
    [ -n "$TUNNEL_PATH" ] && echo -e "  ${C_BOLD}Path:${C_RESET}     $TUNNEL_PATH ${C_DIM}(anything else gets 404)${C_RESET}"
    echo -e "\n  ${C_BOLD}Command:${C_RESET}"
    printf "${C_DIM}    %s" "$BIN"
    for a in "${args[@]}"; do
        case "$a" in -*) printf ' \\\n      %s' "$a" ;; *) printf ' %q' "$a" ;; esac
    done
    printf "${C_RESET}\n\n"

    if ask_yn "Write the service and start it" "y"; then
        write_service
    else
        echo -e "\n${C_YELLOW}Nothing changed.${C_RESET}"
    fi
    echo; read -rp "Press Enter to continue..." _
}

status_line() {
    if systemctl is-active --quiet "$SERVICE_NAME" 2> /dev/null; then
        echo -e "  ${C_GREEN}●${C_RESET} $SERVICE_NAME"
        systemctl show -p ExecStart --value "$SERVICE_NAME" 2> /dev/null \
            | grep -oE '\-listen" "[^"]+' | sed 's/-listen" "/    listening: /' | sed 's/^/  /'
    elif [ -f "$SERVICE_FILE" ]; then
        echo -e "  ${C_RED}○${C_RESET} $SERVICE_NAME ${C_DIM}(configured but stopped)${C_RESET}"
    else
        echo -e "  ${C_YELLOW}○${C_RESET} $SERVICE_NAME ${C_DIM}(not configured — run setup)${C_RESET}"
    fi
}

while true; do
    clear
    echo -e "${C_BOLD}${C_PURPLE}=== Ayanakoji SSH Tunnel ===${C_RESET}\n"
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
    read -rp "$(echo -e "👉 Choice: ")" choice || exit 0
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
