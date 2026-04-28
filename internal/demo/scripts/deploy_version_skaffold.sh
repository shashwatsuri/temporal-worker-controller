#!/bin/sh
# Deploy a pre-built helloworld image version via Skaffold (non-interactive).
# This script is designed for CronJob pod execution and does not rebuild the image.
#
# Usage: sh deploy_version_skaffold.sh IMAGE_TAG [NAMESPACE] [RELEASE_NAME]
#   IMAGE_TAG      Full image tag to deploy (e.g., 025066239481.dkr.ecr.us-east-2.amazonaws.com/helloworld:SHA)
#   NAMESPACE      Kubernetes namespace (default: default)
#   RELEASE_NAME   Helm release name for helloworld (default: helloworld)
#
# Environment:
#   SKAFFOLD_DEFAULT_REPO  ECR repository (auto-detected from IMAGE_TAG if not set)
#   SKAFFOLD_PROFILE       Skaffold profile to use (default: helloworld-worker)
#   DRY_RUN                Set to 1 to preview deployment without applying
#   WAIT_FOR_TWD_ROLLOUT   Set to 1 to block until TWD status is Succeeded (default: 0)
#   ROLLOUT_TIMEOUT_SECONDS Timeout when WAIT_FOR_TWD_ROLLOUT=1 (default: 300)
#
# This script:
# 1. Extracts ECR repo from IMAGE_TAG
# 2. Generates artifacts JSON for skaffold deploy (no build)
# 3. Runs skaffold deploy --build-artifacts with pre-built image
# 4. Waits for rollout to complete and reports status

set -eu

TIMESTAMP=$(date '+%H:%M:%S')

# Parse arguments
IMAGE_TAG="${1:-}"
NAMESPACE="${2:-default}"
RELEASE_NAME="${3:-helloworld}"
SKAFFOLD_PROFILE="${SKAFFOLD_PROFILE:-helloworld-worker}"
DRY_RUN="${DRY_RUN:-0}"
WAIT_FOR_TWD_ROLLOUT="${WAIT_FOR_TWD_ROLLOUT:-0}"
ROLLOUT_TIMEOUT_SECONDS="${ROLLOUT_TIMEOUT_SECONDS:-300}"

if [ -z "$IMAGE_TAG" ]; then
  echo "[$TIMESTAMP] ERROR: IMAGE_TAG required"
  exit 1
fi

echo "[$TIMESTAMP] Deploying version: $IMAGE_TAG"
echo "[$TIMESTAMP] Namespace: $NAMESPACE, Release: $RELEASE_NAME, Profile: $SKAFFOLD_PROFILE"

# Verify tools exist
if ! command -v kubectl >/dev/null 2>&1; then
  echo "[$TIMESTAMP] ERROR: kubectl not found"
  exit 1
fi

if ! command -v skaffold >/dev/null 2>&1; then
  echo "[$TIMESTAMP] ERROR: skaffold not found"
  exit 1
fi

# Extract ECR repo from IMAGE_TAG
IMAGE_TAG_WITHOUT_SUFFIX=$(echo "$IMAGE_TAG" | cut -d: -f1)
ECR_REPO="${IMAGE_TAG_WITHOUT_SUFFIX%/*}"
TAG=$(echo "$IMAGE_TAG" | cut -d: -f2)

if [ -z "$SKAFFOLD_DEFAULT_REPO" ]; then
  SKAFFOLD_DEFAULT_REPO="$ECR_REPO"
  echo "[$TIMESTAMP] Using ECR repo from IMAGE_TAG: $SKAFFOLD_DEFAULT_REPO"
fi

# 1. Ensure namespace exists
echo "[$TIMESTAMP] Ensuring namespace $NAMESPACE exists..."
kubectl create namespace "$NAMESPACE" --dry-run=client -o yaml | kubectl apply -f - || true

# 2. Create skaffold artifacts JSON (tells skaffold to use pre-built image, no build)
ARTIFACTS_FILE="/tmp/skaffold-artifacts-${TIMESTAMP%:*}.json"
cat > "$ARTIFACTS_FILE" << EOF
{
  "builds": [
    {
      "imageName": "helloworld",
      "tag": "$IMAGE_TAG"
    }
  ]
}
EOF

echo "[$TIMESTAMP] Artifacts file: $ARTIFACTS_FILE"
cat "$ARTIFACTS_FILE"

# 3. Set environment for skaffold
export SKAFFOLD_DEFAULT_REPO
export NAMESPACE

