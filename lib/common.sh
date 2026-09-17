#!/bin/bash

run_root() {
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    elif command -v sudo >/dev/null 2>&1; then
        sudo "$@"
    else
        echo "Error: root privileges are required." >&2
        return 1
    fi
}

enable_bbr() {
    echo "Enabling BBR..."

    local tmp
    tmp=$(mktemp)
    cat >"$tmp" <<'EOF'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF

    run_root install -m 0644 "$tmp" /etc/sysctl.d/99-bbr.conf
    rm -f "$tmp"
    run_root sysctl -p /etc/sysctl.d/99-bbr.conf

    sysctl net.core.default_qdisc
    sysctl net.ipv4.tcp_congestion_control
}

enable_ipvs() {
    echo "Enabling IPVS..."

    run_root modprobe ip_vs
    printf '%s\n' ip_vs | run_root tee /etc/modules-load.d/ipvs.conf >/dev/null
    lsmod | grep '^ip_vs' || true
}

_install_package() {
    local package=$1

    if command -v apt-get >/dev/null 2>&1; then
        run_root env DEBIAN_FRONTEND=noninteractive apt-get update
        run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "$package"
    elif command -v dnf >/dev/null 2>&1; then
        run_root dnf install -y "$package"
    elif command -v yum >/dev/null 2>&1; then
        run_root yum install -y "$package"
    else
        echo "Error: $package is not installed and no supported package manager was found." >&2
        return 1
    fi
}

_install_systemd_resolved() {
    echo "Installing systemd-resolved..."
    _install_package systemd-resolved
}

setup_systemd_resolved_dot() {
    echo "Configuring DNS-over-TLS..."

    if ! command -v systemctl >/dev/null 2>&1; then
        echo "Error: systemd is not available." >&2
        return 1
    fi

    local resolv_backup=/etc/resolv.conf.before-systemd-resolved
    local dot_conf=/etc/systemd/resolved.conf.d/dot.conf
    local old_dot
    local had_old_dot=0
    local switched_resolv=0

    old_dot=$(mktemp)

    if [ -f "$dot_conf" ]; then
        cat "$dot_conf" >"$old_dot"
        had_old_dot=1
    fi

    restore_dot_config() {
        if [ "$had_old_dot" -eq 1 ]; then
            run_root install -D -m 0644 "$old_dot" "$dot_conf"
        else
            run_root rm -f "$dot_conf"
        fi
        run_root systemctl restart systemd-resolved.service >/dev/null 2>&1 || true
    }

    if ! command -v resolvectl >/dev/null 2>&1; then
        _install_systemd_resolved || {
            rm -f "$old_dot"
            return 1
        }
    fi

    # Some VPS images, including some DMIT images, mask systemd-resolved.
    run_root systemctl unmask systemd-resolved.service >/dev/null 2>&1 || true
    run_root systemctl daemon-reload
    run_root systemctl enable --now systemd-resolved.service

    local dns_servers
    dns_servers="1.1.1.1#cloudflare-dns.com 1.0.0.1#cloudflare-dns.com 8.8.8.8#dns.google 8.8.4.4#dns.google"

    # Add IPv6 resolvers only when the host has a global IPv6 address and route.
    if command -v ip >/dev/null 2>&1 \
        && ip -6 addr show scope global | grep -q 'inet6 ' \
        && ip -6 route get 2606:4700:4700::1111 >/dev/null 2>&1; then
        dns_servers="$dns_servers 2606:4700:4700::1111#cloudflare-dns.com 2606:4700:4700::1001#cloudflare-dns.com 2001:4860:4860::8888#dns.google 2001:4860:4860::8844#dns.google"
    fi

    local tmp
    tmp=$(mktemp)
    cat >"$tmp" <<EOF
[Resolve]
DNS=$dns_servers
FallbackDNS=
Domains=~.
DNSSEC=no
DNSOverTLS=yes
DNSStubListener=yes
EOF

    run_root install -D -m 0644 "$tmp" "$dot_conf"
    rm -f "$tmp"
    run_root systemctl restart systemd-resolved.service

    resolvectl flush-caches >/dev/null 2>&1 || true
    if ! timeout 20 resolvectl query example.com >/dev/null 2>&1; then
        echo "Error: DNS-over-TLS validation failed; restoring the previous resolved configuration." >&2
        restore_dot_config
        rm -f "$old_dot"
        return 1
    fi

    # Preserve a provider-supplied resolver configuration before taking it over.
    if { [ -e /etc/resolv.conf ] || [ -L /etc/resolv.conf ]; } \
        && [ ! -e "$resolv_backup" ] && [ ! -L "$resolv_backup" ]; then
        if [ "$(readlink -f /etc/resolv.conf 2>/dev/null || true)" != "/run/systemd/resolve/stub-resolv.conf" ]; then
            run_root cp -a /etc/resolv.conf "$resolv_backup"
        fi
    fi

    if ! run_root ln -sfn /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf; then
        if command -v chattr >/dev/null 2>&1; then
            run_root chattr -i /etc/resolv.conf >/dev/null 2>&1 || true
        fi
        run_root rm -f /etc/resolv.conf
        run_root ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    fi
    switched_resolv=1

    run_root systemctl restart systemd-resolved.service

    if ! timeout 20 getent ahosts example.com >/dev/null 2>&1; then
        echo "Error: system resolver validation failed; rolling back." >&2
        restore_dot_config

        if [ "$switched_resolv" -eq 1 ] && { [ -e "$resolv_backup" ] || [ -L "$resolv_backup" ]; }; then
            run_root rm -f /etc/resolv.conf
            run_root cp -a "$resolv_backup" /etc/resolv.conf
        fi

        rm -f "$old_dot"
        return 1
    fi

    rm -f "$old_dot"

    echo "DNS-over-TLS enabled."
    resolvectl status | sed -n '1,12p'
}

