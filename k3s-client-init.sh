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
    local tmp

    if [ ! -f "$file" ] || ! grep -Eq '^[[:space:]]*ip_vs[[:space:]]*$' "$file"; then
        return 0
    fi

    tmp=$(mktemp)
    grep -Ev '^[[:space:]]*ip_vs[[:space:]]*$' "$file" >"$tmp" || true

    if grep -q '[^[:space:]]' "$tmp"; then
        run_root install -m 0644 "$tmp" "$file"
    else
        run_root rm -f "$file"
    fi

    rm -f "$tmp"
    echo "Removed legacy IPVS module-load configuration."
}

# -----preflight-----
preflight_require_root
preflight_require_env DOMAIN K3S_TOKEN
preflight_require_commands curl hostname sed awk grep install systemctl sysctl getent

# -----host setup-----
enable_bbr
setup_systemd_resolved_dot
setup_nftables_firewall client
report_other_firewalls

# -----uninstall previous k3s-----
uninstall_previous_k3s

# -----k3s installation-----
echo "Installing K3s..."
export K3S_URL=https://${DOMAIN}:6443
export K3S_EXTERNAL_IP=$(curl -4 ifconfig.me)
export INSTALL_K3S_EXEC="
--node-external-ip $K3S_EXTERNAL_IP
--kube-proxy-arg proxy-mode=nftables
"
curl -sfL https://get.k3s.io | sh -
cleanup_legacy_ipvs_config
echo "done."
