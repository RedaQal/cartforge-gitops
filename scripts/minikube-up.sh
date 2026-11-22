#!/usr/bin/env bash
set -euo pipefail

PROFILE=shop
CPUS="${CPUS:-4}"
MEMORY="${MEMORY:-6g}"
REGISTRY_CONTAINER="${REGISTRY_CONTAINER:-cartforge-ci-registry-1}"

# The cluster can pull from the CI registry as "registry:5000".
# It is plain HTTP, so it must be declared insecure when the cluster is created.
minikube start -p "$PROFILE" \
  --driver=docker \
  --container-runtime=docker \
  --cpus="$CPUS" --memory="$MEMORY" \
  --insecure-registry="registry:5000"

minikube addons enable ingress -p "$PROFILE"
minikube addons enable metrics-server -p "$PROFILE"

# Attach the registry container to the cluster's Docker network under the name "registry"
docker network connect --alias registry "$PROFILE" "$REGISTRY_CONTAINER" 2>/dev/null || true

kubectl config use-context "$PROFILE"
for ns in shop-dev shop-staging shop-prod; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -
done

echo "Cluster ready. Namespaces:"
kubectl get ns | grep shop-