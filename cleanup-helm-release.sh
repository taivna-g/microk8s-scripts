#!/bin/bash

# Prompt for Helm release name
read -p "Enter the Helm release name to uninstall: " RELEASE
read -p "Enter the namespace (default: default): " NAMESPACE
NAMESPACE=${NAMESPACE:-default}

echo "Uninstalling Helm release: $RELEASE from namespace: $NAMESPACE"
helm uninstall "$RELEASE" --namespace "$NAMESPACE"

# Wait for Helm to finish uninstalling
sleep 5

echo "Checking for leftover resources in '$NAMESPACE' namespace..."

# Get all namespaced resource types that support list
RESOURCE_TYPES=$(kubectl api-resources --verbs=list --namespaced -o name)

# Iterate through resource types and delete resources labeled with the release name
for TYPE in $RESOURCE_TYPES; do
    RESOURCES=$(kubectl get "$TYPE" -n "$NAMESPACE" -l "release=$RELEASE" --no-headers -o custom-columns=":metadata.name" 2>/dev/null)
    if [ -n "$RESOURCES" ]; then
        echo "Deleting leftover $TYPE resources: $RESOURCES"
        for ITEM in $RESOURCES; do
            kubectl delete "$TYPE" "$ITEM" -n "$NAMESPACE"
        done
    fi
done

# Extra cleanup for common leftovers
echo "Deleting Jobs, PVCs, and Pods with release label..."
kubectl delete jobs,pvc,pods -n "$NAMESPACE" -l "release=$RELEASE" --ignore-not-found

echo "Cleanup complete!"
