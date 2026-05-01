#!/bin/sh
# Builds a helloworld worker image by launching a Kaniko Kubernetes Job.
# The demo runner pod (Alpine) creates the Job via kubectl and waits for it.
# Kaniko runs as PID 1 in its own container — not as a subprocess — avoiding
# the filesystem-clobbering issue that occurs when running it inline in Alpine.
#
# Usage: sh build_version_kaniko.sh IMAGE_TAG GIT_REPO_URL GIT_COMMIT_SHA
#   IMAGE_TAG       Full ECR image tag (e.g., 025066239481.dkr.ecr.us-east-2.amazonaws.com/helloworld:SHA)
#   GIT_REPO_URL    Git repo URL (e.g., https://github.com/org/repo)
#   GIT_COMMIT_SHA  Git commit SHA that has the mutated worker.go baked in
#
# Environment:
#   NAMESPACE       Kubernetes namespace (default: default)
#   WORKER          Worker name for build args (default: helloworld)
#   AWS_REGION      AWS region for ECR (auto-detected from image URI)
#   BUILD_TIMEOUT   Seconds to wait for Job completion (default: 900)

set -eu

TIMESTAMP=$(date '+%H:%M:%S')

IMAGE_TAG="${1:-}"
GIT_REPO_URL="${2:-}"
GIT_COMMIT_SHA="${3:-}"
NAMESPACE="${NAMESPACE:-default}"
WORKER="${WORKER:-helloworld}"
BUILD_TIMEOUT="${BUILD_TIMEOUT:-900}"

if [ -z "$IMAGE_TAG" ] || [ -z "$GIT_REPO_URL" ] || [ -z "$GIT_COMMIT_SHA" ]; then
  echo "[$TIMESTAMP] ERROR: Usage: build_version_kaniko.sh IMAGE_TAG GIT_REPO_URL GIT_COMMIT_SHA"
  exit 1
fi

echo "[$TIMESTAMP] Building $IMAGE_TAG from $GIT_REPO_URL@$GIT_COMMIT_SHA"

# Extract AWS region from ECR URI
AWS_REGION=$(echo "$IMAGE_TAG" | sed -n 's#.*\.ecr\.\([a-z0-9-]*\)\.amazonaws\.com.*#\1#p')
AWS_REGION="${AWS_REGION:-us-east-2}"
ECR_REGISTRY=$(echo "$IMAGE_TAG" | cut -d/ -f1)

# Get ECR auth token to pass to Kaniko via a K8s Secret
echo "[$TIMESTAMP] Getting ECR login token..."
ECR_TOKEN=$(aws ecr get-authorization-token \
  --region "$AWS_REGION" \
  --output text \
  --query 'authorizationData[0].authorizationToken' 2>/dev/null || true)
if [ -z "$ECR_TOKEN" ]; then
  echo "[$TIMESTAMP] ERROR: Failed to obtain ECR login token - check IRSA permissions"
  exit 1
fi

# Build docker config JSON for Kaniko's /kaniko/.docker/config.json
DOCKER_CONFIG_JSON=$(printf '{"auths":{"%s":{"auth":"%s"}}}' "$ECR_REGISTRY" "$ECR_TOKEN")

# Unique names based on short SHA
SHORT_SHA=$(echo "$GIT_COMMIT_SHA" | cut -c1-8)
JOB_NAME="kaniko-build-${SHORT_SHA}"
SECRET_NAME="kaniko-ecr-${SHORT_SHA}"

# Clean up any previous run with the same SHA
kubectl delete job "$JOB_NAME" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
kubectl delete secret "$SECRET_NAME" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true

echo "[$TIMESTAMP] Creating ECR credentials secret: $SECRET_NAME"
kubectl create secret generic "$SECRET_NAME" \
  --namespace="$NAMESPACE" \
  --from-literal=config.json="$DOCKER_CONFIG_JSON"

# Detect native node architecture so we build the right binary
NODE_ARCH=$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}' 2>/dev/null || echo "amd64")
echo "[$TIMESTAMP] Cluster node architecture: $NODE_ARCH"

# Use Kaniko's git:// context — it clones the repo at the exact SHA so that
# --context-sub-path resolves correctly (GitHub tarballs unpack as <repo>-<sha>/
# which breaks sub-path resolution).
CONTEXT_URL="git://${GIT_REPO_URL#https://}#${GIT_COMMIT_SHA}"
echo "[$TIMESTAMP] Kaniko context: $CONTEXT_URL"

echo "[$TIMESTAMP] Creating Kaniko Job: $JOB_NAME"
kubectl apply -f - <<EOF
apiVersion: batch/v1
kind: Job
metadata:
  name: ${JOB_NAME}
  namespace: ${NAMESPACE}
  labels:
    app: kaniko-build
    version-sha: ${SHORT_SHA}
spec:
  ttlSecondsAfterFinished: 600
  backoffLimit: 0
  template:
    metadata:
      annotations:
        karpenter.sh/do-not-disrupt: "true"
    spec:
      serviceAccountName: rainbow-demo-runner
      restartPolicy: Never
      containers:
        - name: kaniko
          image: gcr.io/kaniko-project/executor:latest
          args:
            - "--context=${CONTEXT_URL}"
            - "--context-sub-path=internal/demo"
            - "--dockerfile=Dockerfile"
            - "--destination=${IMAGE_TAG}"
            - "--snapshot-mode=redo"
            - "--compressed-caching=false"
            - "--custom-platform=linux/${NODE_ARCH}"
            - "--build-arg=WORKER=${WORKER}"
            - "--build-arg=GOARCH=${NODE_ARCH}"
            - "--build-arg=DD_GIT_COMMIT_SHA=${GIT_COMMIT_SHA}"
            - "--verbosity=info"
          volumeMounts:
            - name: docker-config
              mountPath: /kaniko/.docker
          resources:
            requests:
              cpu: 500m
              memory: 1Gi
            limits:
              cpu: 2000m
              memory: 3Gi
      volumes:
        - name: docker-config
          secret:
            secretName: ${SECRET_NAME}
            items:
              - key: config.json
                path: config.json
EOF

echo "[$TIMESTAMP] Waiting up to ${BUILD_TIMEOUT}s for Job $JOB_NAME..."
if ! kubectl wait job/"$JOB_NAME" \
    --namespace="$NAMESPACE" \
    --for=condition=complete \
    --timeout="${BUILD_TIMEOUT}s" 2>/dev/null; then
  echo "[$TIMESTAMP] ERROR: Kaniko Job failed or timed out - fetching logs"
  kubectl logs -n "$NAMESPACE" "job/$JOB_NAME" --tail=100 2>/dev/null || true
  kubectl delete job "$JOB_NAME" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
  kubectl delete secret "$SECRET_NAME" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true
  exit 1
fi

echo "[$TIMESTAMP] Build succeeded. Log tail:"
kubectl logs -n "$NAMESPACE" "job/$JOB_NAME" --tail=10 2>/dev/null || true

kubectl delete secret "$SECRET_NAME" -n "$NAMESPACE" --ignore-not-found 2>/dev/null || true

echo "[$TIMESTAMP] Build complete: $IMAGE_TAG"
