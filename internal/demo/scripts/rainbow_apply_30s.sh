#!/bin/sh
set -eu

ROOT_DIR="$(git rev-parse --show-toplevel)"
cd "$ROOT_DIR"

STEP_DELAY_SECONDS="${STEP_DELAY_SECONDS:-40}"
SKIP_DEPLOY="${SKIP_DEPLOY:-0}"
STRICT_PATCH_SEQUENCE="${STRICT_PATCH_SEQUENCE:-1}"

echo "[$(date '+%H:%M:%S')] Starting rainbow_apply_30s"
echo "[$(date '+%H:%M:%S')] STEP_DELAY_SECONDS=${STEP_DELAY_SECONDS}"
echo "[$(date '+%H:%M:%S')] SKIP_DEPLOY=${SKIP_DEPLOY}"
echo "[$(date '+%H:%M:%S')] STRICT_PATCH_SEQUENCE=${STRICT_PATCH_SEQUENCE}"

if [ "$SKIP_DEPLOY" != "0" ] && [ "$SKIP_DEPLOY" != "1" ]; then
  echo "[$(date '+%H:%M:%S')] Invalid SKIP_DEPLOY value: ${SKIP_DEPLOY} (expected 0 or 1)"
  exit 1
fi

if [ "$STRICT_PATCH_SEQUENCE" != "0" ] && [ "$STRICT_PATCH_SEQUENCE" != "1" ]; then
  echo "[$(date '+%H:%M:%S')] Invalid STRICT_PATCH_SEQUENCE value: ${STRICT_PATCH_SEQUENCE} (expected 0 or 1)"
  exit 1
fi

apply_patch_if_needed() {
  patch_file="$1"

  if git apply --check "$patch_file" >/dev/null 2>&1; then
    echo "[$(date '+%H:%M:%S')] Applying patch: $patch_file"
    git apply "$patch_file"
    return 0
  fi

  if git apply --reverse --check "$patch_file" >/dev/null 2>&1; then
    echo "[$(date '+%H:%M:%S')] Patch already applied, skipping: $patch_file"
    return 2
  fi

  echo "[$(date '+%H:%M:%S')] Patch cannot be applied in current state: $patch_file"
  echo "[$(date '+%H:%M:%S')] Tip: run internal/demo/scripts/reset_rainbow_demo.sh first"
  return 1
}

apply_and_deploy() {
  patch_file="$1"
  apply_result=0
  if apply_patch_if_needed "$patch_file"; then
    apply_result=0
  else
    apply_result=$?
  fi

  if [ "$apply_result" -eq 2 ]; then
    if [ "$STRICT_PATCH_SEQUENCE" = "1" ]; then
      echo "[$(date '+%H:%M:%S')] Strict mode is enabled and patch was already applied."
      echo "[$(date '+%H:%M:%S')] Run internal/demo/scripts/reset_rainbow_demo.sh, then rerun this script."
      exit 1
    fi

    echo "[$(date '+%H:%M:%S')] No code change for this step; skipping deploy"
    return 0
  fi

  if [ "$apply_result" -ne 0 ]; then
    echo "[$(date '+%H:%M:%S')] Stopping because patch step failed: $patch_file"
    exit "$apply_result"
  fi

  if [ "$SKIP_DEPLOY" = "1" ]; then
    echo "[$(date '+%H:%M:%S')] SKIP_DEPLOY=1 set, skipping skaffold run"
  else
    echo "[$(date '+%H:%M:%S')] Deploying with skaffold profile helloworld-worker"
    skaffold run --profile helloworld-worker
  fi
}

apply_and_deploy "internal/demo/helloworld/changes/add-timer-and-email-greeting.patch"

echo "[$(date '+%H:%M:%S')] Waiting ${STEP_DELAY_SECONDS}s before next patch"
sleep "$STEP_DELAY_SECONDS"
apply_and_deploy "internal/demo/helloworld/changes/increase-timer-v2.patch"

echo "[$(date '+%H:%M:%S')] Waiting ${STEP_DELAY_SECONDS}s before next patch"
sleep "$STEP_DELAY_SECONDS"
apply_and_deploy "internal/demo/helloworld/changes/add-second-timer-v3.patch"

echo "[$(date '+%H:%M:%S')] Rainbow sequence complete"
