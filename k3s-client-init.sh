#!/bin/bash

# -----bbr-----
echo "Enabling BBR..."
sudo sed -i '/^[a-zA-Z]/d' /etc/sysctl.conf
echo "net.core.default_qdisc = fq" | sudo tee -a /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control = bbr" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
lsmod | grep bbr
sudo sysctl -a | grep tcp_congestion_control

# -----ip_vs-----
echo "Enabling IPVS..."
sudo modprobe ip_vs
echo "ip_vs" | sudo tee -a /etc/modules-load.d/ipvs.conf
lsmod | grep ip_vs

# -----iptables-----
echo "Setting up iptables rules..."
sudo tee /etc/rc.local > /dev/null <<'EOF'
#!/bin/bash
set -euo pipefail

SSH_PORT=$(grep -i '^Port' /etc/ssh/sshd_config | awk '{print $2}' || true)
SSH_PORT=${SSH_PORT:-22}

add_rule() {
    if iptables -C INPUT "$@" 2>/dev/null; then
        echo "Rule exists: $*"
    else
        echo "Inserting rule: $*"
        iptables -I INPUT 1 "$@"
    fi
}


add_rule -j REJECT --reject-with icmp-host-prohibited
add_rule -p tcp -m state --state NEW -m tcp --dport "$SSH_PORT" -j ACCEPT
add_rule -i lo -j ACCEPT
add_rule -p icmp -j ACCEPT
add_rule -m state --state RELATED,ESTABLISHED -j ACCEPT
add_rule -p udp -m udp --dport 51820 -j ACCEPT
add_rule -p udp -m udp --dport 51821 -j ACCEPT
add_rule -p tcp -m tcp --dport 10250 -j ACCEPT
add_rule -p tcp -m tcp --dport 443 -j ACCEPT
add_rule -s 10.42.0.0/16 -j ACCEPT
add_rule -s 10.43.0.0/16 -j ACCEPT

exit 0
EOF

sudo chmod +x /etc/rc.local
sudo /etc/rc.local

# -----uninstall previous k3s-----
echo "Uninstalling previous K3s installation..."
if [ -f /usr/local/bin/k3s-uninstall.sh ]; then
    k3s-uninstall.sh
elif [ -f /usr/local/bin/k3s-agent-uninstall.sh ]; then
    k3s-agent-uninstall.sh
fi

# -----k3s installation-----
echo "Installing K3s..."
export K3S_URL=https://${DOMAIN}:6443
export K3S_EXTERNAL_IP=`curl -4 ifconfig.me`
export INSTALL_K3S_EXEC="
--node-external-ip $K3S_EXTERNAL_IP
--kube-proxy-arg proxy-mode=ipvs
"
curl -sfL https://get.k3s.io | sh -
echo "done."
