#!/bin/sh
# Cleans up drained versions from Temporal Cloud that have zero running workflows.
# Deletes any non-current version with 0 active workflows, keeping versions that
# still have pinned workflows running on them.
#
# Environment:
#   NAMESPACE              Kubernetes namespace (default: from pod metadata)
#   RELEASE_NAME           TemporalWorkerDeployment name (default: helloworld)
#   TEMPORAL_ADDRESS       Temporal Cloud gRPC address
#   TEMPORAL_NAMESPACE     Temporal Cloud namespace
#   TEMPORAL_API_KEY       Temporal API key
#   WORKER_DEPLOYMENT_NAME Temporal Worker Deployment name (e.g., default/helloworld)
#   MANAGER_IDENTITY       Identity for Temporal operations

set -eu

NAMESPACE="${NAMESPACE:-default}"
RELEASE_NAME="${RELEASE_NAME:-helloworld}"
WORKER_DEPLOYMENT_NAME="${WORKER_DEPLOYMENT_NAME:-default/${RELEASE_NAME}}"
MANAGER_IDENTITY="${MANAGER_IDENTITY:-temporal-worker-controller/temporal-system}"
TIMESTAMP=$(date -u +'%Y-%m-%dT%H:%M:%SZ')

echo "[$TIMESTAMP] Starting cleanup for TWD: ${NAMESPACE}/${RELEASE_NAME}"

# Check required env vars
if [ -z "${TEMPORAL_ADDRESS:-}" ] || [ -z "${TEMPORAL_NAMESPACE:-}" ] || [ -z "${TEMPORAL_API_KEY:-}" ]; then
  echo "[$TIMESTAMP] ERROR: TEMPORAL_ADDRESS, TEMPORAL_NAMESPACE, and TEMPORAL_API_KEY are required"
  exit 1
fi

# Describe the deployment once and cache the result
DESCRIBE_JSON=$(temporal worker deployment describe \
  -d "$WORKER_DEPLOYMENT_NAME" \
  --address "$TEMPORAL_ADDRESS" \
  -n "$TEMPORAL_NAMESPACE" \
  --api-key "$TEMPORAL_API_KEY" \
  --tls \
  -o json 2>/dev/null || echo "{}")

ALL_VERSIONS=$(echo "$DESCRIBE_JSON" | jq -r '.versionSummaries[].BuildID // empty' || true)

if [ -z "$ALL_VERSIONS" ]; then
  echo "[$TIMESTAMP] No versions found on Temporal"
  exit 0
fi

VERSION_COUNT=$(echo "$ALL_VERSIONS" | wc -l | tr -d ' ')

# Get the current version (can't be deleted)
CURRENT_BUILD_ID=$(echo "$DESCRIBE_JSON" | jq -r '.routingConfig.currentVersionBuildID // ""' || true)

echo "[$TIMESTAMP] Found $VERSION_COUNT versions, current: ${CURRENT_BUILD_ID:-(none)}"

DELETED=0
SKIPPED=0
FAILED=0
HAS_WORKFLOWS=0

for BUILD_ID in $ALL_VERSIONS; do
  # Never delete current version
  if [ "$BUILD_ID" = "$CURRENT_BUILD_ID" ]; then
    SKIPPED=$((SKIPPED + 1))
    continue
  fi

  # Check if this version has any running workflows
  VERSION_KEY="${WORKER_DEPLOYMENT_NAME}:${BUILD_ID}"
  QUERY="ExecutionStatus='Running' AND TemporalWorkerDeploymentVersion='${VERSION_KEY}'"

  RUNNING_COUNT=$(temporal workflow count \
    --query "$QUERY" \
    --address "$TEMPORAL_ADDRESS" \
    -n "$TEMPORAL_NAMESPACE" \
    --api-key "$TEMPORAL_API_KEY" \
    --tls 2>/dev/null | grep -oE '[0-9]+' || echo "0")

  # First, delete the K8s Deployment so pollers disconnect
  K8S_DEPLOY="${RELEASE_NAME}-${BUILD_ID}"
  if kubectl get deployment "$K8S_DEPLOY" -n "$NAMESPACE" >/dev/null 2>&1; then
    if [ "$RUNNING_COUNT" -gt 0 ] 2>/dev/null; then
      echo "[$TIMESTAMP] Keeping $BUILD_ID (has K8s deployment and $RUNNING_COUNT running workflows)"
      HAS_WORKFLOWS=$((HAS_WORKFLOWS + 1))
    else
      echo "[$TIMESTAMP] Deleting K8s deployment $K8S_DEPLOY (will delete version next cycle)"
      kubectl delete deployment "$K8S_DEPLOY" -n "$NAMESPACE" --ignore-not-found >/dev/null 2>&1
      FAILED=$((FAILED + 1))
    fi
    continue
  fi

  # No K8s deployment — no workers to process these workflows.
  # Terminate any orphaned pinned workflows before deleting the version.
  if [ "$RUNNING_COUNT" -gt 0 ] 2>/dev/null; then
    echo "[$TIMESTAMP] Terminating $RUNNING_COUNT orphaned workflows on $BUILD_ID (no K8s deployment)"
    temporal workflow terminate \
      --query "$QUERY" \
      --reason "Version $BUILD_ID has no active workers" \
      --address "$TEMPORAL_ADDRESS" \
      -n "$TEMPORAL_NAMESPACE" \
      --api-key "$TEMPORAL_API_KEY" \
      --tls \
      --yes 2>&1 || true
    # Wait for batch to take effect before attempting version delete next cycle
    FAILED=$((FAILED + 1))
    continue
  fi

  # No K8s deployment, no running workflows — attempt Temporal version delete
  echo "[$TIMESTAMP] Deleting version $BUILD_ID from Temporal (0 running workflows)"
  if temporal worker deployment delete-version \
    --deployment-name "$WORKER_DEPLOYMENT_NAME" \
    --build-id "$BUILD_ID" \
    --skip-drainage \
    --identity "$MANAGER_IDENTITY" \
    --address "$TEMPORAL_ADDRESS" \
    -n "$TEMPORAL_NAMESPACE" \
    --api-key "$TEMPORAL_API_KEY" \
    --tls 2>&1; then
    DELETED=$((DELETED + 1))
  else
    FAILED=$((FAILED + 1))
  fi
done

echo "[$TIMESTAMP] Temporal cleanup: deleted=$DELETED skipped=$SKIPPED has_workflows=$HAS_WORKFLOWS failed=$FAILED"

echo "[$TIMESTAMP] Cleanup complete"
