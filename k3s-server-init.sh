#!/bin/sh
set -eu

COMMON_URL="https://raw.githubusercontent.com/madwind/infra-scripts/refs/heads/main/lib/common.sh"

COMMON_SH=
INFRA_LIB_DIR=
if [ -f "$0" ]; then
    SCRIPT_DIR=$(CDPATH= cd "$(dirname "$0")" && pwd)
    if [ -f "$SCRIPT_DIR/lib/common.sh" ]; then
        COMMON_SH="$SCRIPT_DIR/lib/common.sh"
        INFRA_LIB_DIR="$SCRIPT_DIR/lib"
        export INFRA_LIB_DIR
    fi
fi

if [ -z "$COMMON_SH" ]; then
    COMMON_SH=$(mktemp)
    trap 'rm -f "$COMMON_SH"' 0
    curl -fsSL "$COMMON_URL" -o "$COMMON_SH"
fi

# shellcheck source=lib/common.sh
. "$COMMON_SH"
load_infra_modules system dns firewall k3s

# -----preflight-----
preflight_require_root
preflight_require_env DOMAIN ACCOUNT_ID DATABASE_ID API_TOKEN
if ! command -v jq >/dev/null 2>&1; then
    _install_package jq
fi

# -----host setup-----
enable_bbr
setup_systemd_resolved_dot
setup_pod_system_dns
setup_iptables_firewall server

# -----prepare k3s installation-----
HOSTNAME=$(hostname)
K3S_EXTERNAL_IP=$(get_external_ipv4)
K3S_INSTALLER=$(mktemp)
if ! download_k3s_installer "$K3S_INSTALLER"; then
    rm -f "$K3S_INSTALLER"
    exit 1
fi

# -----uninstall previous k3s-----
if ! uninstall_previous_k3s; then
    rm -f "$K3S_INSTALLER"
    exit 1
fi

# -----k3s installation-----
echo "Installing K3s..."
INSTALL_K3S_EXEC="server
--tls-san $DOMAIN
--write-kubeconfig /root/.kube/config
--node-external-ip $K3S_EXTERNAL_IP
--flannel-external-ip
--flannel-backend wireguard-native
--disable traefik,servicelb
--kube-proxy-arg proxy-mode=nftables
"
if ! env \
    INSTALL_K3S_EXEC="$INSTALL_K3S_EXEC" \
    sh "$K3S_INSTALLER"; then
    rm -f "$K3S_INSTALLER"
    exit 1
fi
rm -f "$K3S_INSTALLER"

# -----save k3s to d1-----
echo "Saving Kubeconfig to Cloudflare D1..."
NEW_KUBECONFIG=$(run_root sed -e "s|server: https://127.0.0.1:6443|server: https://$DOMAIN:6443|" \
                           -e "s|default|$HOSTNAME|g" \
                           /root/.kube/config | base64 -w 0)

D1_PAYLOAD=$(jq -n \
    --arg cluster_name "$HOSTNAME" \
    --arg content "$NEW_KUBECONFIG" \
    '{
        sql: "INSERT OR REPLACE INTO config (cluster_name, content) VALUES (?, ?);",
        params: [$cluster_name, $content]
    }')

D1_RESPONSE=$(mktemp)
if ! curl -fsS \
    --connect-timeout 10 \
    --max-time 30 \
    -X POST "https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/d1/database/$DATABASE_ID/query" \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $API_TOKEN" \
    -d "$D1_PAYLOAD" \
    -o "$D1_RESPONSE"; then
    rm -f "$D1_RESPONSE"
    echo "Error: failed to save kubeconfig to Cloudflare D1." >&2
    exit 1
fi

jq . "$D1_RESPONSE"
if ! jq -e '.success == true' "$D1_RESPONSE" >/dev/null; then
    rm -f "$D1_RESPONSE"
    echo "Error: Cloudflare D1 rejected the kubeconfig update." >&2
    exit 1
fi
rm -f "$D1_RESPONSE"

echo "done."
