#!/usr/bin/env bash
# Usage: scripts/deploy.sh <env> <namespace> <image-tag>   (run from the repo root)
# 1. sets the tag in values-<env>.yaml  2. deploys it  3. smoke-tests it
# 4. only after success, commits the new version to Git.
set -euo pipefail

ENV_NAME="$1"; NAMESPACE="$2"; TAG="$3"
VALUES="charts/cartforge/values-${ENV_NAME}.yaml"

sed -i -E "s/^(\s*tag: \")[^\"]*(\")/\1${TAG}\2/" "$VALUES"

helm upgrade --install cartforge charts/cartforge \
  -n "$NAMESPACE" -f "$VALUES" --wait --timeout 5m

echo "Smoke tests in ${NAMESPACE}..."
kubectl -n "$NAMESPACE" exec deploy/cartforge-frontend -- wget -qO- http://localhost:3000/api/health
echo
kubectl -n "$NAMESPACE" exec deploy/cartforge-frontend -- wget -qO- http://cartforge-catalog:8080/actuator/health
echo

if ! git diff --quiet -- "$VALUES"; then
  git config user.name "cartforge-ci"
  git config user.email "ci@cartforge.local"
  git add "$VALUES"
  git commit -m "deploy(${ENV_NAME}): ${TAG}"
  git pull --rebase origin main
  git push origin HEAD:main
fi