#!/bin/bash
set -u
C_RESET='\033[0m'; C_BOLD='\033[1m'; C_RED='\033[31m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'
[ "$(id -u)" -eq 0 ] || { echo -e "${C_RED}Run as root${C_RESET}"; exit 1; }

INSTALL_DIR="${INSTALL_DIR:-/opt/ayanakoji-proxy}"
CERT_DIR="${CERT_DIR:-/etc/ayanakoji}"
SERVICE_FILE="${SERVICE_FILE:-/etc/systemd/system/ayanakoji-proxy.service}"
SERVICE_NAME="$(basename "$SERVICE_FILE" .service)"

echo -e "${C_BOLD}${C_RED}=== Uninstall ===${C_RESET}\n"
echo -e "This removes:"
echo -e "  • the $SERVICE_NAME service"
echo -e "  • $INSTALL_DIR"
echo -e "\n${C_YELLOW}SSH user accounts and sshd itself are left alone.${C_RESET}\n"

read -rp "$(echo -e "Type ${C_BOLD}yes${C_RESET} to continue, anything else to abort: ")" confirm
if [ "${confirm:-}" != "yes" ]; then
    echo -e "\n${C_GREEN}Aborted. Nothing was changed.${C_RESET}"
    exit 0
fi

systemctl disable --now "$SERVICE_NAME" 2> /dev/null
rm -f "$SERVICE_FILE"
systemctl daemon-reload
rm -rf "$INSTALL_DIR"
echo -e "${C_GREEN}  ✓ service and files removed${C_RESET}"

# Kept by default: a Let's Encrypt path may be shared, and a self-signed key is
# cheap to keep but annoying to regenerate if clients pinned it.
if [ -d "$CERT_DIR" ]; then
    read -rp "$(echo -e "Also delete the certificates in ${C_BOLD}$CERT_DIR${C_RESET}? [y/N]: ")" delcerts
    case "${delcerts:-n}" in
        y | Y | yes) rm -rf "$CERT_DIR"; echo -e "${C_GREEN}  ✓ $CERT_DIR removed${C_RESET}" ;;
        *) echo -e "${C_YELLOW}  ! $CERT_DIR kept${C_RESET}" ;;
    esac
fi

echo -e "\n${C_GREEN}${C_BOLD}Uninstall complete.${C_RESET}"
