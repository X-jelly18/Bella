#!/bin/bash
# Interactive transport configuration for ayanakoji_proxy.
#
# Walks through the listeners you want, then writes the systemd unit. Paths can
# be overridden for testing:
#   INSTALL_DIR=/tmp/x SERVICE_FILE=/tmp/x.service ./transport-setup.sh --dry-run
set -u

C_RESET='\033[0m'; C_BOLD='\033[1m'; C_DIM='\033[2m'
C_RED='\033[31m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'; C_CYAN='\033[36m'; C_PURPLE='\033[35m'

INSTALL_DIR="${INSTALL_DIR:-/opt/ayanakoji-proxy}"
SERVICE_FILE="${SERVICE_FILE:-/etc/systemd/system/ayanakoji-proxy.service}"
SERVICE_NAME="$(basename "$SERVICE_FILE" .service)"
BIN="$INSTALL_DIR/ayanakoji_proxy"

DRY_RUN=0
[ "${1:-}" = "--dry-run" ] || [ "${1:-}" = "-n" ] && DRY_RUN=1

# Parallel arrays describing each configured listener.
L_PORT=(); L_MODE=(); L_TLS=()

SSH_HOST="127.0.0.1"; SSH_PORT="22"
CERT=""; KEY=""
WS_STATUS=""; PAYLOAD_STATUS=""; PAYLOAD_MATCH=""
PAYLOAD_ASKED=0; WS_ASKED=0
MAX_CONNS="0"; HANDSHAKE_TIMEOUT="10"

DEFAULT_WS_STATUS="101 <font color='red'><b>AYANAKOJIX!!!!</b></font>"

# ---------------------------------------------------------------- helpers ---

say()  { echo -e "$*"; }
warn() { echo -e "${C_YELLOW}  ! $*${C_RESET}"; }
err()  { echo -e "${C_RED}  ✗ $*${C_RESET}"; }
ok()   { echo -e "${C_GREEN}  ✓ $*${C_RESET}"; }

# ask VAR_NAME "prompt" "default"
#
# Internals are prefixed __ask_ because `local` here would otherwise shadow a
# caller variable of the same name and printf -v would write to the wrong scope.
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
    local __yn_prompt="$1" __yn_default="${2:-n}" __yn_reply="" __yn_hint
    [ "$__yn_default" = "y" ] && __yn_hint="Y/n" || __yn_hint="y/N"
    while true; do
        read -rp "$(echo -e "👉 ${__yn_prompt} ${C_DIM}[${__yn_hint}]${C_RESET}: ")" __yn_reply
        __yn_reply="${__yn_reply:-$__yn_default}"
        case "${__yn_reply,,}" in
            y | yes) return 0 ;;
            n | no) return 1 ;;
            *) err "Answer y or n." ;;
        esac
    done
}

port_in_use() {
    command -v ss > /dev/null 2>&1 || return 1
    ss -ltn 2>/dev/null | awk '{print $4}' | grep -qE "[:.]$1\$"
}

port_already_configured() {
    local p="$1" i
    for ((i = 0; i < ${#L_PORT[@]}; i++)); do
        [ "${L_PORT[i]}" = "$p" ] && return 0
    done
    return 1
}

# Reads a valid, unclaimed port into the named variable.
ask_port() {
    local __port_var="$1" __port_default="$2" __port_reply=""
    while true; do
        ask __port_reply "Port" "$__port_default"
        if ! [[ "$__port_reply" =~ ^[0-9]+$ ]] || [ "$__port_reply" -lt 1 ] || [ "$__port_reply" -gt 65535 ]; then
            err "A port is a number from 1 to 65535."
            continue
        fi
        if port_already_configured "$__port_reply"; then
            err "Port $__port_reply is already assigned to another listener here."
            continue
        fi
        if port_in_use "$__port_reply"; then
            warn "Port $__port_reply is already bound on this host (HAProxy? sshd?)."
            ask_yn "   Use it anyway" "n" || continue
        fi
        printf -v "$__port_var" '%s' "$__port_reply"
        return 0
    done
}

mode_label() {
    case "$1" in
        connect) echo "HTTP CONNECT proxy" ;;
        payload) echo "Custom payload" ;;
        direct)  echo "Direct / raw SSH" ;;
        ws)      echo "WebSocket (classic)" ;;
        auto)    echo "Auto-detect" ;;
    esac
}

