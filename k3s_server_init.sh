#!/bin/bash

# -----bbr-----
echo "Enabling BBR..."
sudo sed -i '/net.core.default_qdisc/d' /etc/sysctl.conf
sudo sed -i '/net.ipv4.tcp_congestion_control/d' /etc/sysctl.conf
echo "net.core.default_qdisc = fq" | sudo tee -a /etc/sysctl.conf
echo "net.ipv4.tcp_congestion_control = bbr" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
lsmod | grep bbr
sudo sysctl -a | grep tcp_congestion_control
echo "BBR enabled"

# -----ip_vs-----
echo "Enabling IPVS..."
sudo modprobe ip_vs
echo "ip_vs" | sudo tee -a /etc/modules-load.d/ipvs.conf
lsmod | grep ip_vs
echo "IPVS enabled"

# -----iptables-----
echo "Setting up iptables rules..."
sudo tee /etc/rc.local > /dev/null <<'EOF'
#!/bin/bash
sudo iptables -I INPUT -p tcp --dport 443 -j ACCEPT
sudo iptables -I INPUT -p tcp --dport 6443 -j ACCEPT
sudo iptables -I INPUT -p udp --dport 51820 -j ACCEPT
sudo iptables -I INPUT -p udp --dport 51821 -j ACCEPT
sudo iptables -I INPUT -p tcp --dport 10250 -j ACCEPT
EOF
sudo chmod +x /etc/rc.local
sudo /etc/rc.local
echo "Iptables rules set"

# -----uninstall k3s-----
k3s-uninstall.sh

# -----k3s installation-----
echo "Installing K3s..."
export HOSTNAME=$(hostname)
export INSTALL_K3S_EXEC="server
--tls-san $DOMAIN
--write-kubeconfig /root/.kube/config
--flannel-backend wireguard-native
--disable traefik,servicelb
--kube-proxy-arg proxy-mode=ipvs
"

curl -sfL https://get.k3s.io | sh -

# 获取并修改 kubeconfig
echo "Modifying Kubeconfig..."
NEW_KUBECONFIG=$(sudo sed -e "s|server: https://127.0.0.1:6443|server: https://$DOMAIN:6443|" \
                        -e "s|default|$HOSTNAME|g" \
                        /root/.kube/config | base64 -w 0)

# 将 kubeconfig 保存到 Cloudflare D1
echo "Saving Kubeconfig to Cloudflare D1..."
curl -X POST https://api.cloudflare.com/client/v4/accounts/$ACCOUNT_ID/d1/database/$DATABASE_ID/query \
    -H 'Content-Type: application/json' \
    -H "Authorization: Bearer $API_TOKEN" \
    -d '{
          "sql": "INSERT OR REPLACE INTO config (cluster_name, config_content) VALUES (?, ?);",
          "params": [
            "'$HOSTNAME'",
            "'$NEW_KUBECONFIG'"
          ]
        }'
echo "Kubeconfig saved to Cloudflare D1"
