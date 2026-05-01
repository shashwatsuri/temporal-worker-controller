# Rainbow Dashboard

A real-time monitoring dashboard for Temporal Worker Deployments managed by the Temporal Worker Controller. It provides visibility into version rollouts, traffic routing, active workflow distribution, and worker slot utilization.

## What It Does

The dashboard serves a web UI and JSON API that shows:

- **Version cards** — each deployed worker version with its role (current, target, deprecated), traffic routing percentage, replica count, and active workflow count
- **Rollout progress** — visualizes ramping between versions during a rainbow (canary) deployment
- **Active workflows per version** — queries Temporal's visibility API to show how many running workflows are pinned to each version
- **Slot utilization** — queries Prometheus for `temporal_worker_task_slots_used` / `temporal_worker_task_slots_available` metrics
- **Execution list** — returns individual running workflow IDs with their version assignment for progressive polling UIs

## Architecture

```
┌─────────────────────────────────────────────────────────┐
│  Browser / External Client                              │
│    GET /api/state         → full version + metrics view │
│    GET /api/executions    → workflow list with versions  │
│    GET /healthz           → health check (instant 200)  │
│    GET /                  → embedded static HTML UI      │
└────────────────┬────────────────────────────────────────┘
                 │
                 ▼
┌─────────────────────────────────────────────────────────┐
│  Dashboard Server (Go, port 8787)                       │
│                                                         │
│  - CORS enabled (Access-Control-Allow-Origin: *)        │
│  - Response caching (5s TTL for /api/state)             │
│  - Retry logic for Temporal CLI calls (3 attempts)      │
│  - Temporal access config caching (5-min TTL)           │
└────┬──────────────┬─────────────────┬───────────────────┘
     │              │                 │
     ▼              ▼                 ▼
  kubectl        temporal CLI      kubectl --raw
  (K8s API)      (Temporal Cloud)  (Prometheus proxy)
```

### Data Sources

| Source | How | What |
|--------|-----|------|
| Kubernetes API (via `kubectl`) | `get temporalworkerdeployment`, `get deployments -l temporal.io/deployment-name=X` | Version topology, replica counts, conditions |
| Temporal Connection (via `kubectl`) | `get temporalconnection`, `get secret` | Auth config (API key or mTLS certs) |
| Temporal Visibility (via `temporal` CLI) | `workflow count --query ...`, `workflow list --query ...` | Active workflow counts per version, execution list |
| Prometheus (via `kubectl get --raw`) | PromQL queries through K8s API server proxy | Slot utilization metrics |

### Authentication to Temporal

The dashboard reads the `TemporalConnection` CR referenced by the `TemporalWorkerDeployment` to discover how to authenticate:

1. **API Key** — reads the referenced Secret, extracts the key, passes `--api-key` + `--tls` to the CLI
2. **Mutual TLS** — reads the referenced Secret, writes cert/key to temp files, passes `--tls-cert-path` / `--tls-key-path`

The resolved config is cached for 5 minutes to avoid repeated Secret reads.

## API Endpoints

### `GET /healthz`

Returns `200 ok` instantly. Used by the ALB health check.

### `GET /api/state`

Returns the full dashboard state as JSON. Cached for 5 seconds to prevent concurrent browser polls from spawning redundant subprocess calls.

**Response shape:**
```json
{
  "name": "helloworld",
  "namespace": "default",
  "fetchedAt": "2026-04-30T12:00:00Z",
  "versionCount": 3,
  "activeVersions": 2,
  "activeWorkflowTotal": 150,
  "pinnedLikely": true,
  "slotsUsed": 45.0,
  "slotsCapacity": 100.0,
  "slotUtilizationPct": 45.0,
  "versions": [
    {
      "buildId": "abc123",
      "role": "current",
      "status": "Current",
      "trafficPct": 80,
      "draining": false,
      "activeWorkflowCount": 120,
      "activeWorkflowPct": 80.0,
      "deployment": "default/helloworld-abc123",
      "replicas": 3,
      "readyReplicas": 3
    }
  ],
  "progressing": { "type": "Progressing", "status": "True", ... },
  "ready": { "type": "Ready", "status": "True", ... }
}
```

### `GET /api/executions`

Returns individual running workflow executions with their version assignment.

**Query parameters:**
- `since` (optional) — filter to workflows started after this time. Accepts:
  - RFC3339: `?since=2026-04-30T12:00:00Z`
  - Unix milliseconds (from JS `Date.now()`): `?since=1746054000000`

