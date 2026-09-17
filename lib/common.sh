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

preflight_require_root() {
    if [ "$(id -u)" -ne 0 ] && ! command -v sudo >/dev/null 2>&1; then
        echo "Error: run as root or install sudo." >&2
        return 1
    fi
}

preflight_require_env() {
    local name
    local missing=0

    for name in "$@"; do
        if [ -z "${!name:-}" ]; then
            echo "Error: required environment variable is not set: $name" >&2
            missing=1
        fi
    done

    [ "$missing" -eq 0 ]
}

_install_package() {
    local package=$1

    if [ "$_APT_UPDATED" -eq 0 ]; then
        run_root env DEBIAN_FRONTEND=noninteractive apt-get update
        _APT_UPDATED=1
    fi

    run_root env DEBIAN_FRONTEND=noninteractive apt-get install -y "$package"
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

_install_systemd_resolved() {
    echo "Installing systemd-resolved..."
    _install_package systemd-resolved
}

setup_systemd_resolved_dot() {
    echo "Configuring DNS-over-TLS..."

    local dot_conf=/etc/systemd/resolved.conf.d/dot.conf
    local backup_dir
    local dns_servers
    local tmp

    backup_dir=$(mktemp -d)

    if [ -f "$dot_conf" ]; then
        cp "$dot_conf" "$backup_dir/dot.conf"
    fi

    if [ -e /etc/resolv.conf ] || [ -L /etc/resolv.conf ]; then
        cp -a /etc/resolv.conf "$backup_dir/resolv.conf"
    fi

    restore_resolved() {
        run_root rm -f "$dot_conf"
        if [ -f "$backup_dir/dot.conf" ]; then
            run_root install -D -m 0644 "$backup_dir/dot.conf" "$dot_conf"
        fi

        run_root rm -f /etc/resolv.conf
        if [ -e "$backup_dir/resolv.conf" ] || [ -L "$backup_dir/resolv.conf" ]; then
            run_root cp -a "$backup_dir/resolv.conf" /etc/resolv.conf
        fi

        run_root systemctl restart systemd-resolved.service >/dev/null 2>&1 || true
    }

    if ! command -v resolvectl >/dev/null 2>&1; then
        if ! _install_systemd_resolved; then
            restore_resolved
            rm -rf "$backup_dir"
            return 1
        fi
    fi

    # Some VPS images mask systemd-resolved by default.
    run_root systemctl unmask systemd-resolved.service >/dev/null 2>&1 || true
    if ! run_root systemctl enable --now systemd-resolved.service; then
        restore_resolved
        rm -rf "$backup_dir"
        return 1
    fi

    dns_servers="1.1.1.1#cloudflare-dns.com 1.0.0.1#cloudflare-dns.com 8.8.8.8#dns.google 8.8.4.4#dns.google"

    if ip -6 addr show scope global | grep -q 'inet6 ' \
        && ip -6 route get 2606:4700:4700::1111 >/dev/null 2>&1; then
        dns_servers="$dns_servers 2606:4700:4700::1111#cloudflare-dns.com 2606:4700:4700::1001#cloudflare-dns.com 2001:4860:4860::8888#dns.google 2001:4860:4860::8844#dns.google"
    fi

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

    if ! run_root systemctl restart systemd-resolved.service; then
        restore_resolved
        rm -rf "$backup_dir"
        return 1
    fi

    if ! resolvectl status 2>/dev/null | sed -n '/^Global$/,/^Link /p' | grep -q '+DNSOverTLS' \
        || ! timeout 20 resolvectl query example.com >/dev/null 2>&1; then
        echo "Error: DNS-over-TLS validation failed; restoring the previous resolver configuration." >&2
        restore_resolved
        rm -rf "$backup_dir"
        return 1
    fi

    if ! run_root ln -sfn /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf; then
        if command -v chattr >/dev/null 2>&1; then
            run_root chattr -i /etc/resolv.conf >/dev/null 2>&1 || true
        fi
        run_root rm -f /etc/resolv.conf
        run_root ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
    fi

    if ! timeout 20 getent ahosts example.com >/dev/null 2>&1; then
        echo "Error: system resolver validation failed; restoring the previous resolver configuration." >&2
        restore_resolved
        rm -rf "$backup_dir"
        return 1
    fi

    rm -rf "$backup_dir"

    echo "DNS-over-TLS enabled."
    resolvectl status | sed -n '1,14p'
}

setup_iptables_firewall() {
    local role=${1:-client}
    case "$role" in
        client|server) ;;
        *)
            echo "Error: unknown firewall role: $role" >&2
            return 1
            ;;
    esac

    echo "Configuring iptables firewall ($role)..."

    if ! command -v iptables >/dev/null 2>&1; then
        echo "Error: iptables is required but is not installed." >&2
        return 1
    fi

    local firewall_script=/usr/local/sbin/infra-iptables-firewall
    local service_file=/etc/systemd/system/infra-iptables-firewall.service
    local tmp

    tmp=$(mktemp)
    cat >"$tmp" <<'EOF_FIREWALL'
