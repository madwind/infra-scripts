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

_install_systemd_resolved() {
    echo "Installing systemd-resolved..."

    if command -v apt-get >/dev/null 2>&1; then
        run_root env DEBIAN_FRONTEND=noninteractive apt-get update
        run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y systemd-resolved
    elif command -v dnf >/dev/null 2>&1; then
        run_root dnf install -y systemd-resolved
    elif command -v yum >/dev/null 2>&1; then
        run_root yum install -y systemd-resolved
    else
        echo "Error: systemd-resolved is not installed and no supported package manager was found." >&2
        return 1
    fi
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

uninstall_previous_k3s() {
    echo "Uninstalling previous K3s installation..."

    if [ -x /usr/local/bin/k3s-uninstall.sh ]; then
        run_root /usr/local/bin/k3s-uninstall.sh
    elif [ -x /usr/local/bin/k3s-agent-uninstall.sh ]; then
        run_root /usr/local/bin/k3s-agent-uninstall.sh
    fi
}
