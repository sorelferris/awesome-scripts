#!/bin/bash

# ===== Interactive input =====
read -p "Please enter the Master node IP: " MASTER_IP
read -p "Please enter the Master node token: " MASTER_TOKEN
read -p "Please enter the Worker node IP: " WORKER_IP

# ===== Check network connectivity =====
echo "[INFO] Checking network connectivity to Master node..."
if nc -zv "$MASTER_IP" 6443 2>/dev/null; then
    echo "[INFO] Master API Server port 6443 is accessible"
else
    echo "[ERROR] Cannot access Master API Server port 6443. Check network, firewall, or port"
    exit 1
fi

# ===== Uninstall old k3s-agent =====
echo "[INFO] Uninstalling old k3s-agent (if exists)..."
sudo /usr/local/bin/k3s-agent-uninstall.sh 2>/dev/null || true
sudo rm -rf /etc/rancher/k3s /var/lib/rancher/k3s

# ===== Write systemd environment file =====
echo "[INFO] Writing systemd environment file..."
sudo mkdir -p /etc/systemd/system/
echo "K3S_URL=https://${MASTER_IP}:6443" | sudo tee /etc/systemd/system/k3s-agent.service.env
echo "K3S_TOKEN=${MASTER_TOKEN}" | sudo tee -a /etc/systemd/system/k3s-agent.service.env

# ===== Install k3s-agent =====
echo "[INFO] Installing k3s-agent..."
curl -sfL https://get.k3s.io | \
INSTALL_K3S_EXEC="--node-ip ${WORKER_IP} --insecure-skip-tls-verify" sh -

# ===== Enable and start service =====
echo "[INFO] Enabling and starting k3s-agent service..."
sudo systemctl enable k3s-agent
sudo systemctl restart k3s-agent
sudo systemctl status k3s-agent --no-pager

# ===== Show Master node status =====
echo "[INFO] To check node status, run the following on the Master node:"
echo "sudo k3s kubectl get nodes"
