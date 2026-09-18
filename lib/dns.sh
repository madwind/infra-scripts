#!/bin/sh

_install_systemd_resolved() {
    echo "Installing systemd-resolved..."
    _install_package systemd-resolved
}

setup_systemd_resolved_dot() {
    echo "Configuring DNS-over-TLS..."

    dot_conf=/etc/systemd/resolved.conf.d/dot.conf
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

    dot_tmp=$(mktemp)
    cat >"$dot_tmp" <<EOF_DOT
[Resolve]
DNS=$dns_servers
FallbackDNS=
Domains=~.
DNSSEC=no
DNSOverTLS=yes
DNSStubListener=yes
EOF_DOT

    run_root install -D -m 0644 "$dot_tmp" "$dot_conf"
    rm -f "$dot_tmp"

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

setup_pod_system_dns() {
    echo "Configuring Pod access to the node system resolver..."

    pod_dns_ip=${POD_SYSTEM_DNS_IP:-169.254.20.10}
    address_script=/usr/local/sbin/infra-node-local-address.sh
    address_service=/etc/systemd/system/infra-node-local-address.service
    resolved_dropin=/etc/systemd/system/systemd-resolved.service.d/infra-node-local-address.conf
    listener_conf=/etc/systemd/resolved.conf.d/pod-system-dns.conf

    address_tmp=$(mktemp)
    cat >"$address_tmp" <<EOF_ADDRESS_SCRIPT
#!/bin/sh
set -eu

ip address replace $pod_dns_ip/32 dev lo
EOF_ADDRESS_SCRIPT
    run_root install -m 0755 "$address_tmp" "$address_script"
    rm -f "$address_tmp"

    unit_tmp=$(mktemp)
    cat >"$unit_tmp" <<EOF_ADDRESS_UNIT
[Unit]
Description=infra-scripts node-local service address
DefaultDependencies=no
After=systemd-sysctl.service
Before=systemd-resolved.service sysinit.target k3s.service k3s-agent.service

[Service]
Type=oneshot
ExecStart=$address_script
RemainAfterExit=yes

[Install]
WantedBy=sysinit.target
EOF_ADDRESS_UNIT
    run_root install -m 0644 "$unit_tmp" "$address_service"
    rm -f "$unit_tmp"

    # Older versions made systemd-resolved depend on this service, which can
    # create an early-boot dependency cycle. The address service now starts
    # independently before systemd-resolved.
    run_root rm -f "$resolved_dropin"

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