_remove_legacy_iptables_rule() {
    if ! command -v iptables >/dev/null 2>&1; then
        return 0
    fi

    while run_root iptables -C INPUT "$@" >/dev/null 2>&1; do
        run_root iptables -D INPUT "$@"
    done
}

_migrate_legacy_iptables_firewall() {
    local rc_local=/etc/rc.local

    # Only touch rc.local when it matches the firewall previously generated by this repository.
    if [ ! -f "$rc_local" ] \
        || ! grep -q '^add_rule -j REJECT --reject-with icmp-host-prohibited$' "$rc_local" \
        || ! grep -q '^add_rule -s 10\.42\.0\.0/16 -j ACCEPT$' "$rc_local"; then
        return 0
    fi

    echo "Migrating legacy iptables firewall..."

    _remove_legacy_iptables_rule -j REJECT --reject-with icmp-host-prohibited
    _remove_legacy_iptables_rule -i lo -j ACCEPT
    _remove_legacy_iptables_rule -p icmp -j ACCEPT
    _remove_legacy_iptables_rule -m state --state RELATED,ESTABLISHED -j ACCEPT
    _remove_legacy_iptables_rule -p udp -m udp --dport 51820 -j ACCEPT
    _remove_legacy_iptables_rule -p udp -m udp --dport 51821 -j ACCEPT
    _remove_legacy_iptables_rule -p tcp -m tcp --dport 10250 -j ACCEPT
    _remove_legacy_iptables_rule -p tcp -m tcp --dport 6443 -j ACCEPT
    _remove_legacy_iptables_rule -p tcp -m tcp --dport 443 -j ACCEPT
    _remove_legacy_iptables_rule -s 10.42.0.0/16 -j ACCEPT
    _remove_legacy_iptables_rule -s 10.43.0.0/16 -j ACCEPT

    local ssh_port
    ssh_port=$(grep -i '^Port[[:space:]]' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -n1 || true)
    ssh_port=${ssh_port:-22}
    _remove_legacy_iptables_rule -p tcp -m state --state NEW -m tcp --dport "$ssh_port" -j ACCEPT

    # Prevent every old generated rule, including the final REJECT, from returning on reboot.
    run_root sed -i '/^add_rule /s/^/# migrated to nftables: /' "$rc_local"
}

setup_nftables_firewall() {
    local role=${1:-client}
    case "$role" in
        client|server) ;;
        *)
            echo "Error: unknown firewall role: $role" >&2
            return 1
            ;;
    esac

    echo "Configuring nftables firewall ($role)..."

    if ! command -v nft >/dev/null 2>&1; then
        echo "Installing nftables..."
        _install_package nftables
    fi

    _migrate_legacy_iptables_firewall

    local ssh_port
    if command -v sshd >/dev/null 2>&1; then
        ssh_port=$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2; exit }' || true)
    fi
    if [ -z "${ssh_port:-}" ]; then
        ssh_port=$(grep -i '^Port[[:space:]]' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -n1 || true)
    fi
    ssh_port=${ssh_port:-22}

    if ! [[ "$ssh_port" =~ ^[0-9]+$ ]] || [ "$ssh_port" -lt 1 ] || [ "$ssh_port" -gt 65535 ]; then
        echo "Error: invalid SSH port: $ssh_port" >&2
        return 1
    fi

    local rules_file=/etc/nftables.d/infra-scripts.nft
    local service_file=/etc/systemd/system/infra-firewall.service
    local nft_bin
    nft_bin=$(command -v nft)

    local tmp
    tmp=$(mktemp)
    cat >"$tmp" <<EOF
# Managed by madwind/infra-scripts.
table inet infra_filter {
    chain input {
        type filter hook input priority 0; policy accept;

        ct state established,related accept
        iifname "lo" accept
        meta l4proto { icmp, ipv6-icmp } accept

        tcp dport $ssh_port accept
        udp dport { 51820, 51821 } accept
        tcp dport { 443, 10250 } accept
EOF

    if [ "$role" = server ]; then
        echo '        tcp dport 6443 accept' >>"$tmp"
    fi

    cat >>"$tmp" <<'EOF'

        ip saddr { 10.42.0.0/16, 10.43.0.0/16 } accept

        reject with icmpx type admin-prohibited
    }
}
EOF

    run_root install -D -m 0644 "$tmp" "$rules_file"
    rm -f "$tmp"

    tmp=$(mktemp)
    cat >"$tmp" <<EOF
[Unit]
Description=infra-scripts nftables firewall
DefaultDependencies=no
Wants=network-pre.target
Before=network-pre.target shutdown.target
Conflicts=shutdown.target

[Service]
Type=oneshot
ExecStartPre=-$nft_bin delete table inet infra_filter
ExecStart=$nft_bin -f $rules_file
ExecStop=-$nft_bin delete table inet infra_filter
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
EOF

    run_root install -m 0644 "$tmp" "$service_file"
    rm -f "$tmp"

    run_root systemctl daemon-reload
    run_root systemctl enable --now infra-firewall.service

    echo "nftables firewall enabled."
    run_root nft list table inet infra_filter
}

uninstall_previous_k3s() {
    echo "Uninstalling previous K3s installation..."

    if [ -x /usr/local/bin/k3s-uninstall.sh ]; then
        run_root /usr/local/bin/k3s-uninstall.sh
    elif [ -x /usr/local/bin/k3s-agent-uninstall.sh ]; then
        run_root /usr/local/bin/k3s-agent-uninstall.sh
    fi
}
