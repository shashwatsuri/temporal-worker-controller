#!/usr/bin/env bash
set -euo pipefail

# Deploys controller + helloworld + dashboard to the active EKS context.
# Optional env vars:
AWS_PROFILE="${AWS_PROFILE:-bitovi-temporal}"
#   DASHBOARD_NAMESPACE=<namespace> (default: default)
#   DASHBOARD_NAME=<worker name> (default: helloworld)
#   EXPOSE_PUBLIC=true|false (default: false)

DASHBOARD_NAMESPACE="${DASHBOARD_NAMESPACE:-default}"
DASHBOARD_NAME="${DASHBOARD_NAME:-helloworld}"
EXPOSE_PUBLIC="${EXPOSE_PUBLIC:-false}"

# Override if needed (for mixed-arch clusters or troubleshooting): linux/amd64 or linux/arm64
TARGET_PLATFORM="${TARGET_PLATFORM:-}"

CTX="$(kubectl config current-context)"
if [[ ! "$CTX" =~ ^arn:aws:eks: ]]; then
  echo "Current kubectl context is not EKS: $CTX"
  echo "Use: kubectl config use-context <your-eks-context>"
  exit 1
fi

REGION="$(echo "$CTX" | sed -E 's#arn:aws:eks:([^:]+):([0-9]+):cluster/(.*)#\1#')"
ACCOUNT_ID="$(echo "$CTX" | sed -E 's#arn:aws:eks:([^:]+):([0-9]+):cluster/(.*)#\2#')"
CLUSTER_NAME="$(echo "$CTX" | sed -E 's#arn:aws:eks:([^:]+):([0-9]+):cluster/(.*)#\3#')"
ECR_BASE="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"

AWS_CMD=(aws)
if [[ -n "${AWS_PROFILE:-}" ]]; then
  AWS_CMD+=(--profile "$AWS_PROFILE")
fi

echo "Using EKS cluster: ${CLUSTER_NAME} (${REGION})"

# Default to the first node architecture so pushed images match what EKS can run.
if [[ -z "$TARGET_PLATFORM" ]]; then
  NODE_ARCH="$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}' 2>/dev/null || true)"
  case "$NODE_ARCH" in
    amd64)
      TARGET_PLATFORM="linux/amd64"
      ;;
    arm64)
      TARGET_PLATFORM="linux/arm64"
      ;;
    *)
      TARGET_PLATFORM="linux/amd64"
      echo "Warning: couldn't detect node architecture (got '$NODE_ARCH'); defaulting TARGET_PLATFORM=$TARGET_PLATFORM"
      ;;
  esac
fi

echo "Using image platform: ${TARGET_PLATFORM}"

SKAFFOLD_ARCH_PROFILE=""
case "$TARGET_PLATFORM" in
  linux/amd64)
    SKAFFOLD_ARCH_PROFILE="eks-amd64"
    ;;
  linux/arm64)
    SKAFFOLD_ARCH_PROFILE="eks-arm64"
    ;;
  *)
    echo "Unsupported TARGET_PLATFORM: $TARGET_PLATFORM"
    echo "Expected linux/amd64 or linux/arm64"
    exit 1
    ;;
esac

echo "Using skaffold arch profile: ${SKAFFOLD_ARCH_PROFILE}"

if ! "${AWS_CMD[@]}" sts get-caller-identity >/dev/null 2>&1; then
  echo "AWS credentials not available for this shell."
  if [[ -n "${AWS_PROFILE:-}" ]]; then
    echo "Run: aws sso login --profile ${AWS_PROFILE}"
  else
    echo "Run: aws sso login"
  fi
  exit 1
fi

for repo in temporal-worker-controller helloworld rainbow-dashboard; do
  "${AWS_CMD[@]}" ecr describe-repositories --repository-names "$repo" >/dev/null 2>&1 || \
    "${AWS_CMD[@]}" ecr create-repository --repository-name "$repo" >/dev/null
  echo "ECR repo ready: $repo"
done

"${AWS_CMD[@]}" ecr get-login-password --region "$REGION" | \
  docker login --username AWS --password-stdin "$ECR_BASE"

echo "Deploying controller via skaffold profile worker-controller"
SKAFFOLD_DEFAULT_REPO="$ECR_BASE" skaffold run \
  --cache-artifacts=false \
  --platform "$TARGET_PLATFORM" \
  --profile "worker-controller,${SKAFFOLD_ARCH_PROFILE}"

echo "Deploying demo worker via skaffold profile helloworld-worker"
SKAFFOLD_DEFAULT_REPO="$ECR_BASE" skaffold run \
  --cache-artifacts=false \
  --platform "$TARGET_PLATFORM" \
  --profile "helloworld-worker,${SKAFFOLD_ARCH_PROFILE}"

echo "Building and pushing dashboard image"
docker buildx build --platform "$TARGET_PLATFORM" -t "$ECR_BASE/rainbow-dashboard:latest" -f internal/demo/Dockerfile.dashboard . --push

echo "Applying dashboard manifests"
# Cleanup from older script behavior: remove literal NAMESPACE env so apply with valueFrom succeeds.
kubectl -n "$DASHBOARD_NAMESPACE" set env deployment/rainbow-dashboard NAMESPACE- >/dev/null 2>&1 || true
kubectl apply -f internal/demo/k8s/dashboard-deployment.yaml
kubectl -n "$DASHBOARD_NAMESPACE" set image deployment/rainbow-dashboard \
  dashboard="$ECR_BASE/rainbow-dashboard:latest"
kubectl -n "$DASHBOARD_NAMESPACE" patch deployment rainbow-dashboard --type strategic -p \
  '{"spec":{"template":{"spec":{"containers":[{"name":"dashboard","imagePullPolicy":"Always"}]}}}}'
kubectl -n "$DASHBOARD_NAMESPACE" patch deployment rainbow-dashboard --type strategic -p \
  "{\"spec\":{\"template\":{\"spec\":{\"containers\":[{\"name\":\"dashboard\",\"args\":[\"--namespace\",\"$DASHBOARD_NAMESPACE\",\"--name\",\"$DASHBOARD_NAME\",\"--port\",\"8787\"]}]}}}}"

if [[ "$EXPOSE_PUBLIC" == "true" ]]; then
  kubectl -n "$DASHBOARD_NAMESPACE" patch svc rainbow-dashboard -p '{"spec":{"type":"LoadBalancer"}}'
  echo "Dashboard service set to LoadBalancer."
  echo "Get external endpoint with: kubectl -n $DASHBOARD_NAMESPACE get svc rainbow-dashboard"
else
  echo "Dashboard service left as ClusterIP."
  echo "Use: kubectl -n $DASHBOARD_NAMESPACE port-forward svc/rainbow-dashboard 8787:8787"
fi

echo "Done."
