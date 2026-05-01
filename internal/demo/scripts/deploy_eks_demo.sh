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
DEMO_NAMESPACE="${DEMO_NAMESPACE:-$DASHBOARD_NAMESPACE}"
DEMO_RELEASE_NAME="${DEMO_RELEASE_NAME:-$DASHBOARD_NAME}"
DEMO_RUNNER_REPO_NAME="${DEMO_RUNNER_REPO_NAME:-rainbow-release-job}"
DEMO_RUNNER_LOOP_INTERVAL_SECONDS="${DEMO_RUNNER_LOOP_INTERVAL_SECONDS:-180}"
DEMO_RUNNER_MAX_RUNNING_WORKFLOWS="${DEMO_RUNNER_MAX_RUNNING_WORKFLOWS:-10}"
DEMO_RUNNER_MAX_NEW_WORKFLOWS_PER_RUN="${DEMO_RUNNER_MAX_NEW_WORKFLOWS_PER_RUN:-5}"
DEMO_RUNNER_WORKFLOWS_PER_RUN="${DEMO_RUNNER_WORKFLOWS_PER_RUN:-5}"
DEMO_RUNNER_WAIT_FOR_TWD_ROLLOUT="${DEMO_RUNNER_WAIT_FOR_TWD_ROLLOUT:-false}"

if [[ -f skaffold.env ]]; then
  set -a
  source skaffold.env
  set +a
fi

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
DEMO_RUNNER_IMAGE_REPO="${DEMO_RUNNER_IMAGE_REPO:-${ECR_BASE}/${DEMO_RUNNER_REPO_NAME}}"
DEMO_RUNNER_AWS_ROLE_ARN="${DEMO_RUNNER_AWS_ROLE_ARN:-arn:aws:iam::${ACCOUNT_ID}:role/rainbow-version-generator-role}"
DEMO_RUNNER_REPO_URL="${DEMO_RUNNER_REPO_URL:-$(git config --get remote.origin.url 2>/dev/null || true)}"
DEMO_RUNNER_REPO_REF="${DEMO_RUNNER_REPO_REF:-$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo main)}"
TEMPORAL_API_KEY_SECRET_NAME="${TEMPORAL_API_KEY_SECRET_NAME:-temporal-api-key}"
TEMPORAL_API_KEY_SECRET_KEY="${TEMPORAL_API_KEY_SECRET_KEY:-api-key}"

if [[ "$DEMO_RUNNER_REPO_URL" == git@github.com:* ]]; then
  DEMO_RUNNER_REPO_URL="https://github.com/${DEMO_RUNNER_REPO_URL#git@github.com:}"
fi

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

for repo in temporal-worker-controller helloworld rainbow-dashboard-api rainbow-dashboard-ui "$DEMO_RUNNER_REPO_NAME"; do
  "${AWS_CMD[@]}" ecr describe-repositories --repository-names "$repo" >/dev/null 2>&1 || \
    "${AWS_CMD[@]}" ecr create-repository --repository-name "$repo" >/dev/null
  echo "ECR repo ready: $repo"
done

"${AWS_CMD[@]}" ecr get-login-password --region "$REGION" | \
  docker login --username AWS --password-stdin "$ECR_BASE"

# Build the controller as a multi-platform manifest list (linux/amd64 + linux/arm64) using
# docker buildx directly. Skaffold's own multi-platform merge path has a known issue with
# ECR that results in a broken manifest list, so we bypass it here.
CONTROLLER_IMAGE="$ECR_BASE/temporal-worker-controller:latest"
echo "Building multi-platform controller image (linux/amd64,linux/arm64) → $CONTROLLER_IMAGE"
docker buildx build \
  --platform linux/amd64,linux/arm64 \
  -t "$CONTROLLER_IMAGE" \
  -f Dockerfile \
  --push \
  .

# Deploy the Helm chart using the pre-built multi-arch image.
CONTROLLER_ARTIFACTS=$(mktemp /tmp/skaffold-controller-XXXXXX.json)
printf '{"builds":[{"imageName":"temporal-worker-controller","tag":"%s"}]}\n' \
  "$CONTROLLER_IMAGE" > "$CONTROLLER_ARTIFACTS"

echo "Deploying controller Helm chart via skaffold deploy (pre-built image)"
SKAFFOLD_DEFAULT_REPO="$ECR_BASE" skaffold deploy \
  --profile worker-controller \
  --build-artifacts "$CONTROLLER_ARTIFACTS"

rm -f "$CONTROLLER_ARTIFACTS"

echo "Deploying demo worker via skaffold profile helloworld-worker"
SKAFFOLD_DEFAULT_REPO="$ECR_BASE" skaffold run \
  --cache-artifacts=false \
  --platform "$TARGET_PLATFORM" \
  --profile "helloworld-worker,${SKAFFOLD_ARCH_PROFILE}"

echo "Building and pushing dashboard API image"
docker buildx build --platform "$TARGET_PLATFORM" -t "$ECR_BASE/rainbow-dashboard-api:latest" -f internal/demo/Dockerfile.dashboard . --push

echo "Building and pushing dashboard UI image"
docker buildx build --platform "$TARGET_PLATFORM" \
  --build-arg VITE_API_BASE_URL="" \
  -t "$ECR_BASE/rainbow-dashboard-ui:latest" \
  internal/demo/dashboard --push

DEMO_RUNNER_TAG="demo-loop-$(date +%Y%m%d%H%M%S)"
DEMO_RUNNER_IMAGE="${DEMO_RUNNER_IMAGE_REPO}:${DEMO_RUNNER_TAG}"

echo "Building and pushing unified demo runner image"
docker buildx build --platform "$TARGET_PLATFORM" -t "$DEMO_RUNNER_IMAGE" -f internal/demo/Dockerfile.release-job . --push

echo "Applying dashboard manifests"
kubectl apply -f internal/demo/k8s/dashboard-deployment.yaml
kubectl -n "$DASHBOARD_NAMESPACE" rollout restart deployment/rainbow-dashboard-api deployment/rainbow-dashboard-ui

echo "Suspending legacy demo triggers"
kubectl -n "$DEMO_NAMESPACE" patch cronjob traffic-generator --type merge -p '{"spec":{"suspend":true}}' >/dev/null 2>&1 || true
kubectl -n "$DEMO_NAMESPACE" patch cronjob rainbow-version-generator --type merge -p '{"spec":{"suspend":true}}' >/dev/null 2>&1 || true
kubectl -n "$DEMO_NAMESPACE" scale deployment rainbow-release-manager --replicas=0 >/dev/null 2>&1 || true

if command -v temporal >/dev/null 2>&1 && [[ -n "${TEMPORAL_ADDRESS:-}" ]] && [[ -n "${TEMPORAL_NAMESPACE:-}" ]]; then
  TEMPORAL_API_KEY_VALUE="$(kubectl -n "$DEMO_NAMESPACE" get secret "$TEMPORAL_API_KEY_SECRET_NAME" -o "jsonpath={.data.${TEMPORAL_API_KEY_SECRET_KEY}}" 2>/dev/null | base64 --decode || true)"
  if [[ -n "$TEMPORAL_API_KEY_VALUE" ]]; then
    temporal schedule toggle \
      --schedule-id rainbow-release-schedule \
      --pause \
      --reason "Unified demo runner active" \
      --address "$TEMPORAL_ADDRESS" \
      --namespace "$TEMPORAL_NAMESPACE" \
      --api-key "$TEMPORAL_API_KEY_VALUE" >/dev/null 2>&1 || true
  fi
fi

escape_sed() {
  printf '%s' "$1" | sed -e 's/[\/&]/\\&/g'
}

echo "Applying unified demo runner deployment"
sed \
  -e "s|__NAMESPACE__|$(escape_sed "$DEMO_NAMESPACE")|g" \
  -e "s|__AWS_ROLE_ARN__|$(escape_sed "$DEMO_RUNNER_AWS_ROLE_ARN")|g" \
  -e "s|__RUNNER_IMAGE__|$(escape_sed "$DEMO_RUNNER_IMAGE")|g" \
  -e "s|__RELEASE_NAME__|$(escape_sed "$DEMO_RELEASE_NAME")|g" \
  -e "s|__REPO_URL__|$(escape_sed "$DEMO_RUNNER_REPO_URL")|g" \
  -e "s|__REPO_REF__|$(escape_sed "$DEMO_RUNNER_REPO_REF")|g" \
  -e "s|__WORKER__|$(escape_sed "$DEMO_RELEASE_NAME")|g" \
  -e "s|__STATE_CONFIGMAP__|rainbow-version-state|g" \
  -e "s|__AWS_REGION__|$(escape_sed "$REGION")|g" \
  -e "s|__WAIT_FOR_TWD_ROLLOUT__|$(escape_sed "$DEMO_RUNNER_WAIT_FOR_TWD_ROLLOUT")|g" \
  -e "s|__LOOP_INTERVAL_SECONDS__|$(escape_sed "$DEMO_RUNNER_LOOP_INTERVAL_SECONDS")|g" \
  -e "s|__TEMPORAL_ADDRESS__|$(escape_sed "$TEMPORAL_ADDRESS")|g" \
  -e "s|__TEMPORAL_NAMESPACE__|$(escape_sed "$TEMPORAL_NAMESPACE")|g" \
  -e "s|__TEMPORAL_TASK_QUEUE__|$(escape_sed "${DEMO_NAMESPACE}/${DEMO_RELEASE_NAME}")|g" \
  -e "s|__WORKFLOWS_PER_RUN__|$(escape_sed "$DEMO_RUNNER_WORKFLOWS_PER_RUN")|g" \
  -e "s|__MAX_NEW_WORKFLOWS_PER_RUN__|$(escape_sed "$DEMO_RUNNER_MAX_NEW_WORKFLOWS_PER_RUN")|g" \
  -e "s|__MAX_RUNNING_WORKFLOWS__|$(escape_sed "$DEMO_RUNNER_MAX_RUNNING_WORKFLOWS")|g" \
  -e "s|__TEMPORAL_API_KEY_SECRET_NAME__|$(escape_sed "$TEMPORAL_API_KEY_SECRET_NAME")|g" \
  -e "s|__TEMPORAL_API_KEY_SECRET_KEY__|$(escape_sed "$TEMPORAL_API_KEY_SECRET_KEY")|g" \
  internal/demo/k8s/demo-loop-runner.yaml | kubectl apply -f -

kubectl -n "$DEMO_NAMESPACE" rollout status deployment/rainbow-demo-runner --timeout=180s

if [[ "$EXPOSE_PUBLIC" == "true" ]]; then
  kubectl -n "$DASHBOARD_NAMESPACE" patch svc rainbow-dashboard-ui -p '{"spec":{"type":"LoadBalancer"}}'
  echo "Dashboard UI service set to LoadBalancer."
  echo "Get external endpoint with: kubectl -n $DASHBOARD_NAMESPACE get svc rainbow-dashboard-ui"
else
  echo "Dashboard services left as ClusterIP."
  echo "UI:  kubectl -n $DASHBOARD_NAMESPACE port-forward svc/rainbow-dashboard-ui 8080:80"
  echo "API: kubectl -n $DASHBOARD_NAMESPACE port-forward svc/rainbow-dashboard-api 8787:8787"
fi

echo "Done."
