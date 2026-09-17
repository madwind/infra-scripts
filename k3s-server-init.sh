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
setup_nftables_firewall server

# -----uninstall previous k3s-----
uninstall_previous_k3s

# -----k3s installation-----
echo "Installing K3s..."
export HOSTNAME=$(hostname)
export K3S_EXTERNAL_IP=$(curl -4 ifconfig.me)
export INSTALL_K3S_EXEC="server
--tls-san $DOMAIN
--write-kubeconfig /root/.kube/config
--node-external-ip $K3S_EXTERNAL_IP
--flannel-external-ip
--flannel-backend wireguard-native
--disable traefik,servicelb
--kube-proxy-arg proxy-mode=ipvs
"
curl -sfL https://get.k3s.io | sh -

# -----save k3s to d1-----
echo "Saving Kubeconfig to Cloudflare D1..."
NEW_KUBECONFIG=$(sudo sed -e "s|server: https://127.0.0.1:6443|server: https://$DOMAIN:6443|" \
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
