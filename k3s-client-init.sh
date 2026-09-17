#!/bin/bash
set -euo pipefail

COMMON_URL="https://raw.githubusercontent.com/madwind/infra-scripts/refs/heads/main/lib/common.sh"

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

# -----preflight-----
preflight_require_root
preflight_require_env DOMAIN K3S_TOKEN
preflight_require_commands curl hostname sed awk grep install systemctl sysctl getent

# -----host setup-----
enable_bbr
setup_systemd_resolved_dot
setup_nftables_firewall client

# -----k3s installation-----
echo "Installing K3s..."
export K3S_URL=https://${DOMAIN}:6443
export K3S_EXTERNAL_IP=$(curl -4 ifconfig.me)
export INSTALL_K3S_EXEC="
--node-external-ip $K3S_EXTERNAL_IP
--kube-proxy-arg proxy-mode=nftables
"
curl -sfL https://get.k3s.io | sh -
echo "done."
