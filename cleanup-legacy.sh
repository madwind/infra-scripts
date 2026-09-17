#!/bin/bash
set -euo pipefail

run_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

echo "Cleaning legacy infra-scripts files and firewall state..."

# BBR is now managed by /etc/sysctl.d/99-bbr.conf.
if [ -f /etc/sysctl.d/99-bbr.conf ] && [ -f /etc/sysctl.conf ]; then
    run_root sed -i \
        -e '/^net\.core\.default_qdisc[[:space:]]*=[[:space:]]*fq[[:space:]]*$/d' \
        -e '/^net\.ipv4\.tcp_congestion_control[[:space:]]*=[[:space:]]*bbr[[:space:]]*$/d' \
        /etc/sysctl.conf
fi

run_root rm -f \
    /etc/modules-load.d/ipvs.conf \
    /etc/resolv.conf.before-systemd-resolved

# Remove the nftables firewall previously created by infra-scripts.
if systemctl list-unit-files infra-firewall.service >/dev/null 2>&1; then
    run_root systemctl disable --now infra-firewall.service >/dev/null 2>&1 || true
fi

if command -v nft >/dev/null 2>&1; then
    if run_root nft list table inet infra_filter >/dev/null 2>&1; then
        run_root nft delete table inet infra_filter
    fi
fi

run_root rm -f \
    /etc/systemd/system/infra-firewall.service \
    /etc/nftables.d/infra-scripts.nft
run_root systemctl daemon-reload

# Older versions generated the whole rc.local file for iptables rules.
# Remove only the persistence file here. Those rules had no ownership marker,
# so deleting matching live rules could accidentally remove provider rules.
if [ -f /etc/rc.local ]; then
    if grep -q '^# migrated to nftables: add_rule ' /etc/rc.local \
        || { grep -q '^add_rule() {' /etc/rc.local \
            && grep -q '10\.42\.0\.0/16' /etc/rc.local \
            && grep -q '10\.43\.0\.0/16' /etc/rc.local; }; then
        run_root rm -f /etc/rc.local
    else
        echo "Skipping /etc/rc.local: not recognized as an infra-scripts legacy file."
    fi
fi

# Current iptables rules are explicitly owned with a comment and can be
# removed safely when a full cleanup is requested.
remove_owned_rules() {
    local command=$1

    command -v "$command" >/dev/null 2>&1 || return 0

    while true; do
        local rule
        rule=$($command -S INPUT 2>/dev/null | grep -- '--comment infra-scripts' | head -n1 || true)
        [ -n "$rule" ] || break
        rule=${rule#-A INPUT }
        # shellcheck disable=SC2086
        run_root "$command" -D INPUT $rule
    done
}

remove_owned_rules iptables
remove_owned_rules ip6tables

echo "done."
