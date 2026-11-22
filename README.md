# CartForge GitOps

Kubernetes configuration for [CartForge](https://github.com/RedaQal/cartforge-app): a Helm chart, per-environment values and a script that bootstraps a local Minikube cluster.

The application code and CI pipeline live in `cartforge-app`. This repo describes **what runs in the cluster**, and the deployed version of each service is a value stored here in Git.

## Architecture

```
Minikube cluster "shop"
 ├─ namespace shop-dev
 ├─ namespace shop-staging
 └─ namespace shop-prod
      each one runs the same chart with different values:
      ├─ frontend   (Deployment + Service)  ◄── Ingress (<env>.shop.local)
      ├─ catalog    (Deployment + Service, internal only)
      └─ postgres   (StatefulSet + PersistentVolumeClaim)
```

Images come from the local registry started by the CI stack in `cartforge-app` (`ci/docker-compose.yml`). Inside the cluster it is reachable as `registry:5000`.

## Repository layout

```
cartforge-gitops/
├── charts/cartforge/
│   ├── Chart.yaml
│   ├── values.yaml          # defaults
│   ├── values-dev.yaml      # dev overrides (image tags, host)
│   └── templates/           # postgres, catalog, frontend, ingress
├── scripts/
│   ├── minikube-up.sh       # creates the cluster, addons and namespaces
│   └── helm.sh              # runs Helm in a container (see "Helm on locked-down Windows")
└── README.md
```

## Prerequisites

- Docker Desktop, running
- `kubectl` and `minikube`
- Helm 3, or the Docker-based wrapper described below
- The CI stack from `cartforge-app` started (`cd ci && docker compose up -d`), with at least one successful `main` build so images exist in the registry

Check the available image tags:

```bash
curl localhost:5000/v2/catalog-service/tags/list
curl localhost:5000/v2/frontend/tags/list
```

## 1. Create the cluster

```bash
bash scripts/minikube-up.sh
```

This creates a Minikube profile named `shop`, enables the `ingress` and `metrics-server` addons, declares `registry:5000` as an insecure (plain HTTP) registry, connects the CI registry container to the cluster network, and creates the three namespaces.

Smaller machine? Reduce the resources:

```bash
CPUS=2 MEMORY=4g bash scripts/minikube-up.sh
```

Verify the cluster can pull from the registry:

```bash
minikube ssh -p shop -- docker pull registry:5000/catalog-service:<TAG>
```

## 2. Create the database secret

The password is never stored in Git. Create it once per namespace:

```bash
kubectl -n shop-dev create secret generic cartforge-db \
  --from-literal=POSTGRES_USER=catalog \
  --from-literal=POSTGRES_PASSWORD="$(openssl rand -hex 16)"
```

## 3. Choose the version to deploy

Edit `charts/cartforge/values-dev.yaml` and set the image tags to a SHA that exists in the registry:

```yaml
catalog:
  image:
    tag: "<GIT_SHA>"
frontend:
  image:
    tag: "<GIT_SHA>"
```

## 4. Deploy

```bash
helm lint charts/cartforge -f charts/cartforge/values-dev.yaml

helm upgrade --install cartforge charts/cartforge \
  -n shop-dev -f charts/cartforge/values-dev.yaml --wait --timeout 5m

kubectl -n shop-dev get pods
```

Expected: `cartforge-postgres-0`, `cartforge-catalog-*` and `cartforge-frontend-*` all `Running` and `1/1`.

## 5. Access the application

Quick check with a port-forward:

```bash
kubectl -n shop-dev port-forward svc/cartforge-frontend 3001:3000
# open http://localhost:3001
```

Through the Ingress:

1. Add the hostname to the Windows hosts file (Git Bash as Administrator):
   ```bash
   echo "127.0.0.1 dev.shop.local" >> /c/Windows/System32/drivers/etc/hosts
   ```
2. Keep a tunnel open in a separate terminal (the Docker driver needs it):
   ```bash
   minikube tunnel -p shop
   ```
3. Open http://dev.shop.local

## Everyday commands

```bash
# What is deployed
helm list -A
helm history cartforge -n shop-dev

# Roll out another version
helm upgrade cartforge charts/cartforge -n shop-dev \
  -f charts/cartforge/values-dev.yaml --set catalog.image.tag=<OTHER_SHA> --wait

# Roll back
helm rollback cartforge 1 -n shop-dev

# Scale
helm upgrade cartforge charts/cartforge -n shop-dev \
  -f charts/cartforge/values-dev.yaml --set catalog.replicas=2 --wait

# Debug
kubectl -n shop-dev describe pod <pod>
kubectl -n shop-dev logs deploy/cartforge-catalog

# Show the YAML Helm generates
helm template cartforge charts/cartforge -f charts/cartforge/values-dev.yaml
```

Stop the cluster to free memory, and start it again later:

```bash
minikube stop -p shop
minikube start -p shop
```

## Design notes

- **Only the frontend is exposed.** The catalog API is reachable inside the cluster only.
- **No secrets in Git.** The chart references a Kubernetes Secret by name.
- **Probes reuse the application's health endpoints:** `/actuator/health/liveness` and `/readiness` for the backend, `/api/health` for the frontend. A startup probe gives Spring time to boot.
- **Hardened pods:** non-root with numeric UIDs, no privilege escalation, all Linux capabilities dropped.
- **Resource requests and limits** are set on every container. There is deliberately no CPU limit, to avoid throttling JVM startup.
- **PostgreSQL runs as a StatefulSet** with a PersistentVolumeClaim, so data survives pod restarts.
- **Image tags are git SHAs**, never `latest`, so every deployment traces back to a commit.

## Helm on locked-down Windows

On some Windows machines, an Application Control policy (for example Smart App Control) blocks unsigned executables such as `helm.exe`. In that case, `scripts/helm.sh` runs Helm in a Linux container (`alpine/helm`) connected to the cluster's Docker network.

Set up a shortcut once:

```bash
echo ".kubeconfig.tmp" >> .gitignore
echo "alias helm='bash ~/projects/cartforge-gitops/scripts/helm.sh'" >> ~/.bashrc
source ~/.bashrc
```

Then use `helm` as normal, always from the root of this repository, since the current folder is mounted into the container. `helm lint` and `helm template` work without a running cluster. Deploying requires the cluster to be up.

## Troubleshooting

| Symptom | Likely cause and fix |
|---|---|
| `ImagePullBackOff` | The node cannot reach the registry. Re-run the `docker pull` check above. If the registry container was recreated, reconnect it: `docker network connect --alias registry shop <registry-container>`. |
| `CrashLoopBackOff` on catalog | Read `kubectl logs`. Usually a wrong Secret or the database not ready yet. |
| Password authentication failed | The Secret was recreated but the existing PersistentVolumeClaim keeps the old password. Delete it: `kubectl -n shop-dev delete pvc data-cartforge-postgres-0` and the Postgres pod. |
| Pod `Pending` | Not enough CPU or memory in the cluster. `kubectl describe pod` shows why. Recreate the cluster with more resources. |
| `dev.shop.local` does not load | Tunnel not running, hosts entry missing, or ingress not ready: `kubectl get pods -n ingress-nginx`. |
| `catalog.image.tag is required` | The tag is empty in the values file. |
| `helm.exe` is blocked or `Permission denied` | See "Helm on locked-down Windows". |

## Roadmap

- [x] Helm chart and Minikube bootstrap
- [ ] Environment promotion: dev, staging, prod
- [ ] Jenkins updates image tags and deploys
- [ ] Monitoring with Prometheus and Grafana
- [ ] Autoscaling (HPA) and NetworkPolicies