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
preflight_require_env DOMAIN ACCOUNT_ID DATABASE_ID API_TOKEN
if ! command -v jq >/dev/null 2>&1; then
    _install_package jq
fi

# -----host setup-----
enable_bbr
setup_systemd_resolved_dot
setup_iptables_firewall server

# -----uninstall previous k3s-----
uninstall_previous_k3s

# -----k3s installation-----
echo "Installing K3s..."
HOSTNAME=$(hostname)
K3S_EXTERNAL_IP=$(curl -4 ifconfig.me)
INSTALL_K3S_EXEC="server
--tls-san $DOMAIN
--write-kubeconfig /root/.kube/config
--node-external-ip $K3S_EXTERNAL_IP
--flannel-external-ip
--flannel-backend wireguard-native
--disable traefik,servicelb
--kube-proxy-arg proxy-mode=nftables
"
curl -sfL https://get.k3s.io | env \
    INSTALL_K3S_EXEC="$INSTALL_K3S_EXEC" \
    sh -

# -----save k3s to d1-----
echo "Saving Kubeconfig to Cloudflare D1..."
NEW_KUBECONFIG=$(run_root sed -e "s|server: https://127.0.0.1:6443|server: https://$DOMAIN:6443|" \
                           -e "s|default|$HOSTNAME|g" \
                           /root/.kube/config | base64 -w 0)

curl -X POST https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/d1/database/$DATABASE_ID/query \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $API_TOKEN" \
    -d '{
          "sql": "INSERT OR REPLACE INTO config (cluster_name, content) VALUES (?, ?);",
          "params": [
            "'$HOSTNAME'",
            "'$NEW_KUBECONFIG'"
          ]
        }' | jq
echo "done."
