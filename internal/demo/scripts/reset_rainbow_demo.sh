#!/bin/sh
set -eu

ROOT_DIR="$(git rev-parse --show-toplevel)"
cd "$ROOT_DIR"

NAMESPACE="${NAMESPACE:-default}"
RELEASE_NAME="${RELEASE_NAME:-helloworld}"
HARD_RESET="${HARD_RESET:-1}"

echo "reset_rainbow_demo: NAMESPACE=${NAMESPACE} RELEASE_NAME=${RELEASE_NAME} HARD_RESET=${HARD_RESET}"

echo "restoring internal/demo/helloworld/worker.go"
git restore --worktree --staged internal/demo/helloworld/worker.go 2>/dev/null || git checkout -- internal/demo/helloworld/worker.go

echo "ensuring RolloutGate timeout is long enough for demo workflow runtime"
sed -E -i.bak 's/util\.SetActivityTimeout\(ctx, *([0-9]+\*)?time\.Minute\)/util.SetActivityTimeout(ctx, 12*time.Minute)/' internal/demo/helloworld/worker.go
sed -E -i.bak 's/WorkflowExecutionTimeout: *([0-9]+\*)?time\.Minute/WorkflowExecutionTimeout: 12*time.Minute/' internal/demo/helloworld/worker.go
rm -f internal/demo/helloworld/worker.go.bak

echo "optional: stop the load generator with: pkill -f 'make apply-load-sample-workflow'"

if [ "$HARD_RESET" = "1" ]; then
	echo "performing hard reset: deleting existing ${RELEASE_NAME} rollout resources"
	helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" >/dev/null 2>&1 || true
	kubectl -n "$NAMESPACE" delete temporalworkerdeployment "$RELEASE_NAME" --ignore-not-found >/dev/null 2>&1 || true
	kubectl -n "$NAMESPACE" wait --for=delete "temporalworkerdeployment/${RELEASE_NAME}" --timeout=120s >/dev/null 2>&1 || true
fi

echo "redeploying baseline worker"

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
	echo "EKS context detected; using derived ECR repo: $DEPLOY_REPO"
fi

if [ -n "$DEPLOY_REPO" ] && echo "$DEPLOY_REPO" | grep -q "dkr.ecr"; then
	# EKS deployment: build multi-platform image manually
	COMMIT_SHA=$(git rev-parse HEAD)
	IMAGE_TAG="${DEPLOY_REPO}/helloworld:${COMMIT_SHA}"
  
	echo "Building multi-platform image for EKS: $IMAGE_TAG"
	docker buildx build \
		--platform linux/amd64,linux/arm64 \
		--build-arg WORKER=helloworld \
		--build-arg DD_GIT_COMMIT_SHA="$COMMIT_SHA" \
		--build-arg DD_GIT_REPOSITORY_URL="github.com/temporalio/temporal-worker-controller" \
		--tag "$IMAGE_TAG" \
		--push \
		-f internal/demo/Dockerfile \
		internal/demo/
  
	echo "Deploying with skaffold (no build)"
	ARTIFACTS_FILE=$(mktemp)
	echo "{\"builds\":[{\"imageName\":\"helloworld\",\"tag\":\"$IMAGE_TAG\"}]}" > "$ARTIFACTS_FILE"
	SKAFFOLD_DEFAULT_REPO="$DEPLOY_REPO" \
	skaffold deploy --profile helloworld-worker \
		--build-artifacts "$ARTIFACTS_FILE"
	rm -f "$ARTIFACTS_FILE"
else
	# Local deployment (Minikube): use skaffold run normally
	skaffold run --profile helloworld-worker
fi

echo "reset complete"
