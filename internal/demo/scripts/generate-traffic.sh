#!/bin/bash
set -euo pipefail

# Configuration
NAMESPACE="${NAMESPACE:-default}"
TASK_QUEUE="${TASK_QUEUE:-default/helloworld}"
WORKFLOWS_PER_RUN="${WORKFLOWS_PER_RUN:-3}"
TEMPORAL_ADDRESS="${TEMPORAL_ADDRESS:-temporal:7233}"
TEMPORAL_NAMESPACE="${TEMPORAL_NAMESPACE:-default}"

TIMESTAMP=$(date '+%s')
HOSTNAME=$(hostname)

echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Starting traffic generation: $WORKFLOWS_PER_RUN workflows to $TASK_QUEUE"
echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Temporal server: $TEMPORAL_ADDRESS, namespace: $TEMPORAL_NAMESPACE"

# Generate workflows
SUCCESS_COUNT=0
FAIL_COUNT=0

for i in $(seq 1 "$WORKFLOWS_PER_RUN"); do
  # Create idempotent workflow ID: timestamp-hostname-sequence
  WORKFLOW_ID="traffic-${TIMESTAMP}-${HOSTNAME}-${i}"
  
  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Starting workflow $i/$WORKFLOWS_PER_RUN: $WORKFLOW_ID"
  
  # Start workflow using temporal CLI
  # Workflow type should be what helloworld worker is listening for
  if temporal workflow start \
    --address "$TEMPORAL_ADDRESS" \
    --namespace "$TEMPORAL_NAMESPACE" \
    --task-queue "$TASK_QUEUE" \
    --type Helloworld \
    --workflow-id "$WORKFLOW_ID" \
    --input '{"name":"traffic-generated"}' \
    2>&1; then
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] ✓ Started workflow: $WORKFLOW_ID"
    ((SUCCESS_COUNT++))
  else
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] ✗ Failed to start workflow: $WORKFLOW_ID (may be retried on next run)"
    ((FAIL_COUNT++))
  fi
  
  # Small delay between starts
  sleep 0.5
done

echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Traffic generation complete: $SUCCESS_COUNT succeeded, $FAIL_COUNT failed"

# Exit with failure if all workflows failed
if [ "$SUCCESS_COUNT" -eq 0 ]; then
  exit 1
fi

exit 0
