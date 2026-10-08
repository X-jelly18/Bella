#!/bin/bash
# Ayanakoji SSH-over-TLS installer.
#
#   curl -fsSL https://raw.githubusercontent.com/X-jelly18/Bella/main/vps/install.sh | sudo bash
#
# Overridable:
#   REF=some-branch   install from a different branch or tag (default: main)
#   REPO=owner/name   install from a fork
#   NONINTERACTIVE=1  install only, skip the setup menu
#   SKIP_DEPS=1       skip apt and Go setup (for re-runs and testing)
set -euo pipefail

REPO="${REPO:-X-jelly18/Bella}"
REF="${REF:-main}"
INSTALL_DIR="${INSTALL_DIR:-/opt/ayanakoji-proxy}"
RAW_BASE="https://raw.githubusercontent.com/${REPO}/${REF}/vps"
MIN_GO_MINOR=21

# When this script is piped into bash, BASH_SOURCE is an empty array, so it has
# to be probed defensively or set -u aborts. A non-empty SRC_DIR means we are
# running from a checkout and can copy instead of download.
SRC_DIR=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    SRC_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
fi

C_RESET='\033[0m'; C_BOLD='\033[1m'; C_DIM='\033[2m'
C_RED='\033[31m'; C_GREEN='\033[32m'; C_YELLOW='\033[33m'; C_PURPLE='\033[35m'

say()  { echo -e "$*"; }
ok()   { echo -e "${C_GREEN}  ✓ $*${C_RESET}"; }
warn() { echo -e "${C_YELLOW}  ! $*${C_RESET}"; }
die()  { echo -e "${C_RED}  ✗ $*${C_RESET}" >&2; exit 1; }

say "${C_BOLD}${C_PURPLE}=== Ayanakoji SSH-over-TLS installer ===${C_RESET}"
say "${C_DIM}  repo ${REPO} @ ${REF}${C_RESET}\n"

[ "$(id -u)" -eq 0 ] || die "Run as root: pipe this into 'sudo bash', or re-run with sudo."

case "$(uname -m)" in
    x86_64 | amd64) GOARCH=amd64 ;;
    aarch64 | arm64) GOARCH=arm64 ;;
    *) die "Unsupported architecture: $(uname -m)" ;;
esac

# ---------------------------------------------------------- dependencies ---

if [ "${SKIP_DEPS:-0}" = "1" ]; then
    warn "SKIP_DEPS=1, assuming openssl and go are present"
    [ -x /usr/local/go/bin/go ] && export PATH="/usr/local/go/bin:$PATH"
    command -v go > /dev/null 2>&1 || die "go not found, and SKIP_DEPS=1 was set"
else
say "${C_BOLD}Installing packages...${C_RESET}"
export DEBIAN_FRONTEND=noninteractive
apt-get update -y > /tmp/ayanakoji-apt.log 2>&1 || warn "apt-get update reported errors (see /tmp/ayanakoji-apt.log)"
if ! apt-get install -y openssl curl ca-certificates >> /tmp/ayanakoji-apt.log 2>&1; then
    die "Package install failed. See /tmp/ayanakoji-apt.log"
fi
ok "openssl and tools installed"

# The proxy uses tls.Conn.NetConn(), so a reasonably recent Go is required.
# Distro packages are often too old, in which case the official tarball is used.
go_minor() {
    command -v go > /dev/null 2>&1 || return 1
    go version 2>/dev/null | sed -n 's/^go version go1\.\([0-9]\+\).*/\1/p'
}

NEED_GO=1
CURRENT_MINOR="$(go_minor || true)"
if [ -n "${CURRENT_MINOR:-}" ] && [ "$CURRENT_MINOR" -ge "$MIN_GO_MINOR" ]; then
    NEED_GO=0
    ok "go 1.${CURRENT_MINOR} already present"
fi

if [ "$NEED_GO" = "1" ]; then
    if [ -x /usr/local/go/bin/go ]; then
        export PATH="/usr/local/go/bin:$PATH"
        CURRENT_MINOR="$(go_minor || true)"
    fi
    if [ -z "${CURRENT_MINOR:-}" ] || [ "$CURRENT_MINOR" -lt "$MIN_GO_MINOR" ]; then
        say "  ${C_DIM}installing Go toolchain (distro version too old or missing)...${C_RESET}"
        GO_VER="$(curl -fsSL https://go.dev/VERSION?m=text 2>/dev/null | head -1)"
        [ -n "$GO_VER" ] || GO_VER="go1.22.5"
        TARBALL="/tmp/${GO_VER}.linux-${GOARCH}.tar.gz"
        curl -fsSL -o "$TARBALL" "https://go.dev/dl/${GO_VER}.linux-${GOARCH}.tar.gz" \
            || die "Could not download ${GO_VER} for ${GOARCH}"
        rm -rf /usr/local/go
        tar -C /usr/local -xzf "$TARBALL"
        rm -f "$TARBALL"
        export PATH="/usr/local/go/bin:$PATH"
        command -v go > /dev/null 2>&1 || die "Go install failed"
        ok "$(go version)"
    else
        ok "$(go version)"
    fi
fi
fi

# ------------------------------------------------------------- fetch src ---

say "\n${C_BOLD}Fetching sources...${C_RESET}"
mkdir -p "$INSTALL_DIR"
for f in ayanakoji_proxy.go go.mod menu.sh ssh-manager.sh uninstall.sh; do
    if [ -n "$SRC_DIR" ] && [ -f "$SRC_DIR/$f" ]; then
        # Running from a checkout rather than piped from curl.
        cp "$SRC_DIR/$f" "$INSTALL_DIR/$f"
    else
        curl -fsSL -o "$INSTALL_DIR/$f" "$RAW_BASE/$f" || die "Could not fetch $f from $RAW_BASE"
    fi
done
chmod +x "$INSTALL_DIR"/*.sh
ok "sources in $INSTALL_DIR"

# ----------------------------------------------------------------- build ---

say "\n${C_BOLD}Building the proxy...${C_RESET}"
cd "$INSTALL_DIR"
if ! GOFLAGS=-mod=mod GOCACHE=/tmp/ayanakoji-gocache go build -ldflags "-s -w" -o ayanakoji_proxy . 2>/tmp/ayanakoji-build.log; then
    cat /tmp/ayanakoji-build.log >&2
    die "Build failed"
fi
chmod +x ayanakoji_proxy
ok "built $INSTALL_DIR/ayanakoji_proxy"

# ------------------------------------------------------------------ menu ---

say "\n${C_GREEN}${C_BOLD}Install complete.${C_RESET}"

if [ "${NONINTERACTIVE:-0}" = "1" ]; then
    say "\nNext: ${C_BOLD}sudo $INSTALL_DIR/menu.sh${C_RESET}"
    exit 0
fi

# Piping this script into bash leaves stdin pointing at the pipe, so the menu's
# prompts would read EOF immediately. Reattach the terminal explicitly.
if [ -r /dev/tty ]; then
    say "\nStarting setup menu...\n"
    exec "$INSTALL_DIR/menu.sh" < /dev/tty
fi

warn "No terminal available, so the setup menu was not started."
say "  Run it yourself: ${C_BOLD}sudo $INSTALL_DIR/menu.sh${C_RESET}"
