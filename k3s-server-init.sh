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

report_other_firewalls() {
    local unit
    local found=0

    for unit in ufw firewalld nftables netfilter-persistent; do
        if systemctl is-active --quiet "$unit.service" 2>/dev/null; then
            echo "Warning: another firewall manager is active: $unit.service" >&2
            found=1
        fi
    done

    if command -v nft >/dev/null 2>&1; then
        local hooks
        hooks=$(nft list ruleset 2>/dev/null | awk '
            /^table[[:space:]]/ { family=$2; table_name=$3 }
            /^[[:space:]]*chain[[:space:]]/ { chain_name=$2 }
            /hook input/ && !(family == "inet" && table_name == "infra_filter") {
                print family " " table_name " / " chain_name
            }
        ' || true)

        if [ -n "$hooks" ]; then
            echo "Notice: additional nftables INPUT base chains are present:" >&2
            printf '%s\n' "$hooks" | sed 's/^/  - /' >&2
            found=1
        fi
    fi

    if [ "$found" -eq 1 ]; then
        echo "Notice: infra-scripts will not disable, flush, or modify those firewall owners." >&2
    fi
}

cleanup_legacy_ipvs_config() {
    local file=/etc/modules-load.d/ipvs.conf

    if [ -f "$file" ] && [ "$(grep -v '^[[:space:]]*$' "$file" 2>/dev/null || true)" = "ip_vs" ]; then
        run_root rm -f "$file"
        echo "Removed legacy IPVS module-load configuration."
    fi
}

# -----preflight-----
preflight_require_root
preflight_require_env DOMAIN ACCOUNT_ID DATABASE_ID API_TOKEN
preflight_require_commands curl hostname sed awk grep install systemctl sysctl getent base64 jq

# -----host setup-----
enable_bbr
setup_systemd_resolved_dot
setup_nftables_firewall server
report_other_firewalls

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
--kube-proxy-arg proxy-mode=nftables
"
curl -sfL https://get.k3s.io | sh -
cleanup_legacy_ipvs_config

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
