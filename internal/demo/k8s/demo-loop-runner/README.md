# Demo Loop Runner

Two independent Kubernetes CronJobs that drive the Temporal Worker Controller rainbow deployment demo:

1. **Release CronJob** (`rainbow-release`) — generates a new worker version, builds the container image via Kaniko, and deploys it via Skaffold/Helm
2. **Traffic CronJob** (`rainbow-traffic`) — starts workflows on Temporal to create realistic in-flight traffic across versions

Scripts are deployed as ConfigMaps and mounted into the pods, so changes to behavior only require a Helm upgrade — no image rebuild.

## Architecture

```
┌────────────────────────────────────────────────────────────┐
│  CronJob: rainbow-release (every 3 min)                    │
│  ConfigMap: rainbow-release-scripts                        │
│    run_release_once.sh                                     │
│      ├─ generate_version_cron.sh  → mutate worker, commit  │
│      ├─ build_version_kaniko.sh   → Kaniko Job → ECR push  │
│      └─ deploy_version_skaffold.sh → skaffold deploy       │
└────┬───────────────────────┬───────────────────────────────┘
     │                       │
     ▼                       ▼
  K8s API                  AWS ECR

┌────────────────────────────────────────────────────────────┐
│  CronJob: rainbow-traffic (every 1 min)                    │
│  ConfigMap: rainbow-traffic-scripts                        │
│    generate-traffic.sh → temporal workflow start            │
└────┬───────────────────────────────────────────────────────┘
     │
     ▼
  Temporal Cloud
```

## How It Works

### Release CronJob

Each invocation:
1. Clones the repo, reads version counter from `rainbow-version-state` ConfigMap
2. Mutates `worker.go` with version-specific sleep duration and commits
3. Launches a Kaniko Job to build and push the image to ECR
4. Runs `skaffold deploy` to update the TemporalWorkerDeployment CR
5. The controller detects the change and begins a rainbow rollout

### Traffic CronJob

Each invocation:
1. Counts running workflows via `temporal workflow count`
2. Computes how many to start (respects `MAX_RUNNING_WORKFLOWS` cap)
3. Starts workflows with `temporal workflow start` on the configured task queue

Because releases and traffic are decoupled, traffic keeps flowing regardless of release state, and releases aren't blocked by traffic generation timing.

## Configuration

All values via Helm:

### Image

| Value | Default | Description |
|-------|---------|-------------|
| `image.repository` | `rainbow-release-job` | Base image with tools (no scripts baked in) |
| `image.tag` | `latest` | Image tag |
| `image.pullPolicy` | `Always` | Pull policy |

### Release CronJob

| Value | Default | Description |
|-------|---------|-------------|
| `release.schedule` | `*/3 * * * *` | Cron schedule for releases |
| `release.activeDeadlineSeconds` | `900` | Job timeout |
| `release.name` | `helloworld` | TemporalWorkerDeployment name |
| `release.repoUrl` | — | Git repo to clone |
| `release.repoRef` | `main` | Branch/tag |
| `release.worker` | `helloworld` | Worker build arg |
| `release.waitForTwdRollout` | `false` | Block until rollout completes |

### Traffic CronJob

| Value | Default | Description |
|-------|---------|-------------|
| `traffic.schedule` | `* * * * *` | Cron schedule for traffic |
| `traffic.activeDeadlineSeconds` | `120` | Job timeout |
| `traffic.workflowType` | `HelloWorld` | Workflow type to start |
| `traffic.workflowsPerRun` | `5` | Target workflows per invocation |
| `traffic.maxNewWorkflowsPerRun` | `5` | Max new workflows per invocation |
| `traffic.maxRunningWorkflows` | `10` | Global cap on running workflows |

### AWS

| Value | Default | Description |
|-------|---------|-------------|
| `aws.roleArn` | — | IAM role ARN for IRSA (ECR push) |
| `aws.region` | `us-east-2` | AWS region |

### Temporal

| Value | Default | Description |
|-------|---------|-------------|
| `temporal.address` | — | Temporal server address |
| `temporal.namespace` | — | Temporal namespace |
| `temporal.taskQueue` | `<ns>/<release.name>` | Task queue |
| `temporal.workerDeployment` | `<ns>/<release.name>` | Worker deployment key |
| `temporal.apiKey.secretName` | `temporal-api-key` | K8s Secret name |
| `temporal.apiKey.secretKey` | `api-key` | Key within Secret |

## Base Image

Built from `internal/demo/Dockerfile.release-job` — Alpine with tools only (no scripts):

- `kubectl`, `temporal` CLI, `skaffold`, `helm`, `aws-cli`, `git`, `jq`

Scripts are mounted from ConfigMaps at `/opt/scripts/`.

## Scripts

Live in the chart at `scripts/`:

| Script | CronJob | Purpose |
|--------|---------|---------|
| `run_release_once.sh` | release | Orchestrates one full release cycle |
| `generate_version_cron.sh` | release | Mutates worker.go, commits, emits image tag |
| `build_version_kaniko.sh` | release | Creates Kaniko Job, waits for completion |
| `deploy_version_skaffold.sh` | release | Skaffold deploy with pre-built artifact |
| `generate-traffic.sh` | traffic | Counts workflows, starts new ones up to cap |

To change script behavior, edit the files and re-deploy the chart. No image rebuild needed.

## Deployment

```bash
skaffold run -p demo-loop-runner,eks-amd64
```

Or deploy just the chart (if base image already exists):

```bash
helm upgrade --install demo-loop-runner internal/demo/k8s/demo-loop-runner \
  --set temporal.address="$TEMPORAL_ADDRESS" \
  --set temporal.namespace="$TEMPORAL_NAMESPACE" \
  --set image.repository=025066239481.dkr.ecr.us-east-2.amazonaws.com/rainbow-release-job \
  --set image.tag=latest \
  --set aws.roleArn=arn:aws:iam::025066239481:role/rainbow-version-generator-role
```

## How Rainbow Deployments Emerge

Because workflows sleep 150–240s and releases happen every 3 minutes, there's always version overlap:

1. Version N deploys → workflows start on version N
2. 3 min later, version N+1 deploys → controller begins ramping
3. Version N's workflows still running (pinned to N)
4. Traffic CronJob independently starts new workflows (routed to latest)
5. Version N drains as its workflows complete
6. Meanwhile version N+2 deploys...

The decoupled traffic ensures continuous workflow pressure independent of the release cadence.
