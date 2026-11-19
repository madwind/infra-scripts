#!/bin/sh

_install_systemd_resolved() {
    echo "Installing systemd-resolved..."
    _install_package systemd-resolved
}

_link_systemd_resolved_stub() {
    if run_root ln -sfn /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf; then
        return 0
    fi
    if command -v chattr >/dev/null 2>&1; then
        run_root chattr -i /etc/resolv.conf >/dev/null 2>&1 || true
    fi
    run_root rm -f /etc/resolv.conf &&
        run_root ln -s /run/systemd/resolve/stub-resolv.conf /etc/resolv.conf
}

setup_systemd_resolved_doh() (
    set -e
    echo "Configuring DNS-over-HTTPS..."

    dns_tmp=$(mktemp -d)
    trap 'rm -rf "$dns_tmp"' 0
    proxy_bin=/usr/sbin/dnscrypt-proxy
    proxy_conf=/etc/infra-scripts/dnscrypt-proxy.toml
    proxy_unit_conf=/etc/systemd/system/dnscrypt-proxy.service.d/infra-scripts.conf
    resolved_conf=/etc/systemd/resolved.conf.d/infra-system-dns.conf

    if ! command -v resolvectl >/dev/null 2>&1; then
        _install_systemd_resolved
    fi

    # Some VPS images mask systemd-resolved by default.
    run_root systemctl unmask systemd-resolved.service >/dev/null 2>&1 || true
    run_root systemctl enable --now systemd-resolved.service

    # The script manages resolved explicitly. Prevent the package's resolvconf
    # integration from changing DNS when apt starts the proxy.
    run_root systemctl mask dnscrypt-proxy-resolvconf.service
    if systemctl is-active --quiet dnscrypt-proxy-resolvconf.service; then
        run_root systemctl stop dnscrypt-proxy-resolvconf.service
    fi
    if [ ! -x "$proxy_bin" ]; then
        _install_package dnscrypt-proxy
    fi
    if ! command -v dig >/dev/null 2>&1; then
        _install_package bind9-dnsutils
    fi

    cat >"$dns_tmp/proxy.toml" <<'EOF_PROXY'
# The packaged socket listens on 127.0.2.1:53 for TCP and UDP.
listen_addresses = []
server_names = ['cloudflare']
dnscrypt_servers = false
doh_servers = true

[static.'cloudflare']
# 1.1.1.1:443, TLS name cloudflare-dns.com, path /dns-query.
stamp = 'sdns://AgcAAAAAAAAABzEuMS4xLjEAEmNsb3VkZmxhcmUtZG5zLmNvbQovZG5zLXF1ZXJ5'
EOF_PROXY
    "$proxy_bin" -config "$dns_tmp/proxy.toml" -check
    run_root install -D -m 0644 "$dns_tmp/proxy.toml" "$proxy_conf"

    cat >"$dns_tmp/proxy-unit.conf" <<EOF_PROXY_UNIT
[Service]
ExecStart=
ExecStart=$proxy_bin -config $proxy_conf
EOF_PROXY_UNIT
    run_root install -D -m 0644 "$dns_tmp/proxy-unit.conf" "$proxy_unit_conf"
    run_root systemctl daemon-reload
    run_root systemctl enable --now dnscrypt-proxy.socket
    run_root systemctl restart dnscrypt-proxy.service

    proxy_attempt=1
    until dig +time=2 +tries=1 +short @127.0.2.1 example.com A \
        | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$'; do
        if [ "$proxy_attempt" -ge 5 ]; then
            echo "Error: local DNS-over-HTTPS proxy validation failed." >&2
            exit 1
        fi
        proxy_attempt=$((proxy_attempt + 1))
        sleep 1
    done

    # This drop-in sorts after the previous dot.conf. The empty DNS= clears
    # its public upstreams, and removing this drop-in restores that setup.
    cat >"$dns_tmp/resolved.conf" <<'EOF_RESOLVED'
[Resolve]
DNS=
DNS=127.0.2.1
FallbackDNS=
Domains=~.
DNSSEC=no
DNSOverTLS=no
DNSStubListener=yes
EOF_RESOLVED
    if run_root test -e "$resolved_conf"; then
        run_root cp -p "$resolved_conf" "$dns_tmp/previous-resolved.conf"
    fi
    if [ -e /etc/resolv.conf ] || [ -L /etc/resolv.conf ]; then
        run_root cp -pP /etc/resolv.conf "$dns_tmp/previous-resolv.conf"
    fi
    run_root install -D -m 0644 "$dns_tmp/resolved.conf" "$resolved_conf"

    stub_changed=no
    if run_root systemctl restart systemd-resolved.service \
        && resolvectl dns | grep -Eq '^Global:[[:space:]]+127\.0\.2\.1$' \
        && timeout 20 resolvectl query -4 example.com >/dev/null 2>&1; then
        stub_changed=yes
        if _link_systemd_resolved_stub && timeout 20 getent ahosts example.com >/dev/null 2>&1; then
            echo "DNS-over-HTTPS enabled."
            resolvectl status | sed -n '1,14p'
            exit 0
        fi
    fi

    echo "Error: DNS-over-HTTPS validation failed; restoring the previous DNS configuration." >&2
    if [ -f "$dns_tmp/previous-resolved.conf" ]; then
        run_root install -m 0644 "$dns_tmp/previous-resolved.conf" "$resolved_conf"
    else
        run_root rm -f "$resolved_conf"
    fi
    if [ "$stub_changed" = yes ]; then
        if [ -e "$dns_tmp/previous-resolv.conf" ] || [ -L "$dns_tmp/previous-resolv.conf" ]; then
            run_root cp -pP --remove-destination "$dns_tmp/previous-resolv.conf" /etc/resolv.conf
        else
            run_root rm -f /etc/resolv.conf
        fi
    fi
    run_root systemctl restart systemd-resolved.service
    exit 1
)

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
