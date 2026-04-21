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
sed -i.bak 's/WorkflowExecutionTimeout: time.Minute,/WorkflowExecutionTimeout: 12 * time.Minute,/' internal/demo/helloworld/worker.go
rm -f internal/demo/helloworld/worker.go.bak

echo "optional: stop the load generator with: pkill -f 'make apply-load-sample-workflow'"

if [ "$HARD_RESET" = "1" ]; then
	echo "performing hard reset: deleting existing ${RELEASE_NAME} rollout resources"
	helm uninstall "$RELEASE_NAME" -n "$NAMESPACE" >/dev/null 2>&1 || true
	kubectl -n "$NAMESPACE" delete temporalworkerdeployment "$RELEASE_NAME" --ignore-not-found >/dev/null 2>&1 || true
	kubectl -n "$NAMESPACE" wait --for=delete "temporalworkerdeployment/${RELEASE_NAME}" --timeout=120s >/dev/null 2>&1 || true
fi

echo "redeploying baseline worker"
skaffold run --profile helloworld-worker

echo "reset complete"
