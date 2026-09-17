#!/bin/bash
set -euo pipefail

run_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

echo "Cleaning legacy infra-scripts files..."

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

# Older versions generated the whole rc.local file for iptables rules.
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

echo "done."
