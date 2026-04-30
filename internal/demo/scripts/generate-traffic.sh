#!/bin/sh
set -eu

# Configuration
NAMESPACE="${NAMESPACE:-default}"
TASK_QUEUE="${TEMPORAL_TASK_QUEUE:-${TASK_QUEUE:-default/helloworld}}"
WORKFLOWS_PER_RUN="${WORKFLOWS_PER_RUN:-3}"
TEMPORAL_ADDRESS="${TEMPORAL_ADDRESS:-temporal:7233}"
TEMPORAL_NAMESPACE="${TEMPORAL_NAMESPACE:-default}"
WORKFLOW_TYPE="${WORKFLOW_TYPE:-HelloWorld}"
TEMPORAL_WORKER_DEPLOYMENT="${TEMPORAL_WORKER_DEPLOYMENT:-${NAMESPACE}/helloworld}"
MAX_RUNNING_WORKFLOWS="${MAX_RUNNING_WORKFLOWS:-10}"
MAX_NEW_WORKFLOWS_PER_RUN="${MAX_NEW_WORKFLOWS_PER_RUN:-5}"

TIMESTAMP=$(date '+%s')
HOSTNAME=$(hostname)

parse_temporal_count() {
  output="$1"

  if printf '%s\n' "$output" | grep -Eq '^[[:space:]]*Total:[[:space:]]*[0-9]+[[:space:]]*$'; then
    printf '%s\n' "$output" | sed -E 's/^[[:space:]]*Total:[[:space:]]*([0-9]+)[[:space:]]*$/\1/'
    return 0
  fi

  if printf '%s\n' "$output" | grep -Eq '^[[:space:]]*[0-9]+[[:space:]]*$'; then
    printf '%s\n' "$output" | tr -d '[:space:]'
    return 0
  fi

  if printf '%s\n' "$output" | jq -er '(.count // .total) | numbers' >/dev/null 2>&1; then
    printf '%s\n' "$output" | jq -r '.count // .total'
    return 0
  fi

  return 1
}

count_running_workflows() {
  query="ExecutionStatus=\"Running\" AND WorkflowType=\"${WORKFLOW_TYPE}\""
  if [ -n "$TEMPORAL_WORKER_DEPLOYMENT" ]; then
    query="$query AND TemporalWorkerDeployment=\"${TEMPORAL_WORKER_DEPLOYMENT}\""
  fi

  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Counting running ${WORKFLOW_TYPE} workflows with query: $query" >&2
  output=$(temporal workflow count \
    --query "$query" \
    --address "$TEMPORAL_ADDRESS" \
    --namespace "$TEMPORAL_NAMESPACE" \
    2>&1) || {
      echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] ERROR: temporal workflow count failed: $output" >&2
      return 1
    }

  count=$(parse_temporal_count "$output") || {
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] ERROR: could not parse workflow count output: $output" >&2
    return 1
  }

  printf '%s\n' "$count"
}

running_workflows=$(count_running_workflows)
remaining_capacity=$((MAX_RUNNING_WORKFLOWS - running_workflows))
launch_target="$WORKFLOWS_PER_RUN"

if [ "$launch_target" -gt "$MAX_NEW_WORKFLOWS_PER_RUN" ]; then
  launch_target="$MAX_NEW_WORKFLOWS_PER_RUN"
fi

if [ "$remaining_capacity" -lt "$launch_target" ]; then
  launch_target="$remaining_capacity"
fi

if [ "$launch_target" -le 0 ]; then
  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Skipping traffic generation: running=${running_workflows}, max=${MAX_RUNNING_WORKFLOWS}"
  exit 0
fi

echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Starting traffic generation: launch=${launch_target}, running=${running_workflows}, max=${MAX_RUNNING_WORKFLOWS}, taskQueue=${TASK_QUEUE}"
echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Temporal server: $TEMPORAL_ADDRESS, namespace: $TEMPORAL_NAMESPACE"

# Generate workflows
SUCCESS_COUNT=0
FAIL_COUNT=0

for i in $(seq 1 "$launch_target"); do
  # Create idempotent workflow ID: timestamp-hostname-sequence
  WORKFLOW_ID="traffic-${TIMESTAMP}-${HOSTNAME}-${i}"
  
  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Starting workflow $i/$launch_target: $WORKFLOW_ID"
  
  # Start workflow using temporal CLI
  # Workflow type should be what helloworld worker is listening for
  # shellcheck disable=SC2086
  if temporal workflow start \
    --address "$TEMPORAL_ADDRESS" \
    --namespace "$TEMPORAL_NAMESPACE" \
    --task-queue "$TASK_QUEUE" \
    --type "$WORKFLOW_TYPE" \
    --workflow-id "$WORKFLOW_ID" \
    --input '{"name":"traffic-generated"}' \
    2>&1; then
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] ✓ Started workflow: $WORKFLOW_ID"
    SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
  else
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] ✗ Failed to start workflow: $WORKFLOW_ID (may be retried on next run)"
    FAIL_COUNT=$((FAIL_COUNT + 1))
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
