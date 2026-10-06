#!/bin/bash
set -u
C_RESET='\033[0m'; C_BOLD='\033[1m'; C_RED='\033[31m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'
[ "$(id -u)" -eq 0 ] || { echo -e "${C_RED}Run as root${C_RESET}"; exit 1; }

INSTALL_DIR="${INSTALL_DIR:-/opt/ayanakoji-proxy}"
DUMMY_DIR="${DUMMY_DIR:-/var/www/dummy}"

echo -e "${C_BOLD}${C_RED}=== FULL UNINSTALL ===${C_RESET}\n"
echo -e "This removes:"
echo -e "  • the ayanakoji-proxy and ayanakoji-dummy services"
echo -e "  • $INSTALL_DIR and $DUMMY_DIR"
echo -e "  • ${C_YELLOW}/etc/haproxy, including any HAProxy config not created here${C_RESET}"
echo -e "\n${C_YELLOW}SSH user accounts are left alone.${C_RESET}\n"

read -rp "$(echo -e "Type ${C_BOLD}yes${C_RESET} to continue, anything else to abort: ")" confirm
if [ "${confirm:-}" != "yes" ]; then
    echo -e "\n${C_GREEN}Aborted. Nothing was changed.${C_RESET}"
    exit 0
fi

read -rp "$(echo -e "Also purge the ${C_BOLD}haproxy${C_RESET} package and /etc/haproxy? [y/N]: ")" purge

systemctl disable --now ayanakoji-proxy ayanakoji-dummy 2> /dev/null
rm -f /etc/systemd/system/ayanakoji-proxy.service /etc/systemd/system/ayanakoji-dummy.service
systemctl daemon-reload
rm -rf "$INSTALL_DIR" "$DUMMY_DIR"
echo -e "${C_GREEN}  ✓ services and files removed${C_RESET}"

case "${purge:-n}" in
    y | Y | yes)
        systemctl disable --now haproxy 2> /dev/null
        apt-get purge -y haproxy > /dev/null 2>&1
        rm -rf /etc/haproxy
        echo -e "${C_GREEN}  ✓ haproxy purged${C_RESET}" ;;
    *)
        echo -e "${C_YELLOW}  ! haproxy left installed; its config still routes :443${C_RESET}" ;;
esac

echo -e "\n${C_GREEN}${C_BOLD}Uninstall complete.${C_RESET}"
