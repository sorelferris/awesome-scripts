#!/bin/bash

# Install k3sup
curl -sLS https://get.k3sup.dev | sh
sudo install k3sup /usr/local/bin/

# Deploy master node
k3sup install --ip $NODE_IP --user $USER --k3s-extra-args "--node-ip $NODE_IP"

# Join work node
k3sup join --ip $WORKER_IP --user $USER --k3s-extra-args "--node-ip $WORKER_IP"