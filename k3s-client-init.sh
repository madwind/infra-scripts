#!/bin/bash
set -euo pipefail

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
COMMON_SH="$SCRIPT_DIR/lib/common.sh"

if [ ! -f "$COMMON_SH" ]; then
    COMMON_SH=$(mktemp)
    trap 'rm -f "$COMMON_SH"' EXIT
    curl -fsSL https://raw.githubusercontent.com/madwind/infra-scripts/main/lib/common.sh -o "$COMMON_SH"
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
