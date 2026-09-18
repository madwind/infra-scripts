#!/bin/sh

uninstall_previous_k3s() {
    echo "Uninstalling previous K3s installation..."

    if [ -x /usr/local/bin/k3s-uninstall.sh ]; then
        run_root /usr/local/bin/k3s-uninstall.sh
    elif [ -x /usr/local/bin/k3s-agent-uninstall.sh ]; then
        run_root /usr/local/bin/k3s-agent-uninstall.sh
    fi
}
