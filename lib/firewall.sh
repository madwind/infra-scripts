#!/bin/sh

setup_iptables_firewall() {
    role=${1:-client}
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

    firewall_script=/usr/local/sbin/infra-iptables-firewall
    service_file=/etc/systemd/system/infra-iptables-firewall.service
    firewall_tmp=$(mktemp)

    cat >"$firewall_tmp" <<'EOF_FIREWALL'
#!/bin/sh
set -eu

ROLE=${1:-client}
case "$ROLE" in
    client|server) ;;
    *)
        echo "Error: unknown firewall role: $ROLE" >&2
        exit 1
        ;;
esac

valid_port() {
    case "${1:-}" in
        ''|*[!0-9]*) return 1 ;;
    esac
    [ "$1" -ge 1 ] && [ "$1" -le 65535 ]
}

SSH_PORT=
if command -v sshd >/dev/null 2>&1; then
    SSH_PORT=$(sshd -T 2>/dev/null | awk '$1 == "port" { print $2; exit }' || true)
fi
if ! valid_port "$SSH_PORT"; then
    SSH_PORT=$(grep -i '^Port[[:space:]]' /etc/ssh/sshd_config 2>/dev/null | awk '{print $2}' | head -n1 || true)
fi
SSH_PORT=${SSH_PORT:-22}

if ! valid_port "$SSH_PORT"; then
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

    run_root install -m 0755 "$firewall_tmp" "$firewall_script"
    rm -f "$firewall_tmp"

    unit_tmp=$(mktemp)
    cat >"$unit_tmp" <<EOF_UNIT
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

    run_root install -m 0644 "$unit_tmp" "$service_file"
    rm -f "$unit_tmp"

    run_root systemctl daemon-reload
    run_root systemctl reenable infra-iptables-firewall.service >/dev/null

    if ! run_root systemctl restart infra-iptables-firewall.service; then
        echo "Error: failed to activate the iptables firewall." >&2
        return 1
    fi

    echo "iptables firewall enabled."
}