show_listeners() {
    say "${C_BOLD}Configured listeners:${C_RESET}"
    if [ "${#L_PORT[@]}" -eq 0 ]; then
        say "  ${C_DIM}(none yet — add at least one below)${C_RESET}"
        return
    fi
    local i tls_note
    for ((i = 0; i < ${#L_PORT[@]}; i++)); do
        [ "${L_TLS[i]}" = "1" ] && tls_note=" ${C_CYAN}+TLS${C_RESET}" || tls_note=""
        printf "  ${C_GREEN}%2d.${C_RESET} port ${C_BOLD}%-6s${C_RESET} %-22s%b\n" \
            "$((i + 1))" "${L_PORT[i]}" "$(mode_label "${L_MODE[i]}")" "$tls_note"
    done
}

add_listener() {
    local mode="$1" default_port="$2" port use_tls=0

    say "\n${C_BOLD}${C_CYAN}$(mode_label "$mode")${C_RESET}"
    case "$mode" in
        connect) say "  ${C_DIM}Client sends CONNECT host:port, gets 200 Connection established.${C_RESET}"
                 say "  ${C_DIM}For HTTP-proxy clients and ssh ProxyCommand.${C_RESET}" ;;
        payload) say "  ${C_DIM}Client sends any HTTP head, gets your chosen status line.${C_RESET}" ;;
        direct)  say "  ${C_DIM}No handshake at all — raw SSH straight through.${C_RESET}" ;;
        ws)      say "  ${C_DIM}Client sends an Upgrade header, gets a 101 banner.${C_RESET}" ;;
        auto)    say "  ${C_DIM}Sniffs the first bytes and accepts any of the above on one port.${C_RESET}" ;;
    esac

    ask_port port "$default_port"

    if ask_yn "Wrap this port in TLS" "n"; then
        use_tls=1
        [ -z "$CERT" ] && ask CERT "TLS certificate path" "/etc/haproxy/certs/ayanakoji.pem"
        [ -z "$KEY" ]  && ask KEY  "TLS private key path"  "$CERT"
        [ -f "$CERT" ] || warn "Certificate $CERT does not exist yet — create it before starting."
    fi

    # Mode-specific tuning, asked once and reused by later listeners.
    if { [ "$mode" = "payload" ] || [ "$mode" = "auto" ]; } && [ "$PAYLOAD_ASKED" = "0" ]; then
        PAYLOAD_ASKED=1
        # Asked as a yes/no because an empty answer to `ask` means "take the
        # default", so a blank status line is otherwise unreachable.
        if ask_yn "Reply to payload clients with a status line" "y"; then
            ask PAYLOAD_STATUS "Status line" "200 OK"
        else
            PAYLOAD_STATUS=""
            ok "Payload clients will get no reply at all."
        fi
        if ask_yn "Require a secret tag in the payload (drops port scanners)" "n"; then
            ask PAYLOAD_MATCH "Required substring" "X-Tunnel-Key: change-me"
        fi
    fi
    if { [ "$mode" = "ws" ] || [ "$mode" = "auto" ]; } && [ "$WS_ASKED" = "0" ]; then
        WS_ASKED=1
        ask WS_STATUS "WebSocket 101 banner" "$DEFAULT_WS_STATUS"
    fi

    L_PORT+=("$port"); L_MODE+=("$mode"); L_TLS+=("$use_tls")
    ok "Added $(mode_label "$mode") on port $port."
}

remove_listener() {
    if [ "${#L_PORT[@]}" -eq 0 ]; then warn "Nothing to remove."; return; fi
    local n=""
    ask n "Number to remove" ""
    if ! [[ "$n" =~ ^[0-9]+$ ]] || [ "$n" -lt 1 ] || [ "$n" -gt "${#L_PORT[@]}" ]; then
        err "No listener numbered '$n'."
        return
    fi
    local idx=$((n - 1))
    ok "Removed port ${L_PORT[idx]}."
    L_PORT=("${L_PORT[@]:0:idx}" "${L_PORT[@]:$((idx + 1))}")
    L_MODE=("${L_MODE[@]:0:idx}" "${L_MODE[@]:$((idx + 1))}")
    L_TLS=("${L_TLS[@]:0:idx}" "${L_TLS[@]:$((idx + 1))}")
}

