#!/bin/sh
# Generates a single dynamic worker version by modifying worker.go and deploying.
# Usage: sh generate_version.sh [version_number]
#   version_number - optional; auto-increments if not provided
#
# Environment:
#   SKIP_DEPLOY=1    modify and commit but skip skaffold run
set -eu

ROOT_DIR="$(git rev-parse --show-toplevel)"
cd "$ROOT_DIR"

WORKER_FILE="internal/demo/helloworld/worker.go"
SKIP_DEPLOY="${SKIP_DEPLOY:-0}"

# Determine version number
if [ -n "${1:-}" ]; then
  VERSION="$1"
else
  # Count existing demo version commits on this branch to auto-increment
  EXISTING=$(git log --oneline -- "$WORKER_FILE" | grep -c "Rainbow demo v" || true)
  VERSION=$((EXISTING + 1))
fi

TIMESTAMP=$(date '+%H:%M:%S')
echo "[$TIMESTAMP] Generating version $VERSION"

# Find the upstream baseline commit — the last commit that is NOT a "Rainbow demo" commit.
# This is used as a stable restore point so each version always starts from the same base.
BASE_COMMIT=$(git log --oneline -- "$WORKER_FILE" | grep -v "^[a-f0-9]* Rainbow demo v" | head -1 | awk '{print $1}')
if [ -z "$BASE_COMMIT" ]; then
  echo "[$TIMESTAMP] ERROR: Could not find baseline commit (non-Rainbow-demo commit) for $WORKER_FILE"
  exit 1
fi
echo "[$TIMESTAMP] Restoring baseline from commit $BASE_COMMIT"
git show "${BASE_COMMIT}:${WORKER_FILE}" > "$WORKER_FILE"

# --- Compute values that change per version ---
# Keep sleep bounded so gate workflows (which execute HelloWorld) can complete
# before the next version is generated.
# 150s-240s sleep + up to 30s activity latency => <=270s per gate workflow.
SLEEP_SECS=$(( 150 + (VERSION * 11) % 91 ))

# Build the new worker.go with this version's changes using awk.
# Always rewrites from the restored baseline, so patterns are stable.
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

# Keep RolloutGate timeouts long enough for overlap-focused demo rollouts.
# Match both `time.Minute` and `N*time.Minute` forms to stay resilient to baseline changes.
sed -E -i.bak 's/util\.SetActivityTimeout\(ctx, *([0-9]+\*)?time\.Minute\)/util.SetActivityTimeout(ctx, 12*time.Minute)/' "$WORKER_FILE"
sed -E -i.bak 's/WorkflowExecutionTimeout: *([0-9]+\*)?time\.Minute/WorkflowExecutionTimeout: 12*time.Minute/' "$WORKER_FILE"
rm -f "${WORKER_FILE}.bak"

# Verify the change was applied
if ! grep -q "rainbow demo v$VERSION" "$WORKER_FILE"; then
  echo "[$TIMESTAMP] ERROR: Failed to modify worker.go - pattern not found"
  git restore "$WORKER_FILE"
  exit 1
fi

if ! grep -q "util.SetActivityTimeout(ctx, 12\*time.Minute)" "$WORKER_FILE"; then
  echo "[$TIMESTAMP] ERROR: Failed to enforce RolloutGate timeout"
  git restore "$WORKER_FILE"
  exit 1
fi

if ! grep -q "WorkflowExecutionTimeout: 12\*time.Minute" "$WORKER_FILE"; then
  echo "[$TIMESTAMP] ERROR: Failed to enforce RolloutGate child workflow timeout"
  git restore "$WORKER_FILE"
  exit 1
fi

echo "[$TIMESTAMP] worker.go updated: sleep=${SLEEP_SECS}s, greeting=v$VERSION"

# Commit so each version gets a new git SHA (which Skaffold uses as image tag)
git add "$WORKER_FILE"
git commit -m "Rainbow demo v${VERSION}: sleep=${SLEEP_SECS}s" --allow-empty >/dev/null 2>&1 || true

echo "[$TIMESTAMP] Committed version $VERSION"

if [ "$SKIP_DEPLOY" = "1" ]; then
  echo "[$TIMESTAMP] SKIP_DEPLOY=1 set - skipping skaffold run"
  exit 0
fi

echo "[$TIMESTAMP] Deploying..."

# Detect EKS context and ensure we use an ECR repo for deploys.
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
  echo "[$TIMESTAMP] EKS context detected; using derived ECR repo: $DEPLOY_REPO"
fi

if [ "$IS_EKS_CONTEXT" != "1" ] && [ -n "$DEPLOY_REPO" ]; then
  echo "[$TIMESTAMP] Non-EKS context detected; ignoring SKAFFOLD_DEFAULT_REPO=$DEPLOY_REPO for local deploy"
  DEPLOY_REPO=""
fi

if [ "$IS_EKS_CONTEXT" = "1" ] && [ -n "$DEPLOY_REPO" ] && echo "$DEPLOY_REPO" | grep -q "dkr.ecr"; then
  # EKS deployment: build multi-platform image manually (skaffold docker driver can't merge them)
  COMMIT_SHA=$(git rev-parse HEAD)
  IMAGE_TAG="${DEPLOY_REPO}/helloworld:${COMMIT_SHA}"
  
  echo "[$TIMESTAMP] Building multi-platform image for EKS: $IMAGE_TAG"
  docker buildx build \
    --platform linux/amd64,linux/arm64 \
    --build-arg WORKER=helloworld \
    --build-arg DD_GIT_COMMIT_SHA="$COMMIT_SHA" \
    --build-arg DD_GIT_REPOSITORY_URL="github.com/temporalio/temporal-worker-controller" \
    --tag "$IMAGE_TAG" \
    --push \
    -f internal/demo/Dockerfile \
    internal/demo/
  
  echo "[$TIMESTAMP] Deploying with skaffold (no build)"
  ARTIFACTS_FILE=$(mktemp)
  echo "{\"builds\":[{\"imageName\":\"helloworld\",\"tag\":\"$IMAGE_TAG\"}]}" > "$ARTIFACTS_FILE"
  SKAFFOLD_DEFAULT_REPO="$DEPLOY_REPO" \
  skaffold deploy --kube-context "$CURRENT_CONTEXT" --profile helloworld-worker \
    --build-artifacts "$ARTIFACTS_FILE"
  rm -f "$ARTIFACTS_FILE"
else
  # Local deployment defaults to minikube unless overridden.
  LOCAL_KUBE_CONTEXT="${LOCAL_KUBE_CONTEXT:-minikube}"
  if ! kubectl config get-contexts -o name | grep -qx "$LOCAL_KUBE_CONTEXT"; then
    echo "[$TIMESTAMP] ERROR: Local kube context '$LOCAL_KUBE_CONTEXT' not found"
    echo "[$TIMESTAMP] Set LOCAL_KUBE_CONTEXT to an existing local cluster context"
    exit 1
  fi
  echo "[$TIMESTAMP] Local deploy context: $LOCAL_KUBE_CONTEXT"

  # Local deployment (Minikube): build/load image directly into local cluster runtime.
  unset SKAFFOLD_DEFAULT_REPO || true
  skaffold run --kube-context "$LOCAL_KUBE_CONTEXT" --profile helloworld-worker
fi

echo "[$TIMESTAMP] Version $VERSION deployed"
