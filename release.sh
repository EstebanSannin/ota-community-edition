#!/usr/bin/env bash
# Build and push all five OTA CE images as multi-arch images:
#   ota-lith, ota-ce-provisioner, ota-ce-lockbox, ota-ce-ops, ras
# Everything else in the stack is stock nginx/mariadb/caddy/minio plus mounted config.
#
# Prerequisites:
#   - docker with buildx
#   - you are logged in to the target registry:  docker login        (Docker Hub)
#                                                 docker login ghcr.io (GitHub, etc.)
#   - for linux/arm64 on an amd64 host, QEMU handlers registered in the kernel:
#       docker run --privileged --rm tonistiigi/binfmt --install all
#   - JDK 21 + sbt to stage ota-lith - or nothing, and it stages in a container instead
#
# Usage:
#   NS=<namespace> TAG=0.2.0 ./release.sh          # e.g. NS=samnite
#   NS=ghcr.io/you TAG=0.2.0 ./release.sh          # any registry prefix works
#   PLATFORMS=linux/amd64 NS=... ./release.sh      # single arch, much faster
#
# The ota-lith jar is architecture-independent, so multi-arch is cheap (buildx just
# pairs the same jars with the per-arch JRE base image). `ras` is the slow one: it is
# Rust, compiled per-arch inside the Dockerfile, so arm64 builds under emulation.
set -euo pipefail
cd "$(dirname "$0")"

NS="${NS:?set NS to your image namespace, e.g. NS=youruser (Docker Hub) or NS=ghcr.io/youruser}"
TAG="${TAG:-latest}"
PLATFORMS="${PLATFORMS:-linux/amd64,linux/arm64}"
LITH="$NS/ota-lith"
PROV="$NS/ota-ce-provisioner"
RAS="$NS/ras"
LOCKBOX="$NS/ota-ce-lockbox"
OPS="$NS/ota-ce-ops"

echo "== namespace: $NS   tag: $TAG   platforms: $PLATFORMS"

echo "== ensuring a buildx builder"
docker buildx inspect ota-ce-builder >/dev/null 2>&1 || docker buildx create --name ota-ce-builder >/dev/null
docker buildx use ota-ce-builder

# Building for a foreign architecture needs QEMU handlers registered with the kernel. Docker
# Desktop ships them; a plain Linux host usually does not, and the build fails with "exec format
# error". Install them with:  docker run --privileged --rm tonistiigi/binfmt --install all
case "$PLATFORMS" in
  *arm64*)
    if [ "$(uname -m)" != "aarch64" ] && [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
      echo "!! PLATFORMS includes linux/arm64 but no qemu-aarch64 binfmt handler is registered."
      echo "!! Register it (one privileged container, affects the host kernel):"
      echo "!!   docker run --privileged --rm tonistiigi/binfmt --install all"
      echo "!! Or build a single architecture:  PLATFORMS=linux/amd64 $0"
      exit 1
    fi
    ;;
esac

# ota-lith needs a JDK+sbt to stage its jars. If neither is on this host, stage it inside a
# container (same image the docs use) so the release still works from a toolchain-free machine.
echo "== staging ota-lith with sbt (generates target/docker/stage/Dockerfile + jars)"
if command -v sbt >/dev/null 2>&1; then
  sbt "Docker / stage"
else
  echo "   (no local sbt - staging in a container)"
  docker run --rm -v "$PWD:/src" -w /src \
    -v ota-sbt-cache:/root/.cache -v ota-sbt-ivy:/root/.ivy2 -v ota-sbt-sbt:/root/.sbt \
    -e SBT_OPTS="-Xmx3g -Xss4m" \
    sbtscala/scala-sbt:eclipse-temurin-jammy-21.0.2_13_1.9.9_3.4.1 \
    sbt -batch "Docker / stage"
fi

echo "== building + pushing $LITH ($TAG, latest)"
docker buildx build --platform "$PLATFORMS" \
  -t "$LITH:$TAG" -t "$LITH:latest" \
  --push target/docker/stage

echo "== building + pushing $PROV ($TAG, latest)"
docker buildx build --platform "$PLATFORMS" \
  -t "$PROV:$TAG" -t "$PROV:latest" \
  --push provisioner

# The two stdlib-only Python sidecars: python:3.12-slim + COPY, so multi-arch is nearly free.
echo "== building + pushing $LOCKBOX ($TAG, latest)"
docker buildx build --platform "$PLATFORMS" \
  -t "$LOCKBOX:$TAG" -t "$LOCKBOX:latest" \
  --push lockbox

echo "== building + pushing $OPS ($TAG, latest)"
docker buildx build --platform "$PLATFORMS" \
  -t "$OPS:$TAG" -t "$OPS:latest" \
  --push ops

# The ras binary is compiled per-arch inside the Dockerfile, so the non-native arch builds
# under QEMU emulation and can be slow. Set PLATFORMS=linux/amd64 (or your target only) to
# speed it up, or RAS=skip to skip it.
if [ "${RAS:-}" != "skip" ]; then
  echo "== building + pushing $RAS ($TAG, latest)  [Rust multi-arch — may be slow under emulation]"
  docker buildx build --platform "$PLATFORMS" \
    -t "$RAS:$TAG" -t "$RAS:latest" \
    --push remote-access/ras
fi

cat <<EOF

  ✔ Pushed:
      $LITH:$TAG      (and :latest)
      $PROV:$TAG      (and :latest)
      $LOCKBOX:$TAG   (and :latest)
      $OPS:$TAG       (and :latest)
      $RAS:$TAG       (and :latest)

  Run the release stack elsewhere with:
      export OTA_CE_NS=$NS OTA_CE_TAG=$TAG
      ./bootstrap.sh          # (uses compose.release.yaml when OTA_CE_NS is set)
EOF
