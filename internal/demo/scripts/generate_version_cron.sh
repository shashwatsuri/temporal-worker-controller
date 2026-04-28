#!/bin/sh
# Generates a single rainbow demo version for Kubernetes CronJob execution.
# This is a one-shot variant of generate_version.sh that reads/updates version state
# from a Kubernetes ConfigMap and emits IMAGE_TAG for use by build pipeline.
#
# Usage: sh generate_version_cron.sh
#
# Environment (required):
#   WORKER_FILE              Path to worker.go (e.g., internal/demo/helloworld/worker.go)
#   NAMESPACE                Kubernetes namespace where version ConfigMap is stored
#   CONFIG_MAP_NAME          Name of ConfigMap for version state (default: rainbow-version-state)
#   NEXT_VERSION             Optional: version number to use; if unset, auto-increment from ConfigMap
#
# Environment (optional):
#   GIT_COMMIT_SHA           Use explicit git SHA (normally computed from git rev-parse)
#
# Output:
#   IMAGE_TAG - the full ECR image tag in format REPO/IMAGE:COMMIT_SHA

set -eu

TIMESTAMP=$(date '+%H:%M:%S')
ROOT_DIR="${ROOT_DIR:-.}"
WORKER_FILE="${WORKER_FILE:-internal/demo/helloworld/worker.go}"
NAMESPACE="${NAMESPACE:-default}"
CONFIG_MAP_NAME="${CONFIG_MAP_NAME:-rainbow-version-state}"

cd "$ROOT_DIR"

# Ensure git repo and required tools exist
if [ ! -d ".git" ]; then
  echo "[$TIMESTAMP] ERROR: Not a git repository"
  exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
  echo "[$TIMESTAMP] ERROR: kubectl not found in PATH"
  exit 1
fi

# 1. Get or initialize version counter from ConfigMap
echo "[$TIMESTAMP] Reading version state from ConfigMap $NAMESPACE/$CONFIG_MAP_NAME"

CONFIG_MAP_JSON=$(kubectl get configmap "$CONFIG_MAP_NAME" -n "$NAMESPACE" -o json 2>/dev/null || echo "{}")

# Initialize if ConfigMap doesn't exist
if [ "$CONFIG_MAP_JSON" = "{}" ]; then
  echo "[$TIMESTAMP] ConfigMap not found; will create it after version generation"
  CURRENT_VERSION=0
else
  # Extract current_version from data.current_version
  CURRENT_VERSION=$(echo "$CONFIG_MAP_JSON" | jq -r '.data.current_version // "0"' 2>/dev/null || echo "0")
fi

# Determine next version
if [ -n "${NEXT_VERSION:-}" ]; then
  VERSION="$NEXT_VERSION"
  echo "[$TIMESTAMP] Using explicit NEXT_VERSION=$VERSION"
else
  VERSION=$((CURRENT_VERSION + 1))
  echo "[$TIMESTAMP] Auto-incrementing: $CURRENT_VERSION -> $VERSION"
fi

# 2. Verify worker.go exists
if [ ! -f "$WORKER_FILE" ]; then
  echo "[$TIMESTAMP] ERROR: $WORKER_FILE not found"
  exit 1
fi

echo "[$TIMESTAMP] Generating version $VERSION"

# 3. Compute sleep duration (same formula as generate_version.sh)
SLEEP_SECS=$(( 150 + (VERSION * 11) % 91 ))

# 4. Restore worker.go to a baseline state (from HEAD, assume we're on baseline)
# For CronJob runs, we assume the working tree is fresh from repo checkout
git checkout -- "$WORKER_FILE" 2>/dev/null || true

# 5. Mutate worker.go with version-specific changes using awk (same pattern as generate_version.sh)
awk -v ver="$VERSION" -v sleep_secs="$SLEEP_SECS" '
/\/\/ Return the greeting/ {
  print ""
  print "\t// Non-replay-safe change introduced by Rainbow demo v" ver
  print "\tif err := workflow.Sleep(ctx, " sleep_secs "*time.Second); err != nil {"
  print "\t\treturn \"\", err"
  print "\t}"
  print ""
}
/return fmt.Sprintf\(/ && /subject\), nil/ {
  print "\treturn fmt.Sprintf(\"Hello %s (rainbow demo v" ver ", sleep=" sleep_secs "s)\", subject), nil"
  next
}
{ print }
' "$WORKER_FILE" > "${WORKER_FILE}.tmp"

mv "${WORKER_FILE}.tmp" "$WORKER_FILE"

