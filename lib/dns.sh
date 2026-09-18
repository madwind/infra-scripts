#!/bin/sh

_install_systemd_resolved() {
    echo "Installing systemd-resolved..."
    _install_package systemd-resolved
}

setup_systemd_resolved_dot() {
    echo "Configuring DNS-over-TLS..."

    dot_conf=/etc/systemd/resolved.conf.d/dot.conf

    if ! command -v resolvectl >/dev/null 2>&1; then
        _install_systemd_resolved
    fi

    # Some VPS images mask systemd-resolved by default.
    run_root systemctl unmask systemd-resolved.service >/dev/null 2>&1 || true
    run_root systemctl enable --now systemd-resolved.service

    dot_tmp=$(mktemp)
    cat >"$dot_tmp" <<'EOF_DOT'
[Resolve]
DNS=1.1.1.1#cloudflare-dns.com 8.8.8.8#dns.google
FallbackDNS=
Domains=~.
DNSSEC=no
DNSOverTLS=yes
DNSStubListener=yes
EOF_DOT

    run_root install -D -m 0644 "$dot_tmp" "$dot_conf"
    rm -f "$dot_tmp"

    run_root systemctl restart systemd-resolved.service

    if ! resolvectl status 2>/dev/null | sed -n '/^Global$/,/^Link /p' | grep -q '+DNSOverTLS' \
        || ! timeout 20 resolvectl query example.com >/dev/null 2>&1; then
        echo "Error: DNS-over-TLS validation failed." >&2
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
        echo "Error: system resolver validation failed." >&2
        return 1
    fi

    echo "DNS-over-TLS enabled."
    resolvectl status | sed -n '1,14p'
}

setup_pod_system_dns() {
    echo "Configuring Pod access to the node system resolver..."

    pod_dns_ip=${POD_SYSTEM_DNS_IP:-10.254.254.54}
    address_service=/etc/systemd/system/infra-node-local-address.service
    listener_conf=/etc/systemd/resolved.conf.d/pod-system-dns.conf

    unit_tmp=$(mktemp)
    cat >"$unit_tmp" <<EOF_ADDRESS_UNIT
[Unit]
Description=infra-scripts node-local DNS address
Before=k3s.service k3s-agent.service

[Service]
Type=oneshot
ExecStart=/usr/sbin/ip address replace $pod_dns_ip/32 dev lo
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF_ADDRESS_UNIT
    run_root install -m 0644 "$unit_tmp" "$address_service"
    rm -f "$unit_tmp"

    listener_tmp=$(mktemp)
    cat >"$listener_tmp" <<EOF_LISTENER
[Resolve]
DNSStubListenerExtra=$pod_dns_ip
EOF_LISTENER
    run_root install -D -m 0644 "$listener_tmp" "$listener_conf"
    rm -f "$listener_tmp"

    run_root systemctl daemon-reload
    run_root systemctl reenable infra-node-local-address.service >/dev/null
    run_root systemctl restart infra-node-local-address.service
    run_root systemctl restart systemd-resolved.service

    if ! ip -4 addr show dev lo | grep -Fq " $pod_dns_ip/32 "; then
        echo "Error: node-local DNS address was not added to loopback." >&2
        return 1
    fi

    if ! ss -H -lntu | grep -Fq "$pod_dns_ip:53"; then
        echo "Error: systemd-resolved is not listening on $pod_dns_ip:53." >&2
        return 1
    fi

    echo "Pod system DNS enabled at $pod_dns_ip:53."
}
