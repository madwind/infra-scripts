#!/bin/sh

get_external_ipv4() {
    external_ip=$(curl -4fsS --connect-timeout 5 --max-time 10 https://ifconfig.me/ip) || {
        echo "Error: failed to determine the external IPv4 address." >&2
        return 1
    }

    if ! printf '%s\n' "$external_ip" | awk -F. '
        NF != 4 { exit 1 }
        {
            for (i = 1; i <= 4; i++) {
                if ($i !~ /^[0-9]+$/ || $i < 0 || $i > 255) {
                    exit 1
                }
            }
        }
    '; then
        echo "Error: invalid external IPv4 address: $external_ip" >&2
        return 1
    fi

    printf '%s\n' "$external_ip"
}

download_k3s_installer() {
    destination=$1

    echo "Downloading K3s installer..."
    if ! curl -fsSL \
        --connect-timeout 10 \
        --max-time 60 \
        --retry 2 \
        https://get.k3s.io \
        -o "$destination"; then
        echo "Error: failed to download the K3s installer." >&2
        return 1
    fi

    if [ ! -s "$destination" ]; then
        echo "Error: downloaded K3s installer is empty." >&2
        return 1
    fi
}

uninstall_previous_k3s() {
    echo "Uninstalling previous K3s installation..."

    if [ -x /usr/local/bin/k3s-uninstall.sh ]; then
        run_root /usr/local/bin/k3s-uninstall.sh
    elif [ -x /usr/local/bin/k3s-agent-uninstall.sh ]; then
        run_root /usr/local/bin/k3s-agent-uninstall.sh
    fi
}
