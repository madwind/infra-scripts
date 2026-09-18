#!/bin/sh

enable_bbr() {
    echo "Enabling BBR..."

    bbr_tmp=$(mktemp)
    cat >"$bbr_tmp" <<'EOF_BBR'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF_BBR

    run_root install -m 0644 "$bbr_tmp" /etc/sysctl.d/99-bbr.conf
    rm -f "$bbr_tmp"
    run_root sysctl -p /etc/sysctl.d/99-bbr.conf

    sysctl net.core.default_qdisc
    sysctl net.ipv4.tcp_congestion_control
}