**Response shape:**
```json
{
  "executions": [
    { "id": "workflow-id-123", "version": "abc123" },
    { "id": "workflow-id-456", "version": "def789" }
  ],
  "versions": {
    "abc123": { "status": "active", "running": 120, "ramping": 80 },
    "def789": { "status": "ramping", "running": 30, "ramping": 20 }
  }
}
```

## How It's Built

### Project Structure

```
internal/demo/dashboard/
├── main.go          # All server logic (single file)
├── static/
│   └── index.html   # Embedded web UI
└── README.md        # This file

internal/demo/
├── Dockerfile.dashboard   # Multi-stage build (Go builder → bitnami/kubectl runtime)
└── k8s/
    └── dashboard-deployment.yaml  # K8s Deployment, Service, Ingress
```

### Key Implementation Details

- **Single binary** — the entire server is one `main.go` file. Static assets are embedded via `//go:embed static/*`.
- **No dependencies beyond stdlib** — no web frameworks, no Temporal SDK. All Temporal interaction is via shelling out to the `temporal` CLI binary.
- **Subprocess-based** — both `kubectl` and `temporal` are invoked as child processes. This avoids importing the full K8s or Temporal client libraries but means the container must include both binaries.
- **Caching layers:**
  - `/api/state` response: 5-second TTL with single-flight (only one goroutine refreshes at a time)
  - Temporal access config: 5-minute TTL
  - Active workflow counts: 2-minute TTL (fallback if Temporal is unreachable)
  - Slot metrics: 60-second TTL
- **CORS** — all responses include `Access-Control-Allow-Origin: *` via middleware wrapper
- **Graceful degradation** — if Temporal or Prometheus is temporarily unreachable, the dashboard returns cached data with a note field explaining the fallback

### Container Image

Built from `internal/demo/Dockerfile.dashboard`:

1. **Builder stage** (golang:1.25) — compiles the Go binary and downloads the Temporal CLI
2. **Runtime stage** (bitnami/kubectl) — provides `kubectl` in PATH; the Go binary and `temporal` CLI are copied in

The runtime image has:
- `/dashboard` — the Go server binary
- `/usr/local/bin/temporal` — Temporal CLI v1.6.2
- `kubectl` — from the bitnami base image (used for K8s API calls)

### Deployment

Deployed to EKS via Skaffold. The build/deploy workflow:

```bash
# Build for linux/amd64 and push to ECR
skaffold build -p dashboard,eks-amd64

# Tag as :latest (deployment uses latest tag)
docker tag 025066239481.dkr.ecr.us-east-2.amazonaws.com/rainbow-dashboard:<sha> \
           025066239481.dkr.ecr.us-east-2.amazonaws.com/rainbow-dashboard:latest
docker push 025066239481.dkr.ecr.us-east-2.amazonaws.com/rainbow-dashboard:latest

# Restart to pull new image
kubectl rollout restart deployment/rainbow-dashboard
kubectl rollout status deployment/rainbow-dashboard --timeout=60s
```

**ECR login (if token expired):**
```bash
AWS_PROFILE=bitovi-temporal aws ecr get-login-password --region us-east-2 | \
  docker login --username AWS --password-stdin 025066239481.dkr.ecr.us-east-2.amazonaws.com
```

### Infrastructure Notes

- **ALB Ingress** — internet-facing ALB with two public subnets (us-east-2a + us-east-2b)
- **Health check** — ALB checks `/healthz` (instant 200, no subprocess overhead)
- **Target group attributes** — `deregistration_delay.timeout_seconds=30`, `load_balancing.cross_zone.enabled=true`
- **Subnets** — `subnet-020cbb1d237801119` (us-east-2b, public) + `subnet-0c6238d501a8f9328` (us-east-2a, public)
- **Domain** — `replay-demo.bitovi.com` → ALB DNS

### CLI Flags

| Flag | Default | Description |
|------|---------|-------------|
| `--namespace` | `default` | Kubernetes namespace of the TemporalWorkerDeployment |
| `--name` | `helloworld` | Name of the TemporalWorkerDeployment resource |
| `--port` | `8787` | HTTP listen port |

## Development

To run locally (requires `kubectl` configured and `temporal` CLI in PATH):

```bash
cd internal/demo
go run ./dashboard --namespace default --name helloworld --port 8787
```

The server will be available at `http://localhost:8787`.
