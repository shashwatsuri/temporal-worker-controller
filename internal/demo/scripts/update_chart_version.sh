#!/bin/sh
set -e

# Update Chart.yaml appVersion to match the deployed image tag
# Used as a Skaffold pre-deploy hook to keep Helm chart version in sync

CHART="internal/demo/helloworld/helm/helloworld/Chart.yaml"

if [ ! -f "$CHART" ]; then
    echo "[update_chart_version] Chart not found at $CHART, skipping"
    exit 0
fi

if [ $# -gt 0 ]; then
    # Use tag from command line argument if provided
    sed -i.bak "s/^appVersion: .*/appVersion: \"$1\"/" "$CHART" && rm -f "${CHART}.bak"
else
    GIT_SHA=$(git rev-parse --short HEAD 2>/dev/null || echo "unknown")
    sed -i.bak "s/^appVersion: .*/appVersion: \"${GIT_SHA}\"/" "$CHART" && rm -f "${CHART}.bak"
fi
