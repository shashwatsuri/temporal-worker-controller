#!/bin/sh
# Simplified release: retag an existing ECR image with a new random tag and patch the TWD.
# No git clone, no build, no Skaffold. Just a new tag triggers the controller's rollout.
set -eu

TIMESTAMP=$(date '+%H:%M:%S')
NAMESPACE="${NAMESPACE:-default}"
RELEASE_NAME="${RELEASE_NAME:-helloworld}"
AWS_REGION="${AWS_REGION:-us-east-2}"
ECR_REPO="${ECR_REPO:-025066239481.dkr.ecr.us-east-2.amazonaws.com/helloworld}"
SOURCE_TAG="${SOURCE_TAG:-latest}"

echo "[$TIMESTAMP] Starting rainbow release"

# 1. Generate a random 6-character hex tag
NEW_TAG=$(head -c 3 /dev/urandom | od -An -tx1 | tr -d ' \n')
echo "[$TIMESTAMP] Generated new version tag: $NEW_TAG"

# 2. Retag the existing image in ECR (copy manifest to new tag)
ECR_REGISTRY=$(echo "$ECR_REPO" | cut -d/ -f1)
REPO_NAME=$(echo "$ECR_REPO" | cut -d/ -f2-)

echo "[$TIMESTAMP] Copying $ECR_REPO:$SOURCE_TAG -> $ECR_REPO:$NEW_TAG"

MANIFEST=$(aws ecr batch-get-image \
  --region "$AWS_REGION" \
  --repository-name "$REPO_NAME" \
  --image-ids imageTag="$SOURCE_TAG" \
  --query 'images[0].imageManifest' \
  --output text)

if [ -z "$MANIFEST" ] || [ "$MANIFEST" = "None" ]; then
  echo "[$TIMESTAMP] ERROR: Could not fetch manifest for $ECR_REPO:$SOURCE_TAG"
  exit 1
fi

aws ecr put-image \
  --region "$AWS_REGION" \
  --repository-name "$REPO_NAME" \
  --image-tag "$NEW_TAG" \
  --image-manifest "$MANIFEST" \
  >/dev/null 2>&1 || true  # Ignore "already exists" errors

echo "[$TIMESTAMP] Image tagged successfully: $ECR_REPO:$NEW_TAG"

# 3. Patch the TWD to use the new image tag
IMAGE_REF="$ECR_REPO:$NEW_TAG"
echo "[$TIMESTAMP] Patching TWD $RELEASE_NAME with image: $IMAGE_REF"

kubectl patch temporalworkerdeployment "$RELEASE_NAME" -n "$NAMESPACE" \
  --type='json' \
  -p="[{\"op\":\"replace\",\"path\":\"/spec/template/spec/containers/0/image\",\"value\":\"$IMAGE_REF\"}]"

echo "[$TIMESTAMP] Release complete: $IMAGE_REF"