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

    # Convert 05:00 UTC+8 to the host's local time without changing its timezone.
    # Re-run this setup after a DST offset change on hosts that observe DST.
    reboot_time=$(env -u TZ date -d 'TZ="Asia/Shanghai" tomorrow 05:00' +%H:%M)
    auto_upgrade_tmp=$(mktemp)
    cat >"$auto_upgrade_tmp" <<EOF_AUTO_UPGRADES
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
Unattended-Upgrade::Automatic-Reboot "true";
Unattended-Upgrade::Automatic-Reboot-WithUsers "false";
Unattended-Upgrade::Automatic-Reboot-Time "$reboot_time";
EOF_AUTO_UPGRADES
    run_root install -m 0644 "$auto_upgrade_tmp" /etc/apt/apt.conf.d/99infra-unattended-upgrades
    rm -f "$auto_upgrade_tmp"

    run_root systemctl enable --now apt-daily.timer apt-daily-upgrade.timer >/dev/null
    echo "unattended-upgrades enabled; automatic reboot at $reboot_time local time (05:00 UTC+8)."
}
