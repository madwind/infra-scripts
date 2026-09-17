#!/bin/bash

SCRIPT_URL="https://raw.githubusercontent.com/madwind/infra-scripts/refs/heads/main/k3s-client-init.sh"
COMMON_URL="https://raw.githubusercontent.com/madwind/infra-scripts/refs/heads/main/lib/common.sh"

# Ubuntu /bin/sh is usually dash. When this script is piped to `sh`, restart it
# under Bash before any Bash-only syntax is parsed.
if [ -z "${BASH_VERSION:-}" ]; then
    if ! command -v bash >/dev/null 2>&1; then
        echo "Error: bash is required." >&2
        exit 1
    fi

    if command -v curl >/dev/null 2>&1; then
        exec bash -c "$(curl -fsSL "$SCRIPT_URL")" -- "$@"
    elif command -v wget >/dev/null 2>&1; then
        exec bash -c "$(wget -qO- "$SCRIPT_URL")" -- "$@"
    else
        echo "Error: curl or wget is required." >&2
        exit 1
    fi
fi

set -euo pipefail

COMMON_SH=""
if [ -n "${BASH_SOURCE[0]:-}" ] && [ -f "${BASH_SOURCE[0]}" ]; then
    SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
    if [ -f "$SCRIPT_DIR/lib/common.sh" ]; then
        COMMON_SH="$SCRIPT_DIR/lib/common.sh"
    fi
fi

if [ -z "$COMMON_SH" ]; then
    COMMON_SH=$(mktemp)
    trap 'rm -f "$COMMON_SH"' EXIT
    curl -fsSL "$COMMON_URL" -o "$COMMON_SH"
fi

# shellcheck source=lib/common.sh
source "$COMMON_SH"

# -----host setup-----
enable_bbr
enable_ipvs
setup_systemd_resolved_dot
setup_nftables_firewall client

# -----uninstall previous k3s-----
uninstall_previous_k3s

# -----k3s installation-----
echo "Installing K3s..."
export K3S_URL=https://${DOMAIN}:6443
export K3S_EXTERNAL_IP=$(curl -4 ifconfig.me)
export INSTALL_K3S_EXEC="
--node-external-ip $K3S_EXTERNAL_IP
--kube-proxy-arg proxy-mode=ipvs
"
curl -sfL https://get.k3s.io | sh -
echo "done."
