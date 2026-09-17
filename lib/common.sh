#!/bin/bash

_APT_UPDATED=0

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

_run_timeout() {
    local seconds=$1
    shift

    if command -v timeout >/dev/null 2>&1; then
        timeout "$seconds" "$@"
    else
        "$@"
    fi
}

_install_package() {
    local package=$1

    if command -v apt-get >/dev/null 2>&1; then
        if [ "$_APT_UPDATED" -eq 0 ]; then
            run_root env DEBIAN_FRONTEND=noninteractive apt-get update
            _APT_UPDATED=1
        fi
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

enable_bbr() {
    echo "Enabling BBR..."

    local tmp
    tmp=$(mktemp)
    cat >"$tmp" <<'EOF_BBR'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF_BBR

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
    local old_resolv_dir
    local had_old_dot=0
    local had_old_resolv=0
    local original_resolved_state
    local original_resolved_active=0

    old_dot=$(mktemp)
    old_resolv_dir=$(mktemp -d)

    if [ -f "$dot_conf" ]; then
        cat "$dot_conf" >"$old_dot"
        had_old_dot=1
    fi

    if [ -e /etc/resolv.conf ] || [ -L /etc/resolv.conf ]; then
        cp -a /etc/resolv.conf "$old_resolv_dir/resolv.conf"
        had_old_resolv=1

        if [ ! -e "$resolv_backup" ] && [ ! -L "$resolv_backup" ] \
            && [ "$(readlink -f /etc/resolv.conf 2>/dev/null || true)" != "/run/systemd/resolve/stub-resolv.conf" ]; then
            run_root cp -a /etc/resolv.conf "$resolv_backup"
        fi
    fi

    original_resolved_state=$(systemctl is-enabled systemd-resolved.service 2>/dev/null || true)
    if systemctl is-active --quiet systemd-resolved.service 2>/dev/null; then
        original_resolved_active=1
    fi

    restore_resolved() {
        if [ "$had_old_dot" -eq 1 ]; then
            run_root install -D -m 0644 "$old_dot" "$dot_conf"
        else
            run_root rm -f "$dot_conf"
        fi

        run_root rm -f /etc/resolv.conf
        if [ "$had_old_resolv" -eq 1 ] && { [ -e "$old_resolv_dir/resolv.conf" ] || [ -L "$old_resolv_dir/resolv.conf" ]; }; then
            run_root cp -a "$old_resolv_dir/resolv.conf" /etc/resolv.conf
        fi

        run_root systemctl daemon-reload >/dev/null 2>&1 || true

        if [ "$original_resolved_state" = masked ]; then
            run_root systemctl stop systemd-resolved.service >/dev/null 2>&1 || true
            run_root systemctl mask systemd-resolved.service >/dev/null 2>&1 || true
        else
            if [ "$original_resolved_state" = disabled ]; then
                run_root systemctl disable systemd-resolved.service >/dev/null 2>&1 || true
            fi

            if [ "$original_resolved_active" -eq 1 ]; then
                run_root systemctl restart systemd-resolved.service >/dev/null 2>&1 || true
            else
                run_root systemctl stop systemd-resolved.service >/dev/null 2>&1 || true
            fi
        fi
    }

    if ! command -v resolvectl >/dev/null 2>&1; then
        if ! _install_systemd_resolved; then
            restore_resolved
            rm -f "$old_dot"
            rm -rf "$old_resolv_dir"
            return 1
        fi
    fi

    if ! command -v resolvectl >/dev/null 2>&1; then
        echo "Error: resolvectl is unavailable after installing systemd-resolved." >&2
        restore_resolved
        rm -f "$old_dot"
        rm -rf "$old_resolv_dir"
        return 1
    fi

    # Some VPS images, including some DMIT images, mask systemd-resolved.
    run_root systemctl unmask systemd-resolved.service >/dev/null 2>&1 || true
    run_root systemctl daemon-reload
    run_root systemctl enable --now systemd-resolved.service

    local dns_servers
    dns_servers="1.1.1.1#cloudflare-dns.com 1.0.0.1#cloudflare-dns.com 8.8.8.8#dns.google 8.8.4.4#dns.google"

    # Add IPv6 resolvers when the host has a global IPv6 address and route.
    if command -v ip >/dev/null 2>&1 \
        && ip -6 addr show scope global | grep -q 'inet6 ' \
        && ip -6 route get 2606:4700:4700::1111 >/dev/null 2>&1; then
        dns_servers="$dns_servers 2606:4700:4700::1111#cloudflare-dns.com 2606:4700:4700::1001#cloudflare-dns.com 2001:4860:4860::8888#dns.google 2001:4860:4860::8844#dns.google"
    fi

    local tmp
    tmp=$(mktemp)
    cat >"$tmp" <<EOF_DOT
[Resolve]
DNS=$dns_servers
FallbackDNS=
Domains=~.
DNSSEC=no
DNSOverTLS=yes
DNSStubListener=yes
EOF_DOT

    run_root install -D -m 0644 "$tmp" "$dot_conf"
    rm -f "$tmp"
    run_root systemctl restart systemd-resolved.service

    if ! resolvectl status 2>/dev/null | sed -n '/^Global$/,/^Link /p' | grep -q '+DNSOverTLS'; then
        echo "Error: this systemd-resolved build did not enable DNS-over-TLS." >&2
        restore_resolved
        rm -f "$old_dot"
        rm -rf "$old_resolv_dir"
        return 1
    fi

    resolvectl flush-caches >/dev/null 2>&1 || true
    if ! _run_timeout 20 resolvectl query example.com >/dev/null 2>&1; then
        echo "Error: DNS-over-TLS validation failed; restoring the previous resolver configuration." >&2
        restore_resolved
        rm -f "$old_dot"
        rm -rf "$old_resolv_dir"
        return 1
    fi

    if ! run_root ln -sfn /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf; then
        if command -v chattr >/dev/null 2>&1; then
            run_root chattr -i /etc/resolv.conf >/dev/null 2>&1 || true
        fi
        run_root rm -f /etc/resolv.conf
        run_root ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    fi

    run_root systemctl restart systemd-resolved.service

    if ! _run_timeout 20 getent ahosts example.com >/dev/null 2>&1; then
        echo "Error: system resolver validation failed; rolling back." >&2
        restore_resolved
        rm -f "$old_dot"
        rm -rf "$old_resolv_dir"
        return 1
    fi

    rm -f "$old_dot"
    rm -rf "$old_resolv_dir"

    echo "DNS-over-TLS enabled."
    resolvectl status | sed -n '1,14p'
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
        || ! grep -q '^add_rule -s 10\.42\.0\.0/16 -j ACCEPT$' "$rc_local" \
        || ! grep -q '^add_rule -s 10\.43\.0\.0/16 -j ACCEPT$' "$rc_local"; then
        return 0
    fi

    echo "Migrating legacy infra-scripts iptables firewall..."

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

    # Disable only the rules generated by the previous infra-scripts version.
    run_root sed -i \
        -e '/^add_rule -j REJECT --reject-with icmp-host-prohibited$/s/^/# migrated to nftables: /' \
        -e '/^add_rule -p tcp -m state --state NEW -m tcp --dport "\$SSH_PORT" -j ACCEPT$/s/^/# migrated to nftables: /' \
        -e '/^add_rule -i lo -j ACCEPT$/s/^/# migrated to nftables: /' \
        -e '/^add_rule -p icmp -j ACCEPT$/s/^/# migrated to nftables: /' \
        -e '/^add_rule -m state --state RELATED,ESTABLISHED -j ACCEPT$/s/^/# migrated to nftables: /' \
        -e '/^add_rule -p udp -m udp --dport 51820 -j ACCEPT$/s/^/# migrated to nftables: /' \
        -e '/^add_rule -p udp -m udp --dport 51821 -j ACCEPT$/s/^/# migrated to nftables: /' \
        -e '/^add_rule -p tcp -m tcp --dport 10250 -j ACCEPT$/s/^/# migrated to nftables: /' \
        -e '/^add_rule -p tcp -m tcp --dport 6443 -j ACCEPT$/s/^/# migrated to nftables: /' \
        -e '/^add_rule -p tcp -m tcp --dport 443 -j ACCEPT$/s/^/# migrated to nftables: /' \
        -e '/^add_rule -s 10\.42\.0\.0\/16 -j ACCEPT$/s/^/# migrated to nftables: /' \
        -e '/^add_rule -s 10\.43\.0\.0\/16 -j ACCEPT$/s/^/# migrated to nftables: /' \
        "$rc_local"
}

_detect_ssh_port() {
    local port=

    # When run over SSH, the current connection is the safest source of truth.
    if [ -n "${SSH_CONNECTION:-}" ]; then
        port=${SSH_CONNECTION##* }
    fi

    if ! [[ "$port" =~ ^[0-9]+$ ]] && command -v sshd >/dev/null 2>&1; then
        port=$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2; exit }' || true)
    fi

    if ! [[ "$port" =~ ^[0-9]+$ ]]; then
        port=$(grep -i '^Port[[:space:]]' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -n1 || true)
    fi

    port=${port:-22}

    if ! [[ "$port" =~ ^[0-9]+$ ]] || [ "$port" -lt 1 ] || [ "$port" -gt 65535 ]; then
        echo "Error: invalid SSH port: $port" >&2
        return 1
    fi

    printf '%s\n' "$port"
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

    if ! command -v nft >/dev/null 2>&1; then
        echo "Error: nft is unavailable after installing nftables." >&2
        return 1
    fi

    local ssh_port
    ssh_port=$(_detect_ssh_port)

    local rules_file=/etc/nftables.d/infra-scripts.nft
    local service_file=/etc/systemd/system/infra-firewall.service
    local nft_bin
    nft_bin=$(command -v nft)

    local tmp check_tmp check_table
    tmp=$(mktemp)
    cat >"$tmp" <<EOF_NFT
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
EOF_NFT

    if [ "$role" = server ]; then
        echo '        tcp dport 6443 accept' >>"$tmp"
    fi

    cat >>"$tmp" <<'EOF_NFT'

        ip saddr { 10.42.0.0/16, 10.43.0.0/16 } accept

        reject with icmpx type admin-prohibited
    }
}
EOF_NFT

    # Check syntax and kernel feature support without touching the active table.
    check_table="infra_filter_check_$$"
    check_tmp=$(mktemp)
    sed "s/table inet infra_filter/table inet $check_table/" "$tmp" >"$check_tmp"
    if ! run_root "$nft_bin" -c -f "$check_tmp"; then
        echo "Error: generated nftables rules are not supported by this host." >&2
        rm -f "$tmp" "$check_tmp"
        return 1
    fi
    rm -f "$check_tmp"

    run_root install -D -m 0644 "$tmp" "$rules_file"
    rm -f "$tmp"

    tmp=$(mktemp)
    cat >"$tmp" <<EOF_UNIT