# 4. Dry-run first if requested
if [ "$DRY_RUN" = "1" ]; then
  echo "[$TIMESTAMP] DRY_RUN=1 - previewing deployment (kubectl apply --dry-run=client)"
  
  skaffold deploy \
    --profile "$SKAFFOLD_PROFILE" \
    --build-artifacts "$ARTIFACTS_FILE" \
    --namespace "$NAMESPACE" \
    --dry-run=client \
    --no-prune 2>&1 || {
      echo "[$TIMESTAMP] ERROR: Skaffold dry-run failed"
      rm -f "$ARTIFACTS_FILE"
      exit 1
    }
  
  echo "[$TIMESTAMP] Dry-run successful; not applying changes"
  rm -f "$ARTIFACTS_FILE"
  exit 0
fi

# 5. Execute deployment
echo "[$TIMESTAMP] Deploying to namespace $NAMESPACE..."

skaffold deploy \
  --profile "$SKAFFOLD_PROFILE" \
  --build-artifacts "$ARTIFACTS_FILE" \
  --namespace "$NAMESPACE" \
  --no-prune \
  2>&1 || {
    echo "[$TIMESTAMP] ERROR: Skaffold deploy failed"
    rm -f "$ARTIFACTS_FILE"
    exit 1
  }

rm -f "$ARTIFACTS_FILE"

echo "[$TIMESTAMP] Skaffold deploy completed"

# 6. Optionally wait for TemporalWorkerDeployment rollout.
# For schedule-driven rainbow releases we default to non-blocking mode so
# new versions keep getting deployed even while older versions are still
# draining active workflows.
if [ "$WAIT_FOR_TWD_ROLLOUT" = "1" ]; then
  echo "[$TIMESTAMP] Waiting for TemporalWorkerDeployment/$RELEASE_NAME to rollout..."

  ROLLOUT_TIMEOUT="$ROLLOUT_TIMEOUT_SECONDS"
  POLL_INTERVAL=5
  ELAPSED=0

  while [ $ELAPSED -lt $ROLLOUT_TIMEOUT ]; do
    # Check if TWD exists and is ready
    TWD_STATUS=$(kubectl get temporalworkerdeployment "$RELEASE_NAME" -n "$NAMESPACE" -o json 2>/dev/null | jq -r '.status.phase // "Unknown"' 2>/dev/null || echo "Unknown")

    if [ "$TWD_STATUS" = "Succeeded" ]; then
      echo "[$TIMESTAMP] TemporalWorkerDeployment ready (status: $TWD_STATUS)"
      break
    elif [ "$TWD_STATUS" = "Failed" ] || [ "$TWD_STATUS" = "Error" ]; then
      echo "[$TIMESTAMP] ERROR: TemporalWorkerDeployment failed (status: $TWD_STATUS)"
      kubectl get temporalworkerdeployment "$RELEASE_NAME" -n "$NAMESPACE" -o yaml | head -100
      exit 1
    fi

    echo "[$TIMESTAMP] Waiting for rollout... (status: $TWD_STATUS, elapsed: ${ELAPSED}s/${ROLLOUT_TIMEOUT}s)"
    sleep $POLL_INTERVAL
    ELAPSED=$((ELAPSED + POLL_INTERVAL))
  done

  if [ $ELAPSED -ge $ROLLOUT_TIMEOUT ]; then
    echo "[$TIMESTAMP] WARNING: Rollout did not complete within ${ROLLOUT_TIMEOUT}s"
    echo "[$TIMESTAMP] Current status:"
    kubectl get temporalworkerdeployment "$RELEASE_NAME" -n "$NAMESPACE" -o yaml 2>/dev/null | head -50 || true
  else
    echo "[$TIMESTAMP] Rollout successful"
  fi
else
  TWD_STATUS=$(kubectl get temporalworkerdeployment "$RELEASE_NAME" -n "$NAMESPACE" -o json 2>/dev/null | jq -r '.status.phase // "Unknown"' 2>/dev/null || echo "Unknown")
  echo "[$TIMESTAMP] Non-blocking mode: submitted rollout for TemporalWorkerDeployment/$RELEASE_NAME (status now: $TWD_STATUS)"
fi

# 7. Verify image was deployed
DEPLOYED_IMAGE=$(kubectl get temporalworkerdeployment "$RELEASE_NAME" -n "$NAMESPACE" -o jsonpath='{.status.lastDeployedImage}' 2>/dev/null || echo "Unknown")
echo "[$TIMESTAMP] Last deployed image: $DEPLOYED_IMAGE"

if [ "$DEPLOYED_IMAGE" != "Unknown" ] && echo "$DEPLOYED_IMAGE" | grep -q "$TAG"; then
  echo "[$TIMESTAMP] Deployment complete: $IMAGE_TAG"
else
  echo "[$TIMESTAMP] WARNING: Deployed image may not match requested tag"
  echo "[$TIMESTAMP]   Requested: $IMAGE_TAG"
  echo "[$TIMESTAMP]   Deployed: $DEPLOYED_IMAGE"
fi

echo "[$TIMESTAMP] Deploy script completed successfully"
