#!/bin/sh
set -eu

if [ "$#" -ne 1 ]; then
  echo "usage: $0 <patch-file>"
  echo "example: $0 internal/demo/helloworld/changes/add-timer-and-email-greeting.patch"
  exit 2
fi

PATCH_FILE="$1"

if [ ! -f "$PATCH_FILE" ]; then
  echo "patch file not found: $PATCH_FILE"
  exit 2
fi

ROOT_DIR="$(git rev-parse --show-toplevel)"
cd "$ROOT_DIR"

# Start load if it is not already running.
if ! pgrep -f "make apply-load-sample-workflow" >/dev/null 2>&1; then
  echo "starting load generator: make apply-load-sample-workflow"
  nohup make apply-load-sample-workflow >/tmp/twc-rainbow-load.log 2>&1 &
fi

echo "applying patch: $PATCH_FILE"
git apply "$PATCH_FILE"

echo "deploying updated worker"
skaffold run --profile helloworld-worker

echo "done"
