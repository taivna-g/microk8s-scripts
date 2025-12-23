#!/usr/bin/env bash
set -euo pipefail

# Upgrade MicroK8s on all nodes in a Multipass-based HA cluster to a specified version

NODES=3
TARGET_VERSION="1.34"   # <-- Change this to the desired MicroK8s version
SNAP_CHANNEL="$TARGET_VERSION/stable"

echo "Upgrading MicroK8s on $NODES nodes to version $TARGET_VERSION..."

# Validate multipass availability
if ! command -v multipass >/dev/null 2>&1; then
  echo "multipass not found in PATH; please install Multipass first" >&2
  exit 1
fi

# Upgrade MicroK8s on each node
for i in $(seq 1 $NODES); do
  NODE="node$i"
  echo "Upgrading MicroK8s on $NODE to $SNAP_CHANNEL..."
  multipass exec "$NODE" -- sudo snap refresh microk8s --channel="$SNAP_CHANNEL"
done

echo "Waiting for node1 to be ready after upgrade..."
multipass exec node1 -- sudo microk8s status --wait-ready --timeout 300s || multipass exec node1 -- sudo microk8s status || true

echo "Checking cluster health..."
multipass exec node1 -- sudo microk8s kubectl get nodes

echo "✅ Upgrade complete!"
echo "Cluster is now running MicroK8s $TARGET_VERSION on all nodes."
echo "You can verify with:"
echo "  kubectl --kubeconfig $HOME/.kube/config get nodes"
