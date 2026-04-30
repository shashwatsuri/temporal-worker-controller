#!/bin/sh
set -eu

TIMESTAMP=$(date '+%H:%M:%S')

echo "[$TIMESTAMP] Starting rainbow release run"

WORK_DIR=$(mktemp -d)
cleanup() {
  rm -rf "$WORK_DIR"
}
trap cleanup EXIT INT TERM

git clone --depth 1 --branch "$REPO_REF" "$REPO_URL" "$WORK_DIR/repo"
cd "$WORK_DIR/repo"

IMAGE_TAG=$(ROOT_DIR="$WORK_DIR/repo" /opt/release-scripts/generate_version_cron.sh | tail -n 1)
if [ -z "$IMAGE_TAG" ]; then
  echo "[$TIMESTAMP] ERROR: generate_version_cron.sh did not produce an image tag"
  exit 1
fi

export DD_GIT_COMMIT_SHA
DD_GIT_COMMIT_SHA=$(git rev-parse HEAD)
export DD_GIT_REPOSITORY_URL="$REPO_URL"

/opt/release-scripts/build_version_kaniko.sh "$IMAGE_TAG" "$REPO_URL" "$DD_GIT_COMMIT_SHA"
/opt/release-scripts/deploy_version_skaffold.sh "$IMAGE_TAG" "$NAMESPACE" "$RELEASE_NAME"

# Capture the build ID of the newly-deployed target version so the traffic step
# can pin workflows to it. The controller derives the build ID from the image tag plus
# a hash of the pod template spec (e.g. "<sha>-<4chars>") so we must read it from the
# TWD status rather than reconstruct it. Wait up to 30s for the controller to reconcile
# and register the new targetVersion before reading.
DEPLOYED_BUILD_ID=""
for _attempt in $(seq 1 6); do
  _candidate=$(kubectl get temporalworkerdeployment "$RELEASE_NAME" -n "$NAMESPACE" \
    -o jsonpath='{.status.targetVersion.buildID}' 2>/dev/null || true)
  # Accept only if it contains the expected image SHA (everything after the last ':')
  _expected_sha=$(echo "$IMAGE_TAG" | rev | cut -d: -f1 | rev)
  if echo "$_candidate" | grep -qF "$_expected_sha"; then
    DEPLOYED_BUILD_ID="$_candidate"
    break
  fi
  echo "[$TIMESTAMP] Waiting for controller to register new targetVersion (attempt ${_attempt}/6)..."
  sleep 5
done

if [ -n "$DEPLOYED_BUILD_ID" ]; then
  printf '%s' "$DEPLOYED_BUILD_ID" > /tmp/last-deployed-build-id
  echo "[$TIMESTAMP] Captured build ID for traffic pinning: $DEPLOYED_BUILD_ID"
else
  rm -f /tmp/last-deployed-build-id
  echo "[$TIMESTAMP] WARNING: could not read targetVersion.buildID containing SHA $IMAGE_TAG; traffic will not be pinned"
fi

echo "[$TIMESTAMP] Rainbow release run complete: $IMAGE_TAG"