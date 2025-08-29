#!/bin/bash

# ===== Interactive Input =====
read -p "Enter Master node IP: " MASTER_IP
read -p "Enter Master node token: " MASTER_TOKEN
read -p "Enter Worker node IP: " WORKER_IP

# ===== Check Network Connectivity =====
echo "[INFO] Checking network connectivity to Master node..."
if nc -zv "$MASTER_IP" 6443 2>/dev/null; then
    echo "[INFO] Master API Server port 6443 is reachable"
else
    echo "[ERROR] Cannot reach Master API Server port 6443. Check network, firewall, or port settings"
    exit 1
fi

# ===== Uninstall Old k3s-agent =====
echo "[INFO] Uninstalling old k3s-agent (if exists)..."
sudo /usr/local/bin/k3s-agent-uninstall.sh 2>/dev/null || true
sudo rm -rf /etc/rancher/k3s /var/lib/rancher/k3s

# ===== Write systemd Environment File =====
echo "[INFO] Writing systemd environment file..."
sudo mkdir -p /etc/systemd/system/
sudo tee /etc/systemd/system/k3s-agent.service.env > /dev/null <<EOF
K3S_URL=https://${MASTER_IP}:6443
K3S_TOKEN=${MASTER_TOKEN}
EOF

# ===== Install k3s-agent =====
echo "[INFO] Installing k3s-agent..."
curl -sfL https://get.k3s.io | \
  INSTALL_K3S_EXEC="--node-ip ${WORKER_IP} --insecure-skip-tls-verify" \
  INSTALL_K3S_AGENT=1 sh -

# ===== Start and Enable Service =====
echo "[INFO] Enabling and starting k3s-agent service..."
sudo systemctl daemon-reload
sudo systemctl enable k3s-agent
sudo systemctl restart k3s-agent
sudo systemctl status k3s-agent --no-pager

# ===== Show Node Status on Master =====
echo "[INFO] Run the following command on the Master node to check node status:"
echo "sudo k3s kubectl get nodes"
