#!/bin/sh
set -eu

LOOP_INTERVAL_SECONDS="${LOOP_INTERVAL_SECONDS:-180}"
CONTINUE_ON_RELEASE_FAILURE="${CONTINUE_ON_RELEASE_FAILURE:-1}"
CONTINUE_ON_TRAFFIC_FAILURE="${CONTINUE_ON_TRAFFIC_FAILURE:-1}"
CYCLE=0

sleep_until_next_boundary() {
  now=$(date +%s)
  remainder=$((now % LOOP_INTERVAL_SECONDS))
  if [ "$remainder" -eq 0 ]; then
    sleep_for="$LOOP_INTERVAL_SECONDS"
  else
    sleep_for=$((LOOP_INTERVAL_SECONDS - remainder))
  fi

  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Sleeping ${sleep_for}s until next demo cycle"
  sleep "$sleep_for"
}

while true; do
  CYCLE=$((CYCLE + 1))
  echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Starting demo cycle ${CYCLE}"

  if /opt/release-scripts/run_release_once.sh; then
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Release step succeeded for cycle ${CYCLE}"
  else
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Release step failed for cycle ${CYCLE}"
    if [ "$CONTINUE_ON_RELEASE_FAILURE" != "1" ]; then
      exit 1
    fi
    sleep_until_next_boundary
    continue
  fi

  # Pass the build ID written by run_release_once.sh so workflows are pinned to the
  # version that was just deployed.
  if [ -f /tmp/last-deployed-build-id ]; then
    export PINNED_BUILD_ID
    PINNED_BUILD_ID=$(cat /tmp/last-deployed-build-id)
  else
    unset PINNED_BUILD_ID 2>/dev/null || true
  fi

  if /opt/release-scripts/generate-traffic.sh; then
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Traffic step succeeded for cycle ${CYCLE}"
  else
    echo "[$(date -u +'%Y-%m-%dT%H:%M:%SZ')] Traffic step failed for cycle ${CYCLE}"
    if [ "$CONTINUE_ON_TRAFFIC_FAILURE" != "1" ]; then
      exit 1
    fi
  fi

  sleep_until_next_boundary
done