#!/bin/sh
# Jellium Desktop - Debian/Ubuntu dependency installer
# Run once (make deps) to install all build dependencies. Asks before running
# apt-get, and fetches libplacebo when the system one is too old for mpv.
set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

if ! command -v apt-get > /dev/null || ! command -v dpkg-query > /dev/null; then
    echo "error: apt-get not found; this installer supports Debian and Ubuntu only" >&2
    exit 1
fi

# Toolchain: meson + ninja build mpv, bindgen needs libclang.
TOOLS="
build-essential
ca-certificates
clang
git
libclang-dev
meson
ninja-build
pkg-config
python3
"

# mpv (third_party/mpv/meson.build) requires FFmpeg and libass. The rest turn
# on the features release builds ship: Wayland/X11/EGL/DRM output, Vulkan
# (shaderc compiles libplacebo's shaders), VA-API and NVDEC, PipeWire/Pulse/ALSA
# audio, Lua, ICC profiles, rubberband, uchardet and zimg.
MPV="
libavcodec-dev
libavdevice-dev
libavfilter-dev
libavformat-dev
libavutil-dev
libswresample-dev
libswscale-dev
libass-dev
libwayland-dev
wayland-protocols
libxkbcommon-dev
libx11-dev
libxext-dev
libxfixes-dev
libxpresent-dev
libxrandr-dev
libxss-dev
libegl-dev
libgbm-dev
libdrm-dev
libdisplay-info-dev
libvulkan-dev
libshaderc-dev
libva-dev
libffmpeg-nvenc-dev
libpipewire-0.3-dev
libpulse-dev
libasound2-dev
libluajit-5.1-dev
liblcms2-dev
librubberband-dev
libuchardet-dev
libzimg-dev
"

# jellium-desktop crates: the .deb CI build's list, minus what mpv needs anyway.
APP="
libxkbcommon-x11-dev
libxcb1-dev
"

# CEF: the libraries libcef.so links against (readelf -d libcef.so). The linker
# resolves them when it links jellium-desktop, so they are needed to build too.
CEF="
libasound2t64
libatk-bridge2.0-0t64
libatk1.0-0t64
libatspi2.0-0t64
libcairo2
libcups2t64
libdbus-1-3
libexpat1
libgbm1
libglib2.0-0t64
libnspr4
libnss3
libpango-1.0-0
libudev1
libx11-6
libxcb1
libxcomposite1
libxdamage1
libxext6
libxfixes3
libxkbcommon0
libxrandr2
"

echo "Checking installed packages..."
INSTALLED="$(dpkg-query -W -f '${Status} ${Package}\n' | awk '$3 == "installed" { print $4 }')"
MISSING=""
for pkg in ${TOOLS} ${MPV} ${APP} ${CEF}; do
    if ! printf '%s\n' "${INSTALLED}" | grep -qx "${pkg}"; then
        MISSING="${MISSING} ${pkg}"
    fi
done

if [ -n "${MISSING}" ]; then
    echo "Missing packages:${MISSING}"
    if [ "$(id -u)" -eq 0 ]; then SUDO=""; else SUDO="sudo"; fi
    if [ ! -t 0 ]; then
        echo "Non-interactive shell; cannot prompt. Install them with:" >&2
        echo "  ${SUDO:+${SUDO} }apt-get install${MISSING}" >&2
        exit 1
    fi
    printf 'Install them now with apt-get? [y/N] '
    read -r ans || ans=""
    case "${ans}" in
        [yY]|[yY][eE][sS]) ;;
        *) echo "Aborted. Install the packages and re-run 'make deps'."; exit 1 ;;
    esac
    ${SUDO} apt-get update
    # shellcheck disable=SC2086
    ${SUDO} apt-get install -y ${MISSING}
fi

# mpv needs a newer libplacebo than Debian/Ubuntu ship. Meson then builds the
# checkout in mpv's subprojects/ and links it statically.
MPV_DIR="${PROJECT_ROOT}/third_party/mpv"
if ! [ -e "${MPV_DIR}/.git" ]; then
    git -C "${PROJECT_ROOT}" submodule update --init --recursive
fi
PLACEBO_MIN="$(sed -n "s/^libplacebo = dependency('libplacebo', version: '>= *\([0-9.]*\)'.*/\1/p" "${MPV_DIR}/meson.build")"
if [ -z "${PLACEBO_MIN}" ]; then
    echo "error: no libplacebo version found in third_party/mpv/meson.build" >&2
    exit 1
fi
if [ -d "${MPV_DIR}/subprojects/libplacebo" ]; then
    echo "libplacebo: using third_party/mpv/subprojects/libplacebo"
elif pkg-config --atleast-version="${PLACEBO_MIN}" libplacebo; then
    echo "libplacebo: using system $(pkg-config --modversion libplacebo)"
else
    echo "Fetching libplacebo v${PLACEBO_MIN} (the system one is older)..."
    git clone --depth 1 --branch "v${PLACEBO_MIN}" --recurse-submodules --shallow-submodules \
        https://github.com/haasn/libplacebo.git "${MPV_DIR}/subprojects/libplacebo"
fi

if ! command -v cargo > /dev/null; then
    echo "error: cargo not found. Install Rust with rustup (https://rustup.rs) and re-run 'make deps'." >&2
    exit 1
fi
if ! just --justfile "${PROJECT_ROOT}/justfile" --summary > /dev/null 2>&1; then
    echo "error: just is missing or too old for this justfile. Install it with 'cargo install --locked just'." >&2
    exit 1
fi

echo "All build dependencies are installed."
