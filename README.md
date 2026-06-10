# Azure Platform POC

A disposable Azure platform environment provisioned by Terraform, hosting a probe-instrumented FastAPI service with SHA-tagged container images and on-demand failure injection — designed to be stood up, observed, broken, recovered, and torn down within a single cluster lifecycle.

## Why this exists

A defensible portfolio artifact for platform-engineering interviews. The goal is not to ship a production system; it is to produce a real, runnable codebase that maps to the recurring interview themes — provisioning, deployment, observability, troubleshooting, incident response, teardown — with commit history and live-captured evidence to back the story.

## Architecture

A deliberate two-tool boundary:

- **Terraform owns infrastructure**: Resource Group, AKS (system + user node pools, autoscaling, OIDC), ACR with managed-identity AcrPull binding, Log Analytics Workspace, Azure Monitor Workspace, Data Collection Endpoint + Rule for Managed Prometheus, Azure Managed Grafana with Monitoring Data Reader role.
- **kubectl owns workloads**: namespace, Deployment, Service (LoadBalancer), HPA — applied via a templated script that substitutes the build SHA at deploy time.

Workload-layer resources are intentionally *not* tracked in Terraform state to avoid plan-time chicken-and-egg with the kubernetes provider. See [Engineering decisions worth noting](#engineering-decisions-worth-noting).

## Project structure

```
.
├── terraform/                Terraform stack (azurerm v4)
├── app/                      FastAPI service + Dockerfile (uv-managed)
├── k8s/                      Workload manifests applied via kubectl
│   ├── namespace.yaml
│   ├── deploy.yaml           Templated; __SHA__ / __BUILD_TIME__ substituted at apply
│   ├── service.yaml
│   └── hpa.yaml
├── scripts/
│   └── deploy.sh             build → push → templated apply → rollout status
└── runbooks/                 Incident runbooks
    └── evidence/             Real kubectl describe/events captures backing each runbook
```

## How to run

Prereqs: Azure CLI logged in, Docker, kubectl, Terraform ≥ 1.5, `uv` for local app dev.

```bash
# Set subscription (azurerm v4 requires subscription_id explicitly)
az account set --subscription "<sub-name-or-id>"
export ARM_SUBSCRIPTION_ID=$(az account show --query id -o tsv)

# Provision infra
cd terraform
terraform init
terraform apply
cd ..

# Get cluster credentials
az aks get-credentials \
  --resource-group "$(terraform -chdir=terraform output -raw rg_name)" \
  --name           "$(terraform -chdir=terraform output -raw aks_name)"

# Build, push, and deploy
./scripts/deploy.sh

# Verify end-to-end
IP=$(kubectl get svc -n app loadbalancer-service -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
curl http://$IP/health
curl http://$IP/version    # git_sha should match the deployed image tag

# Tear down
cd terraform && terraform destroy
```

## App endpoints

| Path | Purpose |
|---|---|
| `/health` | Liveness — process is alive |
| `/ready` | Readiness — flips to 503 during shutdown so traffic drains cleanly |
| `/version` | Returns `APP_VERSION`, `GIT_SHA`, `BUILD_TIME` from env vars set at deploy time |
| `/metrics` | Prometheus exposition via `prometheus-fastapi-instrumentator` |
| `/simulate-error?kind=500\|crash\|hang\|oom` | On-demand failure injection for runbook validation |

## Engineering decisions worth noting

**Terraform for infrastructure, kubectl for workloads.** An early attempt to deploy the namespace via `kubernetes_manifest` hit the classic plan-time chicken-and-egg: the provider needs cluster credentials that do not exist until apply. Moving workload-layer resources to `k8s/` and applying them with kubectl eliminated an entire class of "works on the second apply" flakiness.

**SHA-tagged immutable images.** `git rev-parse --short HEAD` is the only image tag pattern used. The same SHA is templated into `deploy.yaml` as both the image tag and the `GIT_SHA` env var, then surfaced through `/version`. A curl against `/version` and `kubectl get pod -o jsonpath='{.items[0].spec.containers[0].image}'` should always return the same string — proof of commit→image→pod traceability.

**Dual random-suffix naming.** Azure name constraints are heterogeneous (ACR: 50 chars alphanumeric-only; Managed Grafana: 2–23 chars alphanumeric+dashes). The Terraform `locals` block uses two random suffixes: a descriptive `random_pet` for long-name resources and tags, plus a short `random_string` for resources with tight constraints.

**Templated `deploy.yaml` with `sed` substitution.** Keeps the manifest a clean template on disk (no per-deploy churn in `git diff`) and guarantees the image tag and `GIT_SHA` env var come from the same shell variable, so they cannot drift.

**Separate liveness and readiness semantics.** Liveness on `/health` triggers restart; readiness on `/ready` only removes the pod from Service endpoints. A flaky downstream takes the pod out of rotation without triggering a restart loop.

**Walking-skeleton iteration, not big-bang.** Pass 1 deployed nginx through the entire stack to validate AKS, networking, RBAC, and ACR pull. Pass 2 swapped in FastAPI. Every layer was proven before the next was added, so when something broke the suspect space stayed small.

**Tear-down as idempotency testing.** `terraform destroy` between iterations is treated as the only honest test of IaC reproducibility, not just a cost control. Several real bugs surfaced *only* on rebuild.

**Identity-based access throughout.** ACR admin is disabled; image pulls go through the AKS kubelet's system-assigned managed identity bound by an `AcrPull` role assignment. Grafana reads metrics via a `Monitoring Data Reader` role on its own managed identity. No static credentials in source or state.

## Status

| Component | State |
|---|---|
| Terraform infrastructure stack | Implemented |
| FastAPI app + endpoints | Implemented |
| Kubernetes workload manifests | Implemented |
| Local deploy script (`scripts/deploy.sh`) | Implemented |
| Observability (Container Insights, Managed Prometheus, Grafana, Log Analytics) | Provisioned in Terraform |
| Failure-mode evidence capture | Implemented; outputs under `runbooks/evidence/` |
| Runbook prose | Pending (evidence captured) |
| GitHub Actions CI/CD workflow | Pending (`deploy.sh` is the rehearsal) |

## OpenShift comparison

This POC uses vanilla Kubernetes on AKS because the core operational model — provisioning, manifests, probes, RBAC, observability — transfers across Kubernetes platforms. In OpenShift I would expect additional platform layers around Routes, SCCs, Operators, Projects, the integrated registry, and stricter security defaults.
