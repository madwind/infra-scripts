#!/bin/sh

enable_bbr() {
    echo "Enabling BBR..."

    bbr_tmp=$(mktemp)
    cat >"$bbr_tmp" <<'EOF_BBR'
net.core.default_qdisc = fq
net.ipv4.tcp_congestion_control = bbr
EOF_BBR

    run_root install -m 0644 "$bbr_tmp" /etc/sysctl.d/99-bbr.conf
    rm -f "$bbr_tmp"
    run_root sysctl -p /etc/sysctl.d/99-bbr.conf

    sysctl net.core.default_qdisc
    sysctl net.ipv4.tcp_congestion_control
}

enable_unattended_upgrades() {
    echo "Ensuring unattended upgrades are enabled..."

    if ! dpkg-query -W -f='${Status}\n' unattended-upgrades 2>/dev/null | grep -q '^install ok installed$'; then
        echo "unattended-upgrades not found; installing..."
        if ! _install_package unattended-upgrades; then
            echo "Error: failed to install unattended-upgrades." >&2
            return 1
        fi
    fi

    unattended_value=$(apt-config shell value APT::Periodic::Unattended-Upgrade 2>/dev/null \
        | sed -n "s/^value='\\(.*\\)'$/\\1/p" || true)
    update_lists_value=$(apt-config shell value APT::Periodic::Update-Package-Lists 2>/dev/null \
        | sed -n "s/^value='\\(.*\\)'$/\\1/p" || true)

    if [ "$unattended_value" != "1" ] || [ "$update_lists_value" != "1" ]; then
        auto_upgrade_tmp=$(mktemp)
        cat >"$auto_upgrade_tmp" <<'EOF_AUTO_UPGRADES'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
EOF_AUTO_UPGRADES
        run_root install -m 0644 "$auto_upgrade_tmp" /etc/apt/apt.conf.d/99infra-unattended-upgrades
        rm -f "$auto_upgrade_tmp"
    fi

    run_root systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null
    echo "unattended-upgrades enabled."
}
