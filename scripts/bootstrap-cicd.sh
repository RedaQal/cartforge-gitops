#!/usr/bin/env bash
# Prepares the cluster for Jenkins: environments, DB secrets, a ServiceAccount
# limited to the shop-* namespaces, and a kubeconfig file for the Jenkins container.
# Requires: Minikube running and the CI stack started.
set -euo pipefail

PROFILE="${PROFILE:-shop}"
JENKINS_CONTAINER="${JENKINS_CONTAINER:-cartforge-ci-jenkins-1}"
OUT="${1:-$HOME/projects/cartforge-app/ci/secrets/kubeconfig}"

kubectl config use-context "$PROFILE" >/dev/null

kubectl create namespace cicd --dry-run=client -o yaml | kubectl apply -f -
kubectl -n cicd create serviceaccount jenkins --dry-run=client -o yaml | kubectl apply -f -

for ns in shop-dev shop-staging shop-prod; do
  kubectl create namespace "$ns" --dry-run=client -o yaml | kubectl apply -f -

  # Database credentials: created once, never overwritten (the PVC keeps the old password)
  if ! kubectl -n "$ns" get secret cartforge-db >/dev/null 2>&1; then
    kubectl -n "$ns" create secret generic cartforge-db \
      --from-literal=POSTGRES_USER=catalog \
      --from-literal=POSTGRES_PASSWORD="$(openssl rand -hex 16)"
  fi

  # Jenkins may manage the objects Helm creates in this namespace, and nothing else
  kubectl -n "$ns" create role jenkins-deployer \
    --verb=get,list,watch,create,update,patch,delete \
    --resource=pods,pods/log,pods/exec,services,endpoints,configmaps,secrets,persistentvolumeclaims,serviceaccounts,deployments.apps,replicasets.apps,statefulsets.apps,ingresses.networking.k8s.io \
    --dry-run=client -o yaml | kubectl apply -f -
  kubectl -n "$ns" create rolebinding jenkins-deployer \
    --role=jenkins-deployer --serviceaccount=cicd:jenkins \
    --dry-run=client -o yaml | kubectl apply -f -
done

# Long-lived token for the ServiceAccount
kubectl -n cicd apply -f - <<'EOF'
apiVersion: v1
kind: Secret
metadata:
  name: jenkins-token
  annotations:
    kubernetes.io/service-account.name: jenkins
type: kubernetes.io/service-account-token
EOF

TOKEN=""
for _ in $(seq 1 20); do
  TOKEN="$(kubectl -n cicd get secret jenkins-token -o jsonpath='{.data.token}' | base64 -d 2>/dev/null || true)"
  [ -n "$TOKEN" ] && break
  sleep 1
done
[ -n "$TOKEN" ] || { echo "Token was not generated" >&2; exit 1; }
CA="$(kubectl -n cicd get secret jenkins-token -o jsonpath='{.data.ca\.crt}')"
IP="$(docker inspect -f "{{(index .NetworkSettings.Networks \"$PROFILE\").IPAddress}}" "$PROFILE")"

mkdir -p "$(dirname "$OUT")"
cat > "$OUT" <<EOF
apiVersion: v1
kind: Config
clusters:
  - name: ${PROFILE}
    cluster:
      server: https://${IP}:8443
      certificate-authority-data: ${CA}
users:
  - name: jenkins
    user:
      token: ${TOKEN}
contexts:
  - name: ${PROFILE}
    context:
      cluster: ${PROFILE}
      user: jenkins
current-context: ${PROFILE}
EOF
chmod 600 "$OUT"
echo "kubeconfig written to $OUT (treat it as a secret, never commit it)"

# Let the Jenkins container reach the cluster network (redo if Jenkins is recreated)
docker network connect "$PROFILE" "$JENKINS_CONTAINER" 2>/dev/null || true

echo "Testing from inside Jenkins..."
docker exec "$JENKINS_CONTAINER" kubectl -n shop-dev get pods