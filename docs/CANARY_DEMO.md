# Canary deployment demo (prod backend)

Production uses [Argo Rollouts](https://argo-rollouts.readthedocs.io/) for `packmate-backend` only. The frontend remains a standard Deployment.

## Prerequisites

1. Argo Rollouts controller installed in the cluster.
2. Prod overlay applied (`deploy/overlays/prod`) — **not** covered by this doc; apply manually after review.
3. [kubectl argo rollouts plugin](https://argo-rollouts.readthedocs.io/en/stable/installation/#kubectl-plugin-installation).

```bash
kubectl argo rollouts version
```

## Canary strategy

Defined in `deploy/overlays/prod/rollout-backend.yaml`:

| Step | Action |
|------|--------|
| 1 | Route **10%** canary weight |
| 2 | **Analysis** — smoke checks `/health` and `/ready` on `packmate-backend-canary` |
| 3 | **Pause** — wait for manual promote |
| 4 | Route **50%** canary weight |
| 5 | **Analysis** — smoke checks again |
| 6 | **Pause** — wait for manual promote |
| 7 | Route **100%** (complete rollout) |

Services:

- `packmate-backend` — stable traffic (frontend Nginx `/api` proxy target)
- `packmate-backend-canary` — canary pods for analysis and weighted traffic

## Helper script

```bash
./scripts/canary-demo.sh demo      # print step sequence
./scripts/canary-demo.sh status    # current step and weights
./scripts/canary-demo.sh watch     # watch until paused/stable
./scripts/canary-demo.sh promote   # advance past pause (next step)
./scripts/canary-demo.sh promote --full   # skip remaining pauses
./scripts/canary-demo.sh pause     # pause an active rollout
./scripts/canary-demo.sh resume    # resume after pause
./scripts/canary-demo.sh abort     # abort canary, revert to stable
./scripts/canary-demo.sh retry     # retry failed analysis
./scripts/canary-demo.sh history   # revision list
```

Override namespace or rollout name:

```bash
NAMESPACE=packmate-prod ROLLOUT=packmate-backend ./scripts/canary-demo.sh status
```

## Typical demo flow

1. Deploy a new backend image tag (GitOps or `kubectl argo rollouts set image`).
2. Watch the rollout reach the first pause at 10%:

   ```bash
   ./scripts/canary-demo.sh watch
   ```

3. Confirm smoke analysis passed and inspect canary pods:

   ```bash
   kubectl get pods -n packmate-prod -l app.kubernetes.io/name=packmate-backend
   kubectl argo rollouts get rollout packmate-backend -n packmate-prod
   ```

4. Promote through pauses:

   ```bash
   ./scripts/canary-demo.sh promote   # 10% -> 50%
   ./scripts/canary-demo.sh promote   # 50% -> 100%
   ```

5. If analysis fails or errors spike, abort:

   ```bash
   ./scripts/canary-demo.sh abort
   ```

## Analysis templates

| Template | Purpose |
|----------|---------|
| `packmate-backend-smoke` | Job-based curl of `/health` and `/ready` on the canary Service |
| `packmate-backend-prometheus` | Optional HTTP error-rate query (not enabled in default steps) |

To enable Prometheus analysis, uncomment the template reference in `rollout-backend.yaml` and set `prometheus-address` to your Prometheus server.

## Render locally (no cluster apply)

```bash
kustomize build deploy/overlays/prod | grep -E '^kind:|^  name:'
./scripts/render-manifests.sh
```

Dev overlay keeps a plain Deployment for the backend; canary is **prod-only**.
