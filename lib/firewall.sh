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
        echo "iptables not found; installing..."
        if ! _install_package iptables; then
            echo "Error: failed to install iptables." >&2
            return 1
        fi
    fi

    if ! command -v iptables >/dev/null 2>&1; then
        echo "Error: iptables is still unavailable after installation." >&2
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

remove_old_input_rules() {
    command_name=$1
    keep_chain=$2

    while true; do
        rule=$($command_name -w 5 -S INPUT 2>/dev/null \
            | grep -- '--comment infra-scripts' \
            | grep -v -- "-j $keep_chain" \
            | head -n1 || true)
        [ -n "$rule" ] || break
        rule=${rule#-A INPUT }
        # shellcheck disable=SC2086
        $command_name -w 5 -D INPUT $rule
    done
}

remove_stale_chains() {
    command_name=$1
    keep_chain=$2

    for chain in $($command_name -w 5 -S 2>/dev/null \
        | awk '$1 == "-N" && ($2 == "INFRA-INPUT" || $2 ~ /^INFRA-INPUT-/) { print $2 }'); do
        [ "$chain" = "$keep_chain" ] && continue
        $command_name -w 5 -F "$chain" >/dev/null 2>&1 || true
        $command_name -w 5 -X "$chain" >/dev/null 2>&1 || true
    done
}

configure_ipv4() {
    new_chain="INFRA-INPUT-$$"
    iptables -w 5 -N "$new_chain"

    iptables -w 5 -A "$new_chain" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    iptables -w 5 -A "$new_chain" -p icmp -j ACCEPT
    iptables -w 5 -A "$new_chain" -i lo -j ACCEPT
    iptables -w 5 -A "$new_chain" -p tcp -m conntrack --ctstate NEW --dport "$SSH_PORT" -j ACCEPT
    iptables -w 5 -A "$new_chain" -p udp --dport 51820 -j ACCEPT
    iptables -w 5 -A "$new_chain" -p udp --dport 51821 -j ACCEPT
    iptables -w 5 -A "$new_chain" -p tcp --dport 10250 -j ACCEPT
    if [ "$ROLE" = server ]; then
        iptables -w 5 -A "$new_chain" -p tcp --dport 6443 -j ACCEPT
    fi
    iptables -w 5 -A "$new_chain" -p tcp --dport 443 -j ACCEPT
    iptables -w 5 -A "$new_chain" -s 10.42.0.0/16 -j ACCEPT
    iptables -w 5 -A "$new_chain" -s 10.43.0.0/16 -j ACCEPT
    iptables -w 5 -A "$new_chain" -j REJECT --reject-with icmp-host-prohibited

    # The complete replacement chain is built before traffic is switched to it.
    iptables -w 5 -I INPUT 1 -m comment --comment infra-scripts -j "$new_chain"
    remove_old_input_rules iptables "$new_chain"
    remove_stale_chains iptables "$new_chain"
}

configure_ipv6() {
    new_chain="INFRA-INPUT-$$"
    ip6tables -w 5 -N "$new_chain"

    ip6tables -w 5 -A "$new_chain" -m conntrack --ctstate RELATED,ESTABLISHED -j ACCEPT
    ip6tables -w 5 -A "$new_chain" -p ipv6-icmp -j ACCEPT
    ip6tables -w 5 -A "$new_chain" -i lo -j ACCEPT
    ip6tables -w 5 -A "$new_chain" -p tcp -m conntrack --ctstate NEW --dport "$SSH_PORT" -j ACCEPT
    ip6tables -w 5 -A "$new_chain" -p udp --dport 51820 -j ACCEPT
    ip6tables -w 5 -A "$new_chain" -p udp --dport 51821 -j ACCEPT
    ip6tables -w 5 -A "$new_chain" -p tcp --dport 10250 -j ACCEPT
    if [ "$ROLE" = server ]; then
        ip6tables -w 5 -A "$new_chain" -p tcp --dport 6443 -j ACCEPT
    fi
    ip6tables -w 5 -A "$new_chain" -p tcp --dport 443 -j ACCEPT
    ip6tables -w 5 -A "$new_chain" -j REJECT

    ip6tables -w 5 -I INPUT 1 -m comment --comment infra-scripts -j "$new_chain"
    remove_old_input_rules ip6tables "$new_chain"
    remove_stale_chains ip6tables "$new_chain"
}

configure_ipv4
if command -v ip6tables >/dev/null 2>&1; then
    configure_ipv6
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