# systemd splits ExecStart on whitespace and expands % specifiers, so every
# argument is double-quoted with embedded quotes, backslashes and % escaped.
sd_quote() {
    local s="$1"
    s="${s//\\/\\\\}"
    s="${s//\"/\\\"}"
    s="${s//%/%%}"
    printf '"%s"' "$s"
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
    [ -n "$CERT" ] && out+=(-cert "$CERT")
    [ -n "$KEY" ] && out+=(-key "$KEY")
    [ -n "$WS_STATUS" ] && out+=(-ws-status "$WS_STATUS")
    # A deliberately blank payload status means "reply nothing" and still has to
    # be passed, so this is gated on the mode being present rather than on the
    # value being non-empty.
    needs_payload_flags && out+=(-payload-status "$PAYLOAD_STATUS")
    [ -n "$PAYLOAD_MATCH" ] && out+=(-payload-match "$PAYLOAD_MATCH")
    [ "$MAX_CONNS" != "0" ] && out+=(-max-conns "$MAX_CONNS")
    [ "$HANDSHAKE_TIMEOUT" != "10" ] && out+=(-handshake-timeout-secs "$HANDSHAKE_TIMEOUT")
    return 0
}

needs_payload_flags() {
    local i
    for ((i = 0; i < ${#L_MODE[@]}; i++)); do
        case "${L_MODE[i]}" in payload | auto) return 0 ;; esac
    done
    return 1
}

write_unit() {
    local args=() quoted="" a
    build_args args
    for a in "${args[@]}"; do quoted="$quoted $(sd_quote "$a")"; done

    local unit
    unit=$(
        cat <<UNIT
[Unit]
Description=Ayanakoji Go Proxy Backend
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

[Install]
WantedBy=multi-user.target
UNIT
    )

    if [ "$DRY_RUN" = "1" ]; then
        say "\n${C_BOLD}${C_YELLOW}--- dry run: $SERVICE_FILE would contain ---${C_RESET}"
        printf '%s\n' "$unit"
        say "${C_BOLD}${C_YELLOW}--- end dry run ---${C_RESET}"
        return 0
    fi

    printf '%s\n' "$unit" > "$SERVICE_FILE" || { err "Could not write $SERVICE_FILE"; return 1; }
    ok "Wrote $SERVICE_FILE"

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" >/dev/null 2>&1
    if systemctl restart "$SERVICE_NAME"; then
        ok "$SERVICE_NAME restarted"
    else
        err "$SERVICE_NAME failed to start — see: journalctl -u $SERVICE_NAME -n 30"
        return 1
    fi
}

summary() {
    local args=() a
    build_args args
    say "\n${C_BOLD}${C_PURPLE}=== Summary ===${C_RESET}\n"
    show_listeners
    say "\n  ${C_BOLD}Backend:${C_RESET}      $SSH_HOST:$SSH_PORT"
    [ -n "$CERT" ] && say "  ${C_BOLD}TLS cert:${C_RESET}     $CERT"
    [ -n "$KEY" ] && say "  ${C_BOLD}TLS key:${C_RESET}      $KEY"
    needs_payload_flags && say "  ${C_BOLD}Payload reply:${C_RESET} ${PAYLOAD_STATUS:-(nothing)}"
    [ -n "$PAYLOAD_MATCH" ] && say "  ${C_BOLD}Payload gate:${C_RESET}  $PAYLOAD_MATCH"
    [ "$MAX_CONNS" != "0" ] && say "  ${C_BOLD}Max tunnels:${C_RESET}   $MAX_CONNS"
    say "\n  ${C_BOLD}Resulting command:${C_RESET}"
    printf "${C_DIM}    %s" "$BIN"
    for a in "${args[@]}"; do
        case "$a" in
            -*) printf ' \\\n      %s' "$a" ;;
            *)  printf ' %q' "$a" ;;
        esac
    done
    printf "${C_RESET}\n"
}

apply_preset() {
    L_PORT=(10080 8888 2053); L_MODE=(ws connect payload); L_TLS=(0 0 0)
    WS_STATUS="$DEFAULT_WS_STATUS"; WS_ASKED=1
    PAYLOAD_STATUS="200 OK"; PAYLOAD_ASKED=1
    ok "Preset loaded: websocket on 10080, CONNECT on 8888, payload on 2053."
    say "  ${C_DIM}10080 stays behind HAProxy; 8888 and 2053 are reachable directly.${C_RESET}"
}

