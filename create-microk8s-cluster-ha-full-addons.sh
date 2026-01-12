#!/usr/bin/env bash
set -euo pipefail

# HA MicroK8s on Multipass with CIS hardening and metrics-server enabled on all nodes

NODES=3
CPUS=2
MEMORY=4G
DISK=20G
KUBECONFIG_PATH="$HOME/.kube/config"

if ! command -v multipass >/dev/null 2>&1; then
  echo "multipass not found in PATH; please install Multipass first" >&2
  exit 1
fi

echo "Launching $NODES Multipass instances..."
for i in $(seq 1 $NODES); do
  NAME="microk8s-node$i"
  echo "Launching $NAME..."
  multipass launch --name "$NAME" --cpus "$CPUS" --memory "$MEMORY" --disk "$DISK"
done

# Function: apply required kernel sysctl settings
ensure_sysctl_on_node() {
  local node="$1"
  echo "Applying required kernel sysctls on $node..."
  multipass exec "$node" -- sudo bash -lc '
set -e
cat > /tmp/99-microk8s.conf <<SYSCTL
vm.overcommit_memory=1
vm.panic_on_oom=0
kernel.panic=10
kernel.panic_on_oops=1
kernel.keys.root_maxkeys=1000000
kernel.keys.root_maxbytes=25000000
SYSCTL
sudo mv /tmp/99-microk8s.conf /etc/sysctl.d/99-microk8s.conf
sudo sysctl --system || true
echo "sysctl applied on $(hostname)"
'
}

# Apply sysctl changes before installing MicroK8s
for i in $(seq 1 $NODES); do
  ensure_sysctl_on_node "microk8s-node$i"
done

echo "Installing MicroK8s on each node..."
for i in $(seq 1 $NODES); do
  NAME="microk8s-node$i"
  echo "Installing MicroK8s on $NAME..."
  multipass exec "$NAME" -- sudo snap install microk8s --classic
  multipass exec "$NAME" -- sudo usermod -a -G microk8s ubuntu || true
done

echo "Waiting for microk8s-node1 to be ready..."
multipass exec microk8s-node1 -- sudo microk8s status --wait-ready --timeout 300s || multipass exec microk8s-node1 -- sudo microk8s status || true

echo "Enabling HA clustering on microk8s-node1..."
multipass exec microk8s-node1 -- sudo microk8s enable ha-cluster

# Join other nodes
for i in $(seq 2 $NODES); do
  NAME="microk8s-node$i"
  echo "Getting join command for $NAME from microk8s-node1..."
  JOIN_CMD=$(multipass exec microk8s-node1 -- sudo microk8s add-node | grep 'microk8s join' | head -n 1 || true)
  if [ -z "$JOIN_CMD" ]; then
    echo "Retrying join command fetch..."
    sleep 3
    JOIN_CMD=$(multipass exec node1 -- sudo microk8s add-node | grep 'microk8s join' | head -n 1 || true)
  fi
  if [ -z "$JOIN_CMD" ]; then
    echo "Could not get join command for $NAME; aborting." >&2
    exit 1
  fi
  echo "Joining $NAME to cluster..."
  multipass exec "$NAME" -- sudo bash -lc "$JOIN_CMD"
done

echo "Exporting kubeconfig to $KUBECONFIG_PATH..."
mkdir -p "$(dirname "$KUBECONFIG_PATH")"
multipass exec microk8s-node1 -- sudo microk8s config > "$KUBECONFIG_PATH"
chmod 600 "$KUBECONFIG_PATH"

echo "Enabling DNS, Hostpath Storage, and Metrics Server on all nodes..."
for i in $(seq 1 $NODES); do
  multipass exec "microk8s-node$i" -- sudo microk8s enable dns || true
  multipass exec "microk8s-node$i" -- sudo microk8s enable hostpath-storage || true
  multipass exec "microk8s-node$i" -- sudo microk8s enable metrics-server || true
done

echo "Enabling CIS hardening on all nodes..."
for i in $(seq 1 $NODES); do
  multipass exec "microk8s-node$i" -- sudo microk8s enable cis-hardening || true
done

echo "Labeling nodes with control-plane role..."
for i in $(seq 1 $NODES); do
  NODE_NAME="microk8s-node$i"
  kubectl --kubeconfig "$KUBECONFIG_PATH" label node "$NODE_NAME" node-role.kubernetes.io/control-plane=true --overwrite || true
done

echo "✅ Full HA MicroK8s cluster setup complete!"
echo "You can now run:"
echo "  kubectl --kubeconfig $KUBECONFIG_PATH get nodes"
echo "  kubectl --kubeconfig $KUBECONFIG_PATH top nodes"
echo "  kubectl --kubeconfig $KUBECONFIG_PATH top pods"

cat <<'NOTE'
Notes:
- Kernel flags applied: vm.overcommit_memory=1, vm.panic_on_oom=0, kernel.panic=10, kernel.panic_on_oops=1, kernel.keys.root_maxkeys=1000000, kernel.keys.root_maxbytes=25000000
- CIS hardening enabled on all nodes (requires sudo for microk8s commands).
- Metrics Server enabled on all nodes for resource metrics (kubectl top).
- Hostpath storage is enabled (not suitable for production).
- If kubelet errors persist, verify with:
  sudo sysctl -a | grep -E "vm.overcommit_memory|vm.panic_on_oom|kernel.panic|kernel.panic_on_oops|kernel.keys"
NOTE

