#!/usr/bin/env bash
# Build and push the OTA CE images (ota-lith + provisioner) as multi-arch images.
#
# Prerequisites:
#   - docker with buildx
#   - you are logged in to the target registry:  docker login        (Docker Hub)
#                                                 docker login ghcr.io (GitHub, etc.)
#   - JDK 21 + sbt (to stage the ota-lith build)
#
# Usage:
#   NS=<namespace> TAG=0.1.0 ./release.sh          # e.g. NS=estebansannin
#   NS=ghcr.io/you TAG=0.1.0 ./release.sh          # any registry prefix works
#
# The ota-lith jar is architecture-independent, so multi-arch is cheap (buildx just
# pairs the same jars with the per-arch JRE base image).
set -euo pipefail
cd "$(dirname "$0")"

NS="${NS:?set NS to your image namespace, e.g. NS=youruser (Docker Hub) or NS=ghcr.io/youruser}"
TAG="${TAG:-latest}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"
LITH="$NS/ota-lith"
PROV="$NS/ota-ce-provisioner"

echo "== namespace: $NS   tag: $TAG   platforms: $PLATFORMS"

echo "== ensuring a buildx builder"
docker buildx inspect ota-ce-builder >/dev/null 2>&1 || docker buildx create --name ota-ce-builder >/dev/null
docker buildx use ota-ce-builder

echo "== staging ota-lith with sbt (generates target/docker/stage/Dockerfile + jars)"
sbt "Docker / stage"

echo "== building + pushing $LITH ($TAG, latest)"
docker buildx build --platform "$PLATFORMS" \
  -t "$LITH:$TAG" -t "$LITH:latest" \
  --push target/docker/stage

echo "== building + pushing $PROV ($TAG, latest)"
docker buildx build --platform "$PLATFORMS" \
  -t "$PROV:$TAG" -t "$PROV:latest" \
  --push provisioner

cat <<EOF

  ✔ Pushed:
      $LITH:$TAG   (and :latest)
      $PROV:$TAG   (and :latest)

  Run the release stack elsewhere with:
      export OTA_CE_NS=$NS OTA_CE_TAG=$TAG
      ./bootstrap.sh          # (uses compose.release.yaml when OTA_CE_NS is set)
EOF