[Unit]
Description=infra-scripts nftables firewall
After=local-fs.target nftables.service
Before=network-pre.target
Wants=network-pre.target

[Service]
Type=oneshot
ExecStartPre=-$nft_bin delete table inet infra_filter
ExecStart=$nft_bin -f $rules_file
ExecStop=-$nft_bin delete table inet infra_filter
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_UNIT

    run_root install -m 0644 "$tmp" "$service_file"
    rm -f "$tmp"

    run_root systemctl daemon-reload
    run_root systemctl reenable infra-firewall.service >/dev/null

    if ! run_root systemctl restart infra-firewall.service; then
        echo "Error: failed to activate the nftables firewall." >&2
        return 1
    fi

    if ! run_root "$nft_bin" list table inet infra_filter >/dev/null 2>&1; then
        echo "Error: infra_filter table is not active after service restart." >&2
        return 1
    fi

    # Remove the old repository-generated iptables rules only after nftables is active.
    _migrate_legacy_iptables_firewall

    echo "nftables firewall enabled."
    run_root "$nft_bin" list table inet infra_filter
}

uninstall_previous_k3s() {
    echo "Uninstalling previous K3s installation..."

    if [ -x /usr/local/bin/k3s-uninstall.sh ]; then
        run_root /usr/local/bin/k3s-uninstall.sh
    elif [ -x /usr/local/bin/k3s-agent-uninstall.sh ]; then
        run_root /usr/local/bin/k3s-agent-uninstall.sh
    fi
}
