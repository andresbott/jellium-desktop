#!/bin/sh
# Build a .deb into dist/. Links system libmpv, bundles CEF.
# Must run on a Debian/Ubuntu host (needs dpkg-shlibdeps + apt-mapped libs).
# Env:
#   DEB_ARCH  -- Debian arch (defaults to `dpkg --print-architecture`).
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../../.." && pwd)"
cd "$PROJECT_ROOT"

DEB_ARCH="${DEB_ARCH:-$(dpkg --print-architecture)}"
VERSION="$(cargo run --quiet --manifest-path src/xtask/Cargo.toml -- version)"

STAGE="$PROJECT_ROOT/build/deb/staging"
PREFIX="$STAGE/opt/jellium-desktop"
rm -rf "$STAGE"
mkdir -p "$PREFIX" "$PROJECT_ROOT/dist"

# 1. Install CEF's runtime-lib providers FIRST. libcef.so's indirect deps
#    (nss/nspr/atk/cups/atspi/Xcomposite/Xdamage/...) must be resolvable BOTH
#    when cargo links the binary against libcef AND later for dpkg-shlibdeps.
#    Try the base name, then the t64 variant (Ubuntu 24.04+/Debian 13 time_t
#    transition). A soname with no provider is skipped by --ignore-missing-info.
CEF_LIBS="libnss3 libnspr4 libatk1.0-0 libatk-bridge2.0-0 libcups2 libdrm2 \
libgbm1 libxcomposite1 libxdamage1 libxfixes3 libxrandr2 libxkbcommon0 \
libasound2 libpango-1.0-0 libpangocairo-1.0-0 libcairo2 libatspi2.0-0 \
libx11-6 libxcb1 libxext6 libxi6 libglib2.0-0 libexpat1 libgtk-3-0 \
libxrender1 libxtst6"
if command -v apt-get >/dev/null 2>&1; then
    for p in $CEF_LIBS; do
        apt-get install -y --no-install-recommends "$p" >/dev/null 2>&1 \
          || apt-get install -y --no-install-recommends "${p}t64" >/dev/null 2>&1 \
          || echo "warn: no provider for $p / ${p}t64" >&2
    done
fi

# 2. Build + stage binary and CEF payload into /opt/jellium-desktop (no libmpv).
cargo run --quiet --manifest-path src/xtask/Cargo.toml -- \
    install --system-mpv --prefix "$PREFIX"

# Optional SwiftShader Vulkan ICD (best effort; not copied by xtask install).
for icd in "$PROJECT_ROOT"/.cache/cef/*/vk_swiftshader_icd.json; do
    [ -f "$icd" ] && cp "$icd" "$PREFIX/" || true
    break
done

# Reduce size (release CEF libs are usually pre-stripped; ignore failures).
strip "$PREFIX/jellium-desktop" 2>/dev/null || true
find "$PREFIX" -name '*.so' -exec strip {} + 2>/dev/null || true

# 3. Compute Depends via dpkg-shlibdeps. -l marks our private lib dir so
#    bundled CEF sonames resolve locally (not as external deps); analysing
#    the binary + bundled .so pulls in libmpv, libavcodec, and CEF's system
#    deps under their distro-correct package names.
WORK="$(mktemp -d)"
mkdir -p "$WORK/debian"
printf 'Source: jellium-desktop\n\nPackage: jellium-desktop\nArchitecture: any\n' \
    > "$WORK/debian/control"
RAW_DEPENDS="$(cd "$WORK" && dpkg-shlibdeps -O --ignore-missing-info \
    -l"$PREFIX" \
    "$PREFIX/jellium-desktop" \
    "$PREFIX"/lib*.so 2>/dev/null | sed -n 's/^shlibs:Depends=//p')"
rm -rf "$WORK"

if [ -z "$RAW_DEPENDS" ]; then
    echo "error: dpkg-shlibdeps produced no dependencies" >&2
    exit 1
fi

# 4. Turn "a (>= x), b, c" into a YAML flow array: [ "a (>= x)", "b", "c" ]
DEPENDS='['
first=1
oldifs="$IFS"; IFS=','
for dep in $RAW_DEPENDS; do
    dep="$(printf '%s' "$dep" | sed 's/^ *//; s/ *$//')"
    [ -z "$dep" ] && continue
    if [ "$first" -eq 1 ]; then first=0; else DEPENDS="$DEPENDS,"; fi
    DEPENDS="$DEPENDS \"$dep\""
done
IFS="$oldifs"
DEPENDS="$DEPENDS ]"

# 5. Render nfpm.yaml and package.
export DEB_ARCH VERSION DEPENDS
envsubst '${DEB_ARCH} ${VERSION} ${DEPENDS}' \
    < "$SCRIPT_DIR/nfpm.yaml.in" > "$PROJECT_ROOT/build/deb/nfpm.yaml"

nfpm package --packager deb \
    --config "$PROJECT_ROOT/build/deb/nfpm.yaml" \
    --target "$PROJECT_ROOT/dist/"

echo "Built: $(ls -1 "$PROJECT_ROOT"/dist/*.deb)"