ask_backend() {
    say "\n${C_BOLD}${C_PURPLE}=== Backend and limits ===${C_RESET}\n"
    ask SSH_HOST "SSH backend host" "$SSH_HOST"
    ask SSH_PORT "SSH backend port" "$SSH_PORT"
    if ask_yn "Set a cap on concurrent tunnels" "n"; then
        ask MAX_CONNS "Maximum concurrent tunnels" "2000"
    fi
    ask HANDSHAKE_TIMEOUT "Seconds a client gets to finish its handshake" "$HANDSHAKE_TIMEOUT"
}

main() {
    if [ "$DRY_RUN" = "0" ] && [ "$(id -u)" -ne 0 ]; then
        err "Run as root (sudo ./transport-setup.sh), or pass --dry-run to preview."
        exit 1
    fi
    if [ "$DRY_RUN" = "0" ] && [ ! -x "$BIN" ]; then
        warn "$BIN not found — build it first, or this service will fail to start."
    fi

    while true; do
        clear
        say "${C_BOLD}${C_PURPLE}=== Ayanakoji Transport Setup ===${C_RESET}"
        say "${C_DIM}Pick how clients are allowed to reach the tunnel.${C_RESET}\n"
        show_listeners
        say ""
        say "  ${C_GREEN}[1]${C_RESET} HTTP CONNECT proxy   ${C_DIM}CONNECT host:port → 200 established${C_RESET}"
        say "  ${C_GREEN}[2]${C_RESET} Custom payload       ${C_DIM}any HTTP head → your status line${C_RESET}"
        say "  ${C_GREEN}[3]${C_RESET} Direct / raw SSH     ${C_DIM}no handshake${C_RESET}"
        say "  ${C_GREEN}[4]${C_RESET} WebSocket (classic)  ${C_DIM}Upgrade → 101 banner${C_RESET}"
        say "  ${C_GREEN}[5]${C_RESET} Auto-detect          ${C_DIM}accepts all of the above on one port${C_RESET}"
        say ""
        say "  ${C_CYAN}[p]${C_RESET} Load recommended preset"
        say "  ${C_YELLOW}[r]${C_RESET} Remove a listener"
        say "  ${C_BOLD}[d]${C_RESET} Done — review and save"
        say "  ${C_RED}[q]${C_RESET} Quit without saving"
        say ""
        read -rp "$(echo -e "👉 Choice: ")" choice

        case "${choice,,}" in
            1) add_listener connect 8888 ;;
            2) add_listener payload 2053 ;;
            3) add_listener direct 1194 ;;
            4) add_listener ws 10080 ;;
            5) add_listener auto 443 ;;
            p) apply_preset ;;
            r) remove_listener ;;
            d)
                if [ "${#L_PORT[@]}" -eq 0 ]; then
                    err "Add at least one listener first."
                    sleep 1.5
                    continue
                fi
                break
                ;;
            q) say "\n${C_YELLOW}Nothing was changed.${C_RESET}"; exit 0 ;;
            *) continue ;;
        esac

        # Pause so the result of the action stays readable before the redraw.
        [ "${choice,,}" = "r" ] || say ""
        read -rp "$(echo -e "${C_DIM}Press Enter to continue...${C_RESET}")" _
    done

    ask_backend
    summary

    say ""
    if ask_yn "Write this configuration and restart the service" "y"; then
        write_unit
    else
        say "\n${C_YELLOW}Nothing was changed.${C_RESET}"
        exit 0
    fi

    if [ "$DRY_RUN" = "0" ]; then
        say "\n${C_BOLD}Client hints:${C_RESET}"
        local i
        for ((i = 0; i < ${#L_PORT[@]}; i++)); do
            case "${L_MODE[i]}" in
                connect) say "  ${C_DIM}CONNECT proxy:${C_RESET} point the client's HTTP proxy at this host:${L_PORT[i]}" ;;
                direct)  say "  ${C_DIM}Direct:${C_RESET}        ssh -p ${L_PORT[i]} user@this-host" ;;
                payload) say "  ${C_DIM}Payload:${C_RESET}       send your payload to port ${L_PORT[i]}" ;;
            esac
        done
        say "\n  ${C_DIM}Logs: journalctl -u $SERVICE_NAME -f${C_RESET}"
    fi
    say ""
}

main "$@"
