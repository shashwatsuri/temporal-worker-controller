#!/bin/sh
# Continuously generates and deploys new worker versions on a timer.
# Each version introduces a different timer/greeting, creating a live rainbow deployment demo.
#
# Usage: sh continuous_versions.sh
#
# Environment:
#   DELAY_SECONDS=90    seconds to wait after deploying before generating the next version
#   MAX_VERSIONS=0      stop after this many versions (0 = run forever)
#   SKIP_DEPLOY=0       if 1, generate and commit but don't deploy (for testing)
#   START_VERSION=1     starting version number
set -eu

ROOT_DIR="$(git rev-parse --show-toplevel)"
cd "$ROOT_DIR"

# Progressive rollout uses 3x30s pauses, and gate workflows may take 150-240s.
# Intentionally use a shorter default so multiple pinned versions overlap.
DELAY_SECONDS="${DELAY_SECONDS:-60}"
MAX_VERSIONS="${MAX_VERSIONS:-0}"
SKIP_DEPLOY="${SKIP_DEPLOY:-0}"
START_VERSION="${START_VERSION:-1}"

echo "[$(date '+%H:%M:%S')] Starting continuous version generation"
echo "[$(date '+%H:%M:%S')] DELAY_SECONDS=${DELAY_SECONDS} MAX_VERSIONS=${MAX_VERSIONS} START_VERSION=${START_VERSION}"
if [ "$SKIP_DEPLOY" = "1" ]; then
  echo "[$(date '+%H:%M:%S')] SKIP_DEPLOY=1: will commit but not deploy"
fi

if [ "$SKIP_DEPLOY" != "1" ] && [ "$DELAY_SECONDS" -lt 45 ]; then
  echo "[$(date '+%H:%M:%S')] ERROR: DELAY_SECONDS=${DELAY_SECONDS} is too low for overlap mode"
  echo "[$(date '+%H:%M:%S')] Use DELAY_SECONDS>=45 to avoid excessive rollout churn"
  exit 1
fi

echo ""

VERSION="$START_VERSION"

while true; do
  echo "[$(date '+%H:%M:%S')] ==============================================="
  echo "[$(date '+%H:%M:%S')] === Generating version $VERSION ==="
  echo "[$(date '+%H:%M:%S')] ==============================================="

  SKIP_DEPLOY="$SKIP_DEPLOY" sh internal/demo/scripts/generate_version.sh "$VERSION"

  if [ "$MAX_VERSIONS" -gt 0 ] && [ "$VERSION" -ge "$((START_VERSION + MAX_VERSIONS - 1))" ]; then
    echo "[$(date '+%H:%M:%S')] Reached MAX_VERSIONS=$MAX_VERSIONS, stopping."
    exit 0
  fi

  VERSION=$((VERSION + 1))
  echo "[$(date '+%H:%M:%S')] Waiting ${DELAY_SECONDS}s before next version... (Ctrl-C to stop)"
  sleep "$DELAY_SECONDS"
done
