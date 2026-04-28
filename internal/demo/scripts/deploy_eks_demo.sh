#!/usr/bin/env bash
set -euo pipefail

# Deploys controller + helloworld + dashboard to the active EKS context.
# Optional env vars:
#   AWS_PROFILE=<profile>
#   DASHBOARD_NAMESPACE=<namespace> (default: default)
#   DASHBOARD_NAME=<worker name> (default: helloworld)
#   EXPOSE_PUBLIC=true|false (default: false)

DASHBOARD_NAMESPACE="${DASHBOARD_NAMESPACE:-default}"
DASHBOARD_NAME="${DASHBOARD_NAME:-helloworld}"
EXPOSE_PUBLIC="${EXPOSE_PUBLIC:-false}"

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
SKAFFOLD_DEFAULT_REPO="$ECR_BASE" skaffold run --profile worker-controller

echo "Deploying demo worker via skaffold profile helloworld-worker"
SKAFFOLD_DEFAULT_REPO="$ECR_BASE" skaffold run --profile helloworld-worker

echo "Building and pushing dashboard image"
docker build -t "$ECR_BASE/rainbow-dashboard:latest" -f internal/demo/Dockerfile.dashboard .
docker push "$ECR_BASE/rainbow-dashboard:latest"

echo "Applying dashboard manifests"
kubectl apply -f internal/demo/k8s/dashboard-deployment.yaml
kubectl -n "$DASHBOARD_NAMESPACE" set image deployment/rainbow-dashboard \
  dashboard="$ECR_BASE/rainbow-dashboard:latest"
kubectl -n "$DASHBOARD_NAMESPACE" patch deployment rainbow-dashboard --type strategic -p \
  '{"spec":{"template":{"spec":{"containers":[{"name":"dashboard","imagePullPolicy":"Always"}]}}}}'
kubectl -n "$DASHBOARD_NAMESPACE" set env deployment/rainbow-dashboard \
  NAMESPACE="$DASHBOARD_NAMESPACE"
kubectl -n "$DASHBOARD_NAMESPACE" patch deployment rainbow-dashboard --type merge -p \
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
