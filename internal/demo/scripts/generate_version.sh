#!/bin/sh
# Generates a single dynamic worker version by modifying worker.go and deploying.
# Usage: sh generate_version.sh [version_number]
#   version_number - optional; auto-increments if not provided
#
# Environment:
#   SKIP_DEPLOY=1    modify and commit but skip skaffold run
set -eu

ROOT_DIR="$(git rev-parse --show-toplevel)"
cd "$ROOT_DIR"

WORKER_FILE="internal/demo/helloworld/worker.go"
SKIP_DEPLOY="${SKIP_DEPLOY:-0}"

# Determine version number
if [ -n "${1:-}" ]; then
  VERSION="$1"
else
  # Count existing demo version commits on this branch to auto-increment
  EXISTING=$(git log --oneline -- "$WORKER_FILE" | grep -c "Rainbow demo v" || true)
  VERSION=$((EXISTING + 1))
fi

TIMESTAMP=$(date '+%H:%M:%S')
echo "[$TIMESTAMP] Generating version $VERSION"

# Find the upstream baseline commit — the last commit that is NOT a "Rainbow demo" commit.
# This is used as a stable restore point so each version always starts from the same base.
BASE_COMMIT=$(git log --oneline -- "$WORKER_FILE" | grep -v "^[a-f0-9]* Rainbow demo v" | head -1 | awk '{print $1}')
if [ -z "$BASE_COMMIT" ]; then
  echo "[$TIMESTAMP] ERROR: Could not find baseline commit (non-Rainbow-demo commit) for $WORKER_FILE"
  exit 1
fi
echo "[$TIMESTAMP] Restoring baseline from commit $BASE_COMMIT"
git show "${BASE_COMMIT}:${WORKER_FILE}" > "$WORKER_FILE"

# --- Compute values that change per version ---
# Keep sleep bounded so gate workflows (which execute HelloWorld) can complete
# before the next version is generated.
# 30s-60s sleep + up to 30s activity latency => <=90s per gate workflow.
SLEEP_SECS=$(( 30 + (VERSION * 5) % 31 ))

# Build the new worker.go with this version's changes using awk.
# Always rewrites from the restored baseline, so patterns are stable.
awk -v ver="$VERSION" -v sleep_secs="$SLEEP_SECS" '
/\/\/ Return the greeting/ {
  print ""
  print "\t// Non-replay-safe change introduced by Rainbow demo v" ver
  print "\tif err := workflow.Sleep(ctx, " sleep_secs "*time.Second); err != nil {"
  print "\t\treturn \"\", err"
  print "\t}"
  print ""
}
/return fmt.Sprintf\(/ && /subject\), nil/ {
  print "\treturn fmt.Sprintf(\"Hello %s (rainbow demo v" ver ", sleep=" sleep_secs "s)\", subject), nil"
  next
}
{ print }
' "$WORKER_FILE" > "${WORKER_FILE}.tmp"

mv "${WORKER_FILE}.tmp" "$WORKER_FILE"

# Baseline commits may still have a short gate timeout; enforce a longer timeout
# so rollout test workflows can complete before promotion is evaluated.
sed -i.bak 's/WorkflowExecutionTimeout: time.Minute,/WorkflowExecutionTimeout: 12 * time.Minute,/' "$WORKER_FILE"
rm -f "${WORKER_FILE}.bak"

# Verify the change was applied
if ! grep -q "rainbow demo v$VERSION" "$WORKER_FILE"; then
  echo "[$TIMESTAMP] ERROR: Failed to modify worker.go - pattern not found"
  git restore "$WORKER_FILE"
  exit 1
fi

if ! grep -q "WorkflowExecutionTimeout: 12 \* time.Minute" "$WORKER_FILE"; then
  echo "[$TIMESTAMP] ERROR: Failed to enforce RolloutGate timeout"
  git restore "$WORKER_FILE"
  exit 1
fi

echo "[$TIMESTAMP] worker.go updated: sleep=${SLEEP_SECS}s, greeting=v$VERSION"

# Commit so each version gets a new git SHA (which Skaffold uses as image tag)
git add "$WORKER_FILE"
git commit -m "Rainbow demo v${VERSION}: sleep=${SLEEP_SECS}s" --allow-empty >/dev/null 2>&1 || true

echo "[$TIMESTAMP] Committed version $VERSION"

if [ "$SKIP_DEPLOY" = "1" ]; then
  echo "[$TIMESTAMP] SKIP_DEPLOY=1 set - skipping skaffold run"
  exit 0
fi

echo "[$TIMESTAMP] Deploying..."
skaffold run --profile helloworld-worker

echo "[$TIMESTAMP] Version $VERSION deployed"
