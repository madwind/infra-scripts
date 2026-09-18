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
preflight_require_env DOMAIN K3S_TOKEN

# -----host setup-----
enable_bbr
setup_systemd_resolved_dot
setup_pod_system_dns
setup_iptables_firewall client

# -----prepare k3s installation-----
K3S_URL=https://${DOMAIN}:6443
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
INSTALL_K3S_EXEC="
--node-external-ip $K3S_EXTERNAL_IP
--kube-proxy-arg proxy-mode=nftables
"
if ! env \
    K3S_URL="$K3S_URL" \
    K3S_TOKEN="$K3S_TOKEN" \
    INSTALL_K3S_EXEC="$INSTALL_K3S_EXEC" \
    sh "$K3S_INSTALLER"; then
    rm -f "$K3S_INSTALLER"
    exit 1
fi
rm -f "$K3S_INSTALLER"
echo "done."
