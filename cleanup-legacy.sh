#!/bin/sh
set -eu

run_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        echo "Error: run as root or install sudo." >&2
        return 1
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

# Remove the node-local address used to expose systemd-resolved to Pods.
if systemctl list-unit-files infra-node-local-address.service >/dev/null 2>&1; then
    run_root systemctl disable --now infra-node-local-address.service >/dev/null 2>&1 || true
fi

run_root ip address del 169.254.20.10/32 dev lo >/dev/null 2>&1 || true
run_root ip address del 10.254.254.54/32 dev lo >/dev/null 2>&1 || true
run_root rm -f \
    /etc/systemd/system/infra-node-local-address.service \
    /usr/local/sbin/infra-node-local-address.sh \
    /etc/systemd/system/systemd-resolved.service.d/infra-node-local-address.conf \
    /etc/systemd/resolved.conf.d/pod-system-dns.conf
run_root systemctl daemon-reload
run_root systemctl restart systemd-resolved.service >/dev/null 2>&1 || true

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

# Stop the current infra-scripts iptables service before removing its rules.
if systemctl list-unit-files infra-iptables-firewall.service >/dev/null 2>&1; then
    run_root systemctl disable --now infra-iptables-firewall.service >/dev/null 2>&1 || true
fi

run_root rm -f \
    /etc/systemd/system/infra-iptables-firewall.service \
    /usr/local/sbin/infra-iptables-firewall
run_root systemctl daemon-reload

remove_infra_iptables() {
    command_name=$1

    command -v "$command_name" >/dev/null 2>&1 || return 0

    # Remove both legacy direct INPUT rules and current chain jump rules.
    while true; do
        rule=$(run_root "$command_name" -w 5 -S INPUT 2>/dev/null \
            | grep -- '--comment infra-scripts' \
            | head -n1 || true)
        [ -n "$rule" ] || break
        rule=${rule#-A INPUT }
        # shellcheck disable=SC2086
        run_root "$command_name" -w 5 -D INPUT $rule
    done

    for chain in $(run_root "$command_name" -w 5 -S 2>/dev/null \
        | awk '$1 == "-N" && ($2 == "INFRA-INPUT" || $2 ~ /^INFRA-INPUT-/) { print $2 }'); do
        run_root "$command_name" -w 5 -F "$chain" >/dev/null 2>&1 || true
        run_root "$command_name" -w 5 -X "$chain" >/dev/null 2>&1 || true
    done
}

remove_infra_iptables iptables
remove_infra_iptables ip6tables

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

echo "done."
