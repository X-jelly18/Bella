#!/bin/bash
set -u
C_RESET='\033[0m'; C_BOLD='\033[1m'; C_DIM='\033[2m'
C_RED='\033[31m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'
[ "$(id -u)" -eq 0 ] || { echo -e "${C_RED}Run as root${C_RESET}"; exit 1; }

# Tunnel users need no interactive shell, so the default is a nologin account.
TUNNEL_SHELL="${TUNNEL_SHELL:-/usr/sbin/nologin}"
[ -x "$TUNNEL_SHELL" ] || TUNNEL_SHELL=/bin/false

create_user() {
    local username password password2 days expiry
    read -rp "👉 New username: " username
    if [ -z "$username" ]; then echo -e "${C_RED}  ✗ Username cannot be empty.${C_RESET}"; return; fi
    if ! [[ "$username" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]]; then
        echo -e "${C_RED}  ✗ Invalid name. Use lowercase letters, digits, - and _ (max 32).${C_RESET}"; return
    fi
    if id "$username" &> /dev/null; then
        echo -e "${C_RED}  ✗ User '$username' already exists.${C_RESET}"; return
    fi

    read -rsp "👉 Password: " password; echo
    if [ -z "$password" ]; then echo -e "${C_RED}  ✗ Password cannot be empty.${C_RESET}"; return; fi
    read -rsp "👉 Confirm password: " password2; echo
    if [ "$password" != "$password2" ]; then echo -e "${C_RED}  ✗ Passwords do not match.${C_RESET}"; return; fi

    read -rp "👉 Expire after how many days? [30, 0 = never]: " days
    days=${days:-30}

    if [ "$days" != "0" ]; then
        if ! [[ "$days" =~ ^[0-9]+$ ]]; then echo -e "${C_RED}  ✗ Not a number.${C_RESET}"; return; fi
        expiry=$(date -d "+$days days" +%Y-%m-%d)
        useradd -M -s "$TUNNEL_SHELL" -e "$expiry" "$username" || return
    else
        expiry="never"
        useradd -M -s "$TUNNEL_SHELL" "$username" || return
    fi

    if ! echo "$username:$password" | chpasswd; then
        echo -e "${C_RED}  ✗ Could not set the password; removing the account.${C_RESET}"
        userdel -r "$username" 2> /dev/null
        return
    fi

    echo -e "${C_GREEN}  ✓ Created '$username'${C_RESET}"
    echo -e "${C_DIM}    shell: $TUNNEL_SHELL (tunnel only)   expires: $expiry${C_RESET}"
}

delete_user() {
    local username
    read -rp "👉 Username to delete: " username
    if [ -z "$username" ] || ! id "$username" &> /dev/null; then
        echo -e "${C_RED}  ✗ User '$username' does not exist.${C_RESET}"; return
    fi
    if [ "$(id -u "$username")" -lt 1000 ]; then
        echo -e "${C_RED}  ✗ Refusing to delete a system account (uid < 1000).${C_RESET}"; return
    fi
    pkill -u "$username" 2> /dev/null
    if userdel -r "$username" 2> /dev/null; then
        echo -e "${C_GREEN}  ✓ Deleted '$username'${C_RESET}"
    else
        echo -e "${C_RED}  ✗ Could not delete '$username'${C_RESET}"
    fi
}

list_users() {
    printf "  ${C_BOLD}%-20s %-8s %-12s %s${C_RESET}\n" "USER" "UID" "EXPIRES" "SHELL"
    while IFS=: read -r name _ uid _ _ _ shell; do
        [ "$uid" -ge 1000 ] && [ "$uid" -lt 65000 ] || continue
        printf "  %-20s %-8s %-12s %s\n" \
            "$name" "$uid" "$(chage -l "$name" 2>/dev/null | sed -n 's/^Account expires[^:]*: *//p' | head -1)" "$shell"
    done < /etc/passwd
}

while true; do
    clear
    echo -e "${C_BOLD}=== Ayanakoji SSH User Manager ===${C_RESET}\n"
    echo -e "  ${C_GREEN}[1]${C_RESET} Create a tunnel user"
    echo -e "  ${C_GREEN}[2]${C_RESET} Delete a user"
    echo -e "  ${C_GREEN}[3]${C_RESET} List users"
    echo -e "  ${C_YELLOW}[4]${C_RESET} Back to main menu"
    echo
    read -rp "👉 Choice: " choice
    case "$choice" in
        1) echo; create_user; echo; read -rp "Press Enter..." _ ;;
        2) echo; delete_user; echo; read -rp "Press Enter..." _ ;;
        3) echo; list_users; echo; read -rp "Press Enter..." _ ;;
        4) exit 0 ;;
        *) sleep 1 ;;
    esac
done
