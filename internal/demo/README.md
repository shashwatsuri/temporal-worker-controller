# Local Development Setup

This guide will help you set up and run the Temporal Worker Controller locally using Minikube.

### Prerequisites

- [Minikube](https://minikube.sigs.k8s.io/docs/start/)
- [Helm](https://helm.sh/docs/intro/install/)
- [Skaffold](https://skaffold.dev/docs/install/)
- [kubectl](https://kubernetes.io/docs/tasks/tools/install-kubectl/)
- Temporal Cloud account with API key or mTLS certificates
- Understanding of [Worker Versioning concepts](https://docs.temporal.io/production-deployment/worker-deployments/worker-versioning) (Pinned and Auto-Upgrade versioning behaviors)
- cert-manager is required for the `WorkerResourceTemplate` validating webhook (TLS). The controller Helm chart installs it automatically as a subchart (`certmanager.install: true` is set in the Skaffold profile).

> **Note**: This demo specifically showcases **Pinned** workflow behavior. All workflows in the demo will remain on the worker version where they started, demonstrating how the controller safely manages multiple worker versions simultaneously during deployments.

### Running the Local Demo

1. Start a local Minikube cluster:
   ```bash
   minikube start
   ```

2. Create the `skaffold.env` file:
   - Run:
     ```bash
     cp skaffold.example.env skaffold.env
     ```

   - Update the value of `TEMPORAL_NAMESPACE`, `TEMPORAL_ADDRESS`  in `skaffold.env` to match your configuration.

2. Set up Temporal Cloud Authentication:
   - Create a `certs` directory in the project root
   - Save your Temporal Cloud mTLS client certificates as:
     - `certs/client.pem`
     - `certs/client.key`
   - Create the Kubernetes secret:
     ```bash
     make create-cloud-mtls-secret
     ```
   - In `skaffold.env`, set:
     ```env
     TEMPORAL_API_KEY_SECRET_NAME=""
     TEMPORAL_MTLS_SECRET_NAME=temporal-cloud-mtls-secret
     ```

   NOTE: Alternatively, if you are using API keys, follow the steps below instead of mTLS:

   #### Using API Keys (alternative to mTLS)
   - Create a `certs` directory in the project root if not already present
   - Save your Temporal Cloud API key in a file (single line, no newline):
     ```bash
     echo -n "<YOUR_API_KEY>" > certs/api-key.txt
     ```
   - Create the Kubernetes Secret:
     ```bash
     make create-api-key-secret
     ```
   - In `skaffold.env`, set:
     ```env
     TEMPORAL_API_KEY_SECRET_NAME=temporal-api-key
     TEMPORAL_MTLS_SECRET_NAME=""
     ```
   - **Important**: When using API key authentication, you must use the regional endpoint instead of the namespace-specific endpoint. Set `TEMPORAL_ADDRESS` in `skaffold.env` to your region's endpoint, e.g.:
     ```env
     TEMPORAL_ADDRESS=us-east-1.aws.api.temporal.io:7233
     ```
     The namespace-specific endpoint (e.g. `<namespace>.tmprl.cloud:7233`) requires mTLS and will reject API key connections with a `tls: certificate required` error.
   - Note: Do not set both mTLS and API key for the same connection. If both present, the TemporalConnection Custom Resource
   Instance will not get installed in the k8s environment.

3. Build and deploy the Controller image to the local k8s cluster:
   ```bash
   skaffold run --profile worker-controller
   ```

### Testing Progressive Deployments

5. **Deploy the v1 worker**:
   ```bash
   skaffold run --profile helloworld-worker
   ```
   This deploys a TemporalWorkerDeployment and TemporalConnection Custom Resource using the **Progressive strategy**. Note that when there is no current version (as in an initial versioned worker deployment), the progressive steps are skipped and v1 becomes the current version immediately. All new workflow executions will now start on v1.
   
6. Watch the deployment status:
   ```bash
   watch kubectl get twd
   ```

7. **Apply load** to the v1 worker to simulate production traffic:
    ```bash
    make apply-load-sample-workflow
    ```

#### **Progressive Rollout of v2** (Non-Replay-Safe Change)

8. **Deploy a non-replay-safe workflow change**:
   ```bash
   git apply internal/demo/helloworld/changes/no-version-gate.patch
   skaffold run --profile helloworld-worker
   ```
   This applies a **non-replay-safe change** (switching an activity response type from string to a struct).

9. **Observe the progressive rollout managing incompatible versions**:
   - New workflow executions gradually shift from v1 to v2 following the configured rollout steps (1% → 5% → 10% → 50% → 100%)
   - **Both worker versions run simultaneously** - this is critical since the code changes are incompatible
   - v1 workers continue serving existing workflows (which would fail to replay on v2)
   - v2 workers handle new workflow executions with the updated code
   - This demonstrates how **Progressive rollout** safely handles breaking changes when you have existing traffic

#### Additional Rainbow Versions

After `no-version-gate.patch`, apply these patches one-by-one to create more concurrent versions:

```bash
git apply internal/demo/helloworld/changes/add-timer-and-email-greeting.patch
skaffold run --profile helloworld-worker

git apply internal/demo/helloworld/changes/increase-timer-v2.patch
skaffold run --profile helloworld-worker

git apply internal/demo/helloworld/changes/add-second-timer-v3.patch
skaffold run --profile helloworld-worker
```

For a faster visual effect, use higher load while rolling versions:

```bash
make apply-hpa-load
```

### Rainbow Automation Scripts

Apply one patch + deploy (and ensure load is running):

```bash
internal/demo/scripts/rainbow_step.sh internal/demo/helloworld/changes/add-timer-and-email-greeting.patch
```

Reset back to baseline worker code and redeploy:

```bash
internal/demo/scripts/reset_rainbow_demo.sh
```

By default this performs a hard reset (`HARD_RESET=1`): it deletes the existing `helloworld` release/TWD first, then redeploys baseline so old build IDs are cleared. The dashboard UI process is not stopped automatically.

Generate continuous rainbow versions with overlap:

```bash
DELAY_SECONDS=60 MAX_VERSIONS=6 sh internal/demo/scripts/continuous_versions.sh
```

On EKS, include your ECR repo when running the same command:

```bash
SKAFFOLD_DEFAULT_REPO=<account>.dkr.ecr.<region>.amazonaws.com \
DELAY_SECONDS=60 MAX_VERSIONS=6 \
sh internal/demo/scripts/continuous_versions.sh
```

Important routing semantics for this demo:

- New workflow starts are routed only between current and ramping target versions.
- Deprecated/draining versions do not receive new starts, but continue processing pinned, in-flight workflows.
- The dashboard hides deprecated cards by default, while still counting active overlap through draining/pinned activity.

### Monitoring 

You can monitor the controller's logs and the worker's status using:
```bash
# Output the controller pod's logs
kubectl logs -n temporal-system deployments/temporal-worker-controller-manager -f

# View TemporalWorkerDeployment status
kubectl get twd
```

### Live Rainbow Demo UI

For a lightweight live view while you apply load and roll changes, run the local dashboard:

```bash
cd internal/demo
go run ./dashboard --namespace default --name helloworld --port 8787
```

Then open `http://localhost:8787`.

The dashboard auto-refreshes every 1 second and shows:
- Active/current/target/deprecated worker versions
- Traffic split when the target version is ramping
- Per-version deployment readiness
- Progressing/Ready/TemporalConnection conditions
- A pinned-workflow signal (when deprecated versions are `Draining`)
- Live slot utilization from Prometheus metrics

**Important**: The dashboard now detects code patches properly because:
1. The Helm template includes a dynamic timestamp annotation that changes on every deploy
2. Kubernetes is configured to always pull the latest image (`imagePullPolicy: Always`)
3. When you run `skaffold run` after applying a patch, the pods will restart automatically even if the image tag hasn't changed

This means when you apply a patch and redeploy, the UI will show the new version appearing within 1-2 seconds.

### Testing WorkerResourceTemplate (per-version HPA)

`WorkerResourceTemplate` lets you attach Kubernetes resources — HPAs, PodDisruptionBudgets, etc. — to each worker version with running workers. The controller creates one copy per worker version with a running Deployment and wires it to the correct Deployment automatically.

The `WorkerResourceTemplate` validating webhook enforces that you have permission to create the embedded resource type yourself, and it requires TLS (provided by cert-manager, installed in step 3 above).

After deploying the helloworld worker (step 5), apply the example HPA:

```bash
kubectl apply -f examples/wrt-hpa.yaml
```

Watch the controller create an HPA for each worker version with running workers:

```bash
# See WorkerResourceTemplate status (Applied: true once the controller reconciles)
kubectl get WorkerResourceTemplate

# See the per-Build-ID HPAs
kubectl get hpa
```

You should see one HPA per worker version with running workers, with `scaleTargetRef` automatically pointing at the correct versioned Deployment.

When you deploy a new worker version (e.g., step 8), the controller creates a new HPA for the new Build ID and keeps the old one until that versioned Deployment is deleted during the sunset process.

See [docs/owned-resources.md](../../docs/worker-resource-templates.md) for full documentation.

> **Note**: If you plan to continue to the Metric-Based HPA Scaling Demo below, delete this WRT before proceeding. Two WRTs targeting the same TemporalWorkerDeployment with the same resource kind will create conflicting HPAs.
> ```bash
> kubectl delete -f examples/wrt-hpa.yaml
> ```

---

### Grafana Dashboard

A pre-built Grafana dashboard is included at `internal/demo/k8s/grafana-dashboard.json`. It shows:
- HPA current vs desired replicas per version
- Activity slot utilization per version
- Workflow and activity task backlog per version
- Raw per-pod slot gauges (used vs available)

**Import the dashboard:**

1. Port-forward Grafana:
   ```bash
   kubectl -n monitoring port-forward svc/prometheus-grafana 3000:80 &
   ```
2. Open http://localhost:3000 and log in
    ```bash
    Get your grafana admin user password by running:
    
      kubectl get secret --namespace monitoring -l app.kubernetes.io/component=admin-secret -o jsonpath="{.items[0].data.admin-password}" | base64 --decode ; echo
    ```
3. Go to **Dashboards → Import** → **Upload JSON file**
4. Select `internal/demo/k8s/grafana-dashboard.json`

The dashboard auto-refreshes every 10s and defaults to a 30-minute time window. Use it to tune HPA targets and observe per-version scaling behaviour during progressive rollouts.

---

### Metric-Based HPA Scaling Demo

This section demonstrates **per-version autoscaling** on real Temporal metrics: worker slot utilization (emitted by the worker pods) and approximate backlog count (from Temporal Cloud). The goal is a steady state of ~10 replicas per version, with each version's HPA responding independently during a progressive rollout.

The demo is structured in two phases so you can verify each layer before building on it.

> **Why the worker has only 5 activity slots per pod in this demo:** The Go SDK default is 1,000 slots per pod, which would require an impractically high workflow rate to saturate. The demo worker is configured with `MaxConcurrentActivityExecutionSize: 5` so that ~2 workflows/second drives 10 replicas at 70% utilization. Remove this limit in production.

#### Prerequisites

In addition to the main demo prerequisites, you need `kube-prometheus-stack` with `prometheus-adapter` as a subchart. This provides Prometheus (to scrape worker metrics and Temporal Cloud), a recording rule (to compute the utilization ratio), and the External Metrics API bridge that HPAs use.

```bash
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
helm repo update

helm install prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring --create-namespace \
  -f internal/demo/k8s/prometheus-stack-values.yaml

helm install prometheus-adapter prometheus-community/prometheus-adapter \
  -n monitoring \
  -f internal/demo/k8s/prometheus-adapter-values.yaml

kubectl apply -f internal/demo/k8s/servicemonitor.yaml
```

Wait for the stack to be ready:
```bash
kubectl -n monitoring rollout status deployment/prometheus-adapter
```

#### Phase 1: Scale on slot utilization

Slot utilization measures what fraction of each pod's activity task slots are in use. When workers are busy, the HPA adds replicas; when they drain, it removes them.

**Step 1 — Verify metrics are flowing.**

Port-forward Prometheus and confirm the recording rule is producing values:
```bash
kubectl -n monitoring port-forward svc/prometheus-kube-prometheus-prometheus 9090 &
# In a browser or with curl:
# http://localhost:9090/graph?g0.expr=temporal_slot_utilization
```

If `temporal_slot_utilization` returns no data, check the metric names on a running pod:
```bash
kubectl exec -n default \
  $(kubectl get pods -n default -l temporal.io/deployment-name=helloworld -o name | head -1) \
  -- curl -s localhost:9090/metrics | grep -i slot
```

Update the recording rule `expr` in `internal/demo/k8s/prometheus-stack-values.yaml` if the metric names differ, then run `helm upgrade prometheus ... -f internal/demo/k8s/prometheus-stack-values.yaml`.

**Step 2 — Apply the slot-utilization WRT.**
```bash
kubectl apply -f examples/wrt-hpa-slot-utilization.yaml
```

Confirm the HPA is reading the metric (not showing `<unknown>`):
```bash
kubectl get hpa -w
# TARGETS column should show e.g. "0/700m" within ~60 seconds
```

**Step 3 — Generate load.**
```bash
make apply-hpa-load   # starts ~2 workflows/sec; Ctrl-C to stop
```

Watch the pods scale up to ~10 replicas over the next few minutes:
```bash
kubectl get pods -l temporal.io/deployment-name=helloworld -w
```

Stop the load generator (`Ctrl-C`) and watch the HPA scale back down as in-flight activities complete.

#### Phase 2: Add approximate backlog count

`approximate_backlog_count` measures tasks queued in Temporal but not yet started on a worker. Adding it as a second HPA metric means the HPA scales up on *arriving* work even before slots are full — important for bursty traffic.

> **Note:** Temporal Cloud emits `temporal_approximate_backlog_count` with a combined
> `worker_version="<worker-deployment-name>_<build-id>"` label that easily exceeds Kubernetes max label
> length of 63 characters. The recording rule in `prometheus-stack-values.yaml` uses `label_replace` 
> to extract `temporal_worker_deployment_name` and `temporal_worker_build_id` as separate k8s-compatible 
> labels, producing `temporal_backlog_count_by_version`. The HPA then selects on those labels — the same 
> pair used by Phase 1. Temporal Cloud is in the process of rolling out the new separate labels, so this
> workaround is required until then.

**Step 1 — Create the Temporal Cloud credentials secret.**

Create a Temporal Cloud metrics API key (separate from the namespace API key) at Cloud UI → Settings → Observability → Generate API Key. Save it to `certs/metrics-api-key.txt`, then create the secret in the `monitoring` namespace:
```bash
kubectl create secret generic temporal-cloud-api-key \
  -n monitoring \
  --from-file=api-key=certs/metrics-api-key.txt
```

**Step 2 — Upgrade Prometheus and prometheus-adapter.**

The scrape config and recording rule are already configured in `prometheus-stack-values.yaml`:
```bash
helm upgrade prometheus prometheus-community/kube-prometheus-stack \
  -n monitoring -f internal/demo/k8s/prometheus-stack-values.yaml

helm upgrade prometheus-adapter prometheus-community/prometheus-adapter \
  -n monitoring -f internal/demo/k8s/prometheus-adapter-values.yaml
```

**Step 3 — Verify the backlog metric is flowing.**

```bash
kubectl -n monitoring port-forward svc/prometheus-kube-prometheus-prometheus 9092:9090 &
curl -s 'http://localhost:9092/api/v1/query?query=temporal_backlog_count_by_version' \
  | jq '.data.result'
```

You should see a result with `twd_name` and `build_id` labels. If the result is empty, wait 15–30s for the recording rule to evaluate.

**Step 4 — Apply the combined WRT.**
```bash
# Remove the Phase 1 WRT first to avoid two HPAs targeting the same Deployment
kubectl delete -f examples/wrt-hpa-slot-utilization.yaml
kubectl apply -f examples/wrt-hpa-backlog.yaml
```

#### Full progressive rollout demo

With load running, this demonstrates the core value proposition: v1 and v2 scale independently.

```bash
# Terminal 1: keep load running
make apply-hpa-load

# Terminal 2: deploy v2 while v1 is under load
skaffold run --profile helloworld-worker

# Terminal 3: watch the two HPAs
kubectl get hpa -w
# v1 HPA: replicas stay high while pinned workflows are running, then drop as they drain
# v2 HPA: replicas rise as new workflows are routed to v2 and its slots fill up
```

The progressive rollout steps (1% → 10% → 50% → 100%) gradually shift new workflow traffic to v2. The per-version HPAs respond to each version's actual load, not the aggregate — this is what makes the scaling correct during a deployment.

---

### Cleanup

To clean up the demo:
```bash
# Delete the Helm release
helm uninstall temporal-worker-controller -n temporal-system

# Stop Minikube
minikube stop
```

### Additional Operational commands

Complete cleanup (removes all clusters, cached images, and config):
```
minikube delete --all --purge
```

**What `minikube delete --all --purge` does:**
- `--all`: Deletes ALL minikube clusters (not just the default one)
- `--purge`: Completely removes all minikube data, cached images, and configuration files from your machine

This gives you a completely fresh start and frees up disk space used by minikube.

---

## Temporal Schedule-Based Version Generation (Recommended)

The recommended release trigger is now a Temporal Schedule that starts a release workflow on a fixed interval. The workflow creates a one-shot Kubernetes Job that runs the existing generation/build/deploy scripts (`generate_version_cron.sh`, `build_version_kaniko.sh`, `deploy_version_skaffold.sh`).

The schedule path runs deploys in non-blocking mode (`WAIT_FOR_TWD_ROLLOUT=0`) so a new target version can be submitted even while the current version is still handling/draining active workflows.

This keeps schedule semantics in Temporal while reusing the current image build and rollout pipeline.

### Deploy Temporal Schedule Trigger

```bash
# Deploy release manager and release job runner images/manifests
skaffold deploy --profile rainbow-release

# Or use the helper, which also suspends the legacy CronJob trigger
sh internal/demo/scripts/switch_to_temporal_schedule.sh
```

### Validate Schedule Trigger

```bash
# Release manager pod (should be Running)
kubectl -n default get pods -l app.kubernetes.io/name=release-manager

# Legacy CronJob should be suspended if helper script was used
kubectl -n default get cronjob rainbow-version-generator -o jsonpath='{.spec.suspend}'

# TemporalWorkerDeployment should keep receiving new target builds over time
kubectl -n default get temporalworkerdeployment helloworld -o json | jq '.status | {currentVersion,targetVersion,conditions}'
```

### Key Configuration

- Schedule interval: `schedule.cron` in `internal/demo/release/helm/release-manager/values.yaml`
- Schedule ID: `schedule.id`
- Overlap policy: set in code to `SCHEDULE_OVERLAP_POLICY_SKIP`
- Rollout wait behavior for scheduled deploy jobs: `release.waitForTWDRollout` (default `false` so new versions continue to deploy while prior versions drain)
- Release job image: `job.image.repository` and `job.image.tag`

---

## Kubernetes CronJob-Based Version Generation (EKS)

This path is now legacy/fallback. Prefer the Temporal Schedule-based trigger above.

Instead of running the perpetual `continuous_versions.sh` loop locally, you can deploy a Kubernetes CronJob that automatically generates and deploys new rainbow worker versions on a schedule. This is ideal for EKS deployments where the cluster runs continuously.

### Prerequisites for CronJob Setup

1. **AWS Account and EKS cluster**: Cluster must have IRSA (IAM Roles for Service Accounts) enabled
2. **ECR repository**: For pushing multi-architecture images
3. **Kubectl access**: To the EKS cluster
4. **AWS CLI**: Configured with credentials to create IAM roles

### Deploy the CronJob

#### Step 1: Create IAM Role for IRSA

Create an IAM role that allows the CronJob pods to push images to ECR and access Kubernetes APIs:

```bash
# Set your AWS account ID and region
ACCOUNT_ID=025066239481
REGION=us-east-2
CLUSTER_NAME=temporal-rainbow-deployment-demo
OIDC_ID=$(aws eks describe-cluster --name $CLUSTER_NAME --region $REGION --query 'cluster.identity.oidc.issuer' --output text | cut -d '/' -f 5)

# Create the IAM role
ROLE_NAME=rainbow-version-generator-role
TRUST_POLICY="{
  \"Version\": \"2012-10-17\",
  \"Statement\": [
    {
      \"Effect\": \"Allow\",
      \"Principal\": {
        \"Federated\": \"arn:aws:iam::$ACCOUNT_ID:oidc-provider/oidc.eks.$REGION.amazonaws.com/id/$OIDC_ID\"
      },
      \"Action\": \"sts:AssumeRoleWithWebIdentity\",
      \"Condition\": {
        \"StringEquals\": {
          \"oidc.eks.$REGION.amazonaws.com/id/$OIDC_ID:sub\": \"system:serviceaccount:default:rainbow-version-generator\",
          \"oidc.eks.$REGION.amazonaws.com/id/$OIDC_ID:aud\": \"sts.amazonaws.com\"
        }
      }
    }
  ]
}"

aws iam create-role \
  --role-name $ROLE_NAME \
  --assume-role-policy-document "$TRUST_POLICY" \
  --region $REGION || echo "Role may already exist"

# Attach ECR permissions
aws iam put-role-policy \
  --role-name $ROLE_NAME \
  --policy-name ECRAccess \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
      {
        \"Effect\": \"Allow\",
        \"Action\": [
          \"ecr:GetAuthorizationToken\",
          \"ecr:GetDownloadUrlForLayer\",
          \"ecr:BatchGetImage\",
          \"ecr:PutImage\",
          \"ecr:InitiateLayerUpload\",
          \"ecr:UploadLayerPart\",
          \"ecr:CompleteLayerUpload\",
          \"ecr:BatchCheckLayerAvailability\",
          \"ecr:DescribeImages\",
          \"ecr:ListImages\"
        ],
        \"Resource\": \"arn:aws:ecr:$REGION:$ACCOUNT_ID:repository/helloworld*\"
      }
    ]
  }" \
  --region $REGION
```

#### Step 2: Update CronJob Manifest

Edit `internal/demo/k8s/rainbow-cronjob.yaml` and replace:
- `ACCOUNT_ID` with your AWS account ID (e.g., 025066239481)
- `REGION` with your AWS region (e.g., us-east-2)
- `REPO_URL` and `REPO_REF` if using a fork or different branch

#### Step 3: Apply CronJob Resources

```bash
# Apply the CronJob, ServiceAccount, RBAC, and ConfigMaps
kubectl apply -f internal/demo/k8s/rainbow-cronjob.yaml

# Verify resources were created
kubectl get cronjob rainbow-version-generator
kubectl get sa rainbow-version-generator
kubectl get configmap rainbow-version-state
```

#### Step 4: Verify the CronJob

The CronJob runs every 5 minutes by default. Monitor its progress:

```bash
# Watch for new jobs
kubectl get jobs -l app=rainbow-version-generator -w

# View logs from the latest job
JOB=$(kubectl get jobs -l app=rainbow-version-generator -o name | sort -V | tail -1)
kubectl logs $JOB -c orchestrator

# Check version state
kubectl get configmap rainbow-version-state -o yaml

# Verify new versions were deployed
kubectl port-forward svc/rainbow-dashboard 8787:8787 &
curl -s http://localhost:8787/api/state | jq '.versionCount'
```

### Manual Job Trigger

To manually run the version generator outside the CronJob schedule:

```bash
# Create a one-time job from the CronJob template
kubectl create job rainbow-version-manual-$(date +%s) --from=cronjob/rainbow-version-generator

# Watch the job
kubectl get jobs -w

# View logs
JOB=$(kubectl get jobs -o name | grep rainbow-version-manual | sort -V | tail -1)
kubectl logs $JOB -c orchestrator -f
```

### Monitoring and Troubleshooting

#### View CronJob Status

```bash
kubectl describe cronjob rainbow-version-generator
kubectl get events -A --sort-by='.lastTimestamp' | grep rainbow
```

#### Check Job Logs

```bash
# List all version generator jobs
kubectl get jobs -l app=rainbow-version-generator

# View successful job logs
kubectl logs <job-name> -c orchestrator

# View failed job logs with full output
kubectl logs <job-name> -c orchestrator --all-containers=true
```

#### Emit Diagnostics

The CronJob pod includes a diagnostic utility. To run it:

```bash
# Run diagnostics in a pod
kubectl run -it --rm diagnostics \
  --image=alpine:3.18 \
  --serviceaccount=rainbow-version-generator \
  -- sh -c "apk add jq kubectl; kubectl get configmap rainbow-version-state -o yaml"
```

### Rollback Procedures

#### Option 1: Disable the CronJob (Keep Infrastructure)

If versions are being generated incorrectly, pause new generation:

```bash
# Disable the CronJob
kubectl patch cronjob rainbow-version-generator --type merge -p '{"spec":{"suspend":true}}'

# Re-enable later
kubectl patch cronjob rainbow-version-generator --type merge -p '{"spec":{"suspend":false}}'
```

#### Option 2: Restore to Baseline Version

Redeploy the baseline helloworld worker without version mutations:

```bash
# This resets worker.go to baseline and redeployes
sh internal/demo/scripts/reset_rainbow_demo.sh

# Or manually via Helm:
skaffold deploy --profile helloworld-worker
```

#### Option 3: Delete and Recreate CronJob

If the CronJob is in a bad state:

```bash
# Delete all CronJob resources
kubectl delete cronjob,sa,clusterrole,clusterrolebinding,configmap \
  -l app=rainbow-version-generator

# Recreate from manifest
kubectl apply -f internal/demo/k8s/rainbow-cronjob.yaml
```

#### Option 4: Examine and Fix Version State

If version numbering is corrupted:

```bash
# View current state
kubectl get configmap rainbow-version-state -o jsonpath='{.data.current_version}'

# Reset version counter to 0
kubectl patch configmap rainbow-version-state \
  --type merge \
  -p '{"data":{"current_version":"0"}}'

# Delete version generator jobs and let them restart
kubectl delete jobs -l app=rainbow-version-generator
```

### CronJob Architecture

The CronJob orchestrates three phases:

1. **Phase 1 - Version Generation** (`generate_version_cron.sh`):
   - Reads version counter from ConfigMap
   - Checks out repository at specified ref
   - Mutates `worker.go` with version-specific sleep and greeting
   - Commits changes and gets git SHA

2. **Phase 2 - Build** (`build_version_kaniko.sh`):
   - Builds linux/amd64 image using Kaniko
   - Builds linux/arm64 image using Kaniko
   - Creates and pushes manifest list to ECR
   - Uses IRSA for ECR authentication

3. **Phase 3 - Deploy** (`deploy_version_skaffold.sh`):
   - Uses `skaffold deploy` with precomputed image tag
   - Avoids rebuilding image; uses pre-built manifest list
   - Waits for TemporalWorkerDeployment rollout
   - Verifies deployment succeeded

### Performance Tuning

- **Schedule interval**: Edit `spec.schedule` in `rainbow-cronjob.yaml` (default: `*/5 * * * *`)
- **Concurrency**: Set `concurrencyPolicy` to `Forbid` (default) or `Replace` for single-run guarantee
- **Resource limits**: Adjust `resources.limits` based on your cluster capacity
- **Retry policy**: Modify `backoffLimit` (default: 1) to control failure retries
- **History**: Adjust `successfulJobsHistoryLimit` and `failedJobsHistoryLimit` for log retention

### Disabling the CronJob

To remove automatic version generation and return to manual control:

```bash
# Delete the CronJob while keeping dashboard infrastructure
kubectl delete cronjob rainbow-version-generator

# Keep running perpetual loop locally (if desired)
SKAFFOLD_DEFAULT_REPO=025066239481.dkr.ecr.us-east-2.amazonaws.com \
DELAY_SECONDS=180 \
sh internal/demo/scripts/continuous_versions.sh
``` 
