#!/bin/sh
# Switch rainbow version releases from Kubernetes CronJob to Temporal Schedule.
#
# This script deploys the release manager worker and job image, then suspends
# the legacy CronJob trigger to avoid double-firing version releases.

set -eu

ROOT_DIR="$(git rev-parse --show-toplevel)"
cd "$ROOT_DIR"

TIMESTAMP="$(date '+%H:%M:%S')"
PROFILE="${PROFILE:-rainbow-release}"
NAMESPACE="${NAMESPACE:-default}"
CRONJOB_NAME="${CRONJOB_NAME:-rainbow-version-generator}"

echo "[$TIMESTAMP] Deploying Temporal schedule release manager (profile=$PROFILE)"
skaffold deploy --profile "$PROFILE"

if kubectl -n "$NAMESPACE" get cronjob "$CRONJOB_NAME" >/dev/null 2>&1; then
  echo "[$TIMESTAMP] Suspending legacy CronJob $NAMESPACE/$CRONJOB_NAME"
  kubectl -n "$NAMESPACE" patch cronjob "$CRONJOB_NAME" --type merge -p '{"spec":{"suspend":true}}'
else
  echo "[$TIMESTAMP] Legacy CronJob $NAMESPACE/$CRONJOB_NAME not found; nothing to suspend"
fi

echo "[$TIMESTAMP] Temporal schedule release trigger is active"
echo "[$TIMESTAMP] Check manager pod: kubectl -n $NAMESPACE get pods -l app.kubernetes.io/name=release-manager"
echo "[$TIMESTAMP] Check schedule workers: temporal schedule list --namespace ${TEMPORAL_NAMESPACE:-<your-temporal-namespace>}"