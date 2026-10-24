#!/bin/sh
# Build .AppImage in dist/. Runs the container-based build via :base image.
# Source / cargo / meson state persists in build/appimage/ on the host.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
IMG="jellium-desktop-appimage:base"
VERSION="$(cargo run --quiet --manifest-path "${PROJECT_ROOT}/src/xtask/Cargo.toml" -- version)"

if command -v podman >/dev/null 2>&1; then
    cmd=podman
elif command -v docker >/dev/null 2>&1; then
    cmd=docker
else
    echo 'error: podman or docker required' >&2
    exit 1
fi

if [ ! -d "${PROJECT_ROOT}/build/appimage" ]; then
    # Fresh build dir → clean image rebuild (pull latest base, no layer cache)
    "$cmd" build --pull=always --no-cache \
        -t "$IMG" -f "${SCRIPT_DIR}/Dockerfile" "$PROJECT_ROOT"
fi

# Rootful docker runs the container as host root, so everything it writes to
# the bind mounts below (src/target, build/, dist/) would be root-owned and
# need sudo to clean. Run as the invoking user instead; cargo needs a writable
# HOME. Rootless podman/docker already map container root to that user.
RUN_AS=""
if [ "$cmd" = docker ] && ! docker info --format '{{.SecurityOptions}}' 2>/dev/null | grep -q rootless; then
    RUN_AS="--user $(id -u):$(id -g) -e HOME=/tmp"
fi

mkdir -p "${PROJECT_ROOT}/build/appimage/build" "${PROJECT_ROOT}/dist"

# shellcheck disable=SC2086
"$cmd" run --rm $RUN_AS \
    -v "${PROJECT_ROOT}:/src" \
    -v "${PROJECT_ROOT}/build/appimage/build:/build" \
    -v "${PROJECT_ROOT}/dist:/host-output" \
    -e VERSION="$VERSION" \
    "$IMG" /src/dev/linux/appimage/container-build.sh

ARCH="$(uname -m)"
BUNDLE="dist/JelliumDesktop-${VERSION}-${ARCH}.AppImage"
LINK="${PROJECT_ROOT}/build/appimage/JelliumDesktop.AppImage"
ln -sf "../../${BUNDLE}" "$LINK"
echo "AppImage: ${BUNDLE} (-> ${LINK})"