#!/bin/bash
set -euo pipefail

ROLE=${1:-client}
case "$ROLE" in
    client|server) ;;
    *)
        echo "Error: unknown firewall role: $ROLE" >&2
        exit 1
        ;;
esac

SSH_PORT=
if command -v sshd >/dev/null 2>&1; then
    SSH_PORT=$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2; exit }' || true)
fi
if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]]; then
    SSH_PORT=$(grep -i '^Port[[:space:]]' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -n1 || true)
fi
SSH_PORT=${SSH_PORT:-22}

if ! [[ "$SSH_PORT" =~ ^[0-9]+$ ]] || [ "$SSH_PORT" -lt 1 ] || [ "$SSH_PORT" -gt 65535 ]; then
    echo "Error: invalid SSH port: $SSH_PORT" >&2
    exit 1
fi

add_rule4() {
    if iptables -C INPUT -m comment --comment infra-scripts "$@" >/dev/null 2>&1; then
        return 0
    fi
    iptables -I INPUT 1 -m comment --comment infra-scripts "$@"
}

# Insert the terminal rule first; later allow rules are inserted above it.
add_rule4 -j REJECT --reject-with icmp-host-prohibited
add_rule4 -p tcp -m conntrack --ctstate NEW --dport "$SSH_PORT" -j ACCEPT
add_rule4 -i lo -j ACCEPT
add_rule4 -p icmp -j ACCEPT
add_rule4 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
add_rule4 -p udp --dport 51820 -j ACCEPT
add_rule4 -p udp --dport 51821 -j ACCEPT
add_rule4 -p tcp --dport 10250 -j ACCEPT
if [ "$ROLE" = server ]; then
    add_rule4 -p tcp --dport 6443 -j ACCEPT
fi
add_rule4 -p tcp --dport 443 -j ACCEPT
add_rule4 -s 10.42.0.0/16 -j ACCEPT
add_rule4 -s 10.43.0.0/16 -j ACCEPT

# Keep IPv6 from becoming unfiltered on dual-stack VPS hosts.
if command -v ip6tables >/dev/null 2>&1; then
    add_rule6() {
        if ip6tables -C INPUT -m comment --comment infra-scripts "$@" >/dev/null 2>&1; then
            return 0
        fi
        ip6tables -I INPUT 1 -m comment --comment infra-scripts "$@"
    }

    add_rule6 -j REJECT
    add_rule6 -p tcp -m conntrack --ctstate NEW --dport "$SSH_PORT" -j ACCEPT
    add_rule6 -i lo -j ACCEPT
    add_rule6 -p ipv6-icmp -j ACCEPT
    add_rule6 -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    add_rule6 -p udp --dport 51820 -j ACCEPT
    add_rule6 -p udp --dport 51821 -j ACCEPT
    add_rule6 -p tcp --dport 10250 -j ACCEPT
    if [ "$ROLE" = server ]; then
        add_rule6 -p tcp --dport 6443 -j ACCEPT
    fi
    add_rule6 -p tcp --dport 443 -j ACCEPT
fi
EOF_FIREWALL

    run_root install -m 0755 "$tmp" "$firewall_script"
    rm -f "$tmp"

    tmp=$(mktemp)
    cat >"$tmp" <<EOF_UNIT
[Unit]
Description=infra-scripts iptables firewall
After=local-fs.target netfilter-persistent.service ufw.service
Before=k3s.service k3s-agent.service

[Service]
Type=oneshot
ExecStart=$firewall_script $role
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_UNIT

    run_root install -m 0644 "$tmp" "$service_file"
    rm -f "$tmp"

    run_root systemctl daemon-reload
    run_root systemctl reenable infra-iptables-firewall.service >/dev/null

    if ! run_root systemctl restart infra-iptables-firewall.service; then
        echo "Error: failed to activate the iptables firewall." >&2
        return 1
    fi

    echo "iptables firewall enabled."
}

uninstall_previous_k3s() {
    echo "Uninstalling previous K3s installation..."

    if [ -x /usr/local/bin/k3s-uninstall.sh ]; then
        run_root /usr/local/bin/k3s-uninstall.sh
    elif [ -x /usr/local/bin/k3s-agent-uninstall.sh ]; then
        run_root /usr/local/bin/k3s-agent-uninstall.sh
    fi
}