# 6. Enforce longer RolloutGate timeouts for overlap-focused rollouts
# Match both `time.Minute` and `N*time.Minute` forms to stay resilient to baseline changes.
sed -E -i.bak 's/util\.SetActivityTimeout\(ctx, *([0-9]+\*)?time\.Minute\)/util.SetActivityTimeout(ctx, 12*time.Minute)/' "$WORKER_FILE"
sed -E -i.bak 's/WorkflowExecutionTimeout: *([0-9]+\*)?time\.Minute/WorkflowExecutionTimeout: 12*time.Minute/' "$WORKER_FILE"
rm -f "${WORKER_FILE}.bak"

# 7. Verify mutations were applied
if ! grep -q "rainbow demo v$VERSION" "$WORKER_FILE"; then
  echo "[$TIMESTAMP] ERROR: Failed to insert version marker into worker.go"
  git checkout -- "$WORKER_FILE"
  exit 1
fi

if ! grep -q "util.SetActivityTimeout(ctx, 12\*time.Minute)" "$WORKER_FILE"; then
  echo "[$TIMESTAMP] ERROR: Failed to enforce RolloutGate timeout"
  git checkout -- "$WORKER_FILE"
  exit 1
fi

if ! grep -q "WorkflowExecutionTimeout: 12\*time.Minute" "$WORKER_FILE"; then
  echo "[$TIMESTAMP] ERROR: Failed to enforce RolloutGate child workflow timeout"
  git checkout -- "$WORKER_FILE"
  exit 1
fi

echo "[$TIMESTAMP] worker.go mutated: sleep=${SLEEP_SECS}s, version=$VERSION"

# 8. Commit the mutation
git add "$WORKER_FILE"
git commit -m "Rainbow demo v${VERSION}: sleep=${SLEEP_SECS}s" >/dev/null 2>&1 || true
GIT_COMMIT_SHA=$(git rev-parse HEAD)

echo "[$TIMESTAMP] Committed version $VERSION with SHA $GIT_COMMIT_SHA"

# 9. Detect ECR repo from current context (same logic as generate_version.sh)
CURRENT_CONTEXT=$(kubectl config current-context 2>/dev/null || true)
IS_EKS_CONTEXT=0
case "$CURRENT_CONTEXT" in
  arn:aws:eks:*) IS_EKS_CONTEXT=1 ;;
esac

DEPLOY_REPO="${SKAFFOLD_DEFAULT_REPO:-}"
if [ "$IS_EKS_CONTEXT" = "1" ] && [ -z "$DEPLOY_REPO" ]; then
  AWS_REGION=$(echo "$CURRENT_CONTEXT" | cut -d: -f4)
  AWS_ACCOUNT_ID=$(echo "$CURRENT_CONTEXT" | cut -d: -f5)
  DEPLOY_REPO="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
  echo "[$TIMESTAMP] EKS context detected; using ECR repo: $DEPLOY_REPO"
fi

if [ -z "$DEPLOY_REPO" ] && [ -n "${AWS_REGION:-}" ] && command -v aws >/dev/null 2>&1; then
  AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null || true)
  if [ -n "$AWS_ACCOUNT_ID" ] && [ "$AWS_ACCOUNT_ID" != "None" ]; then
    DEPLOY_REPO="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com"
    echo "[$TIMESTAMP] Derived ECR repo from AWS identity: $DEPLOY_REPO"
  fi
fi

if [ -z "$DEPLOY_REPO" ]; then
  # Local/Minikube deployment
  IMAGE_TAG="helloworld:${GIT_COMMIT_SHA}"
  echo "[$TIMESTAMP] Local deployment detected; IMAGE_TAG=$IMAGE_TAG"
else
  # EKS deployment with ECR
  IMAGE_TAG="${DEPLOY_REPO}/helloworld:${GIT_COMMIT_SHA}"
  echo "[$TIMESTAMP] EKS deployment detected; IMAGE_TAG=$IMAGE_TAG"
fi

# 10. Update or create ConfigMap with new version state
echo "[$TIMESTAMP] Updating ConfigMap with version $VERSION"
kubectl patch configmap "$CONFIG_MAP_NAME" \
  -n "$NAMESPACE" \
  -p "{\"data\":{\"current_version\":\"$VERSION\",\"last_image_tag\":\"$IMAGE_TAG\",\"last_generated\":\"$(date -u +'%Y-%m-%dT%H:%M:%SZ')\"}}" \
  --type merge 2>/dev/null || kubectl create configmap "$CONFIG_MAP_NAME" \
  -n "$NAMESPACE" \
  --from-literal=current_version="$VERSION" \
  --from-literal=last_image_tag="$IMAGE_TAG" \
  --from-literal=last_generated="$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "[$TIMESTAMP] Version $VERSION generation complete"
echo "[$TIMESTAMP] OUTPUT: IMAGE_TAG=$IMAGE_TAG"

# 11. Emit IMAGE_TAG for consumption by build/deploy steps
echo "$IMAGE_TAG"
