#!/usr/bin/env bash
# Runs Helm in a container, talking to the Minikube cluster over its Docker network.
# Usage (from the repo root): bash scripts/helm.sh upgrade --install ...
set -euo pipefail

PROFILE="${PROFILE:-shop}"
KCFG=".kubeconfig.tmp"            # contains client certs: git-ignored, deleted on exit
trap 'rm -f "$KCFG"' EXIT

# API server address on the cluster's Docker network
IP="$(docker inspect -f "{{(index .NetworkSettings.Networks \"$PROFILE\").IPAddress}}" "$PROFILE")"

# Self-contained kubeconfig (certs embedded) pointing at that address
kubectl config view --minify --flatten --context "$PROFILE" \
  | sed -E "s#server: https://.*#server: https://${IP}:8443#" > "$KCFG"

MSYS_NO_PATHCONV=1 docker run --rm \
  --network "$PROFILE" \
  -e KUBECONFIG="/work/$KCFG" \
  -v "$PWD:/work" -w /work \
  alpine/helm "$@"