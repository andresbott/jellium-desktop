# Debian/Ubuntu `.deb` Build Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Produce native `.deb` packages of `jellium-desktop` for Debian 12/13 and Ubuntu 24.04/26.04 on amd64 + arm64, built per-distro with nfpm, depending on the distro's libmpv and bundling CEF.

**Architecture:** A new `--system-mpv` xtask mode links the distro's libmpv (via pkg-config) instead of building/bundling the fork. A `dev/linux/deb/` module (just recipe + `build.sh` + nfpm template) stages CEF + the binary under `/opt/jellium-desktop`, computes `Depends:` with `dpkg-shlibdeps`, and runs nfpm. A GitHub Actions matrix builds one `.deb` per distro/arch inside that distro's own container.

**Tech Stack:** Rust (xtask/clap), just, POSIX sh, nfpm, dpkg-dev (`dpkg-shlibdeps`), GitHub Actions containers.

**Spec:** `docs/superpowers/specs/2026-09-07-debian-deb-build-design.md`

## Global Constraints

- **Rust toolchain ≥ 1.85** (edition 2024) — install via rustup in every container; distro rust (esp. Debian 12) is too old.
- **Install prefix:** `/opt/jellium-desktop` (binary + CEF payload); `/usr/bin/jellium-desktop` is a **symlink** into it (keeps `$ORIGIN` rpath valid). Desktop/icon/metainfo under `/usr/share`.
- **mpv:** system libmpv only — never bundle libmpv in the `.deb`. `Depends:` is derived by `dpkg-shlibdeps`, never hand-listed (yields distro-correct names: `libmpv1` on bookworm, `libmpv2`/`t64` names elsewhere).
- **Package identity:** name `jellium-desktop`, license `GPL-2.0-or-later`, section `video`, priority `optional`, homepage `https://github.com/andrewrabert/jellium-desktop`.
- **Lint before commit:** `just fmt` and `just lint` must pass for any Rust change (`clippy` denies `unwrap`/`expect`/`panic`).
- **Matrix:** `{debian:12 bookworm, debian:13 trixie, ubuntu:24.04 noble, ubuntu:26.04 resolute} × {amd64→ubuntu-24.04, arm64→ubuntu-24.04-arm}`.
- **Git:** never commit on `main`/`master`; single-line commit messages; no `Co-Authored-By`.

## File Structure

- **Modify** `src/xtask/src/main.rs` — add `--system-mpv` flag (conflicts with `--external-mpv`) to `BuildArgs`.
- **Modify** `src/xtask/src/build.rs` — honour `system_mpv`: skip mpv build, clear mpv env vars (fall through to pkg-config), skip mpv staging.
- **Modify** `src/xtask/src/platform_linux.rs` — `install`: skip copying libmpv when `system_mpv`.
- **Create** `src/xtask/tests/args.rs` — parse-level test for the new flag + conflict.
- **Create** `dev/linux/deb/deb.just` — `just deb build` / `clean`.
- **Create** `dev/linux/deb/build.sh` — packaging driver (stage → shlibdeps → render nfpm.yaml → nfpm pkg).
- **Create** `dev/linux/deb/nfpm.yaml.in` — nfpm config template.
- **Modify** `dev/linux/linux.just` — register `mod deb 'deb/deb.just'`.
- **Create** `.github/workflows/build-linux-deb.yml` — CI matrix.

---

### Task 1: xtask `--system-mpv` build mode

**Files:**
- Modify: `src/xtask/src/main.rs` (`BuildArgs`, ~line 42-62)
- Modify: `src/xtask/src/build.rs` (mpv selection ~line 15-20, env block ~line 56-67, stage call ~line 104)
- Modify: `src/xtask/src/platform_linux.rs` (`install`, ~line 35-43)
- Test: `src/xtask/tests/args.rs` (create)

**Interfaces:**
- Produces: `BuildArgs.system_mpv: bool` (clap `--system-mpv`, `conflicts_with = "external_mpv"`), consumed by `build::run` and `platform_linux::install` (both already receive `&BuildArgs`).

- [ ] **Step 1: Write the failing test**

Create `src/xtask/tests/args.rs`. `BuildArgs` derives `clap::Args`; to parse it standalone, wrap it in a throwaway `Parser`.

```rust
use clap::Parser;
use xtask::BuildArgs;

#[derive(Parser)]
struct Wrap {
    #[command(flatten)]
    build: BuildArgs,
}

#[test]
fn system_mpv_flag_parses() {
    let w = Wrap::try_parse_from(["x", "--system-mpv"]).expect("should parse");
    assert!(w.build.system_mpv);
}

#[test]
fn system_mpv_conflicts_with_external_mpv() {
    let err = Wrap::try_parse_from(["x", "--system-mpv", "--external-mpv", "/tmp/mpv"]);
    assert!(err.is_err(), "system-mpv and external-mpv must conflict");
}

#[test]
fn system_mpv_defaults_false() {
    let w = Wrap::try_parse_from(["x"]).expect("should parse");
    assert!(!w.build.system_mpv);
}
```

This requires `xtask` to be usable as a library. Check `src/xtask/Cargo.toml`: if there is no `[lib]`, add a test-visible surface. The simplest route that avoids restructuring: add `src/xtask/src/lib.rs` re-exporting `BuildArgs`, or mark the test as an integration test against the binary crate. Prefer adding a minimal `lib.rs`:

```rust
// src/xtask/src/lib.rs
pub use crate::args::BuildArgs;
```

If `BuildArgs` currently lives in `main.rs`, move the `#[derive(clap::Args)] pub struct BuildArgs {...}` (and the other `*Args` structs) into a new `src/xtask/src/args.rs`, add `mod args; pub use args::*;` in both `main.rs` and a new `lib.rs`. Keep `main.rs` as the binary entry. (This is a small, mechanical move — do it as part of this step.)

- [ ] **Step 2: Run the test to verify it fails**

Run: `cargo test --manifest-path src/Cargo.toml -p xtask --test args`
Expected: FAIL — `no field 'system_mpv'` (flag not defined yet), or a compile error until `lib.rs`/`args.rs` exist.

- [ ] **Step 3: Add the flag to `BuildArgs`**

In `src/xtask/src/args.rs` (or wherever `BuildArgs` now lives), add after the `external_mpv` field:

```rust
    /// Link the system libmpv via pkg-config instead of building or
    /// bundling one (Linux .deb builds). Mutually exclusive with
    /// --external-mpv.
    #[arg(long, conflicts_with = "external_mpv")]
    pub system_mpv: bool,
```

- [ ] **Step 4: Honour `system_mpv` in `build.rs`**

In `src/xtask/src/build.rs`, replace the mpv-selection block (currently lines ~15-20):

```rust
    let (mpv_info, used_external_mpv) = if let Some(dir) = &args.external_mpv {
        println!("Using external mpv from: {}", dir.display());
        (Some(mpv::external(dir)?), true)
    } else if args.system_mpv {
        println!("Using system libmpv (pkg-config)");
        (None, false)
    } else {
        (Some(mpv::build(&out, args.mpv_cli)?), false)
    };
```

Replace the mpv env block (currently lines ~56-67) with a three-way match:

```rust
    match (&args.external_mpv, args.system_mpv) {
        (Some(dir), _) => {
            cmd.env("EXTERNAL_MPV_DIR", dir);
            cmd.env_remove("JFN_MPV_INCLUDE_DIR");
            cmd.env_remove("JFN_MPV_LIB_DIR");
        }
        (None, true) => {
            // Fall through to src/mpv/build.rs's pkg-config path.
            cmd.env_remove("EXTERNAL_MPV_DIR");
            cmd.env_remove("JFN_MPV_INCLUDE_DIR");
            cmd.env_remove("JFN_MPV_LIB_DIR");
        }
        (None, false) => {
            cmd.env_remove("EXTERNAL_MPV_DIR");
            cmd.env("JFN_MPV_INCLUDE_DIR", paths::mpv_source_dir().join("include"));
            if let Some(m) = &mpv_info {
                cmd.env("JFN_MPV_LIB_DIR", &m.build_dir);
            }
        }
    }
```

Replace the `stage_mpv` call (currently line ~104) so it only runs when an mpv was built/staged:

```rust
    crate::platform::stage_cef(&out, &cef_info)?;
    if let Some(m) = &mpv_info {
        crate::platform::stage_mpv(&out, m, used_external_mpv, &bin_dst)?;
    }
```

- [ ] **Step 5: Skip libmpv copy in `platform_linux::install`**

In `src/xtask/src/platform_linux.rs`, replace the mpv copy block in `install` (currently lines ~35-43):

```rust
    if args.system_mpv {
        // System libmpv is resolved by the dynamic loader at runtime;
        // nothing to stage into the package prefix.
    } else if let Some(dir) = &args.external_mpv {
        xfs::copy_file(
            &dir.join("lib").join("libmpv.so"),
            &prefix.join("libmpv.so"),
        )?;
    } else {
        let runtime = mpv::runtime_library_name();
        xfs::copy_file(&build_dir.join(runtime), &prefix.join(runtime))?;
    }
```

- [ ] **Step 6: Run the arg tests to verify they pass**

Run: `cargo test --manifest-path src/Cargo.toml -p xtask --test args`
Expected: PASS (3 tests).

- [ ] **Step 7: Verify the workspace still builds and lints**

Run: `just fmt && cargo build --manifest-path src/Cargo.toml -p xtask && just clippy`
Expected: clean build, no clippy errors. (Full `just build` needs CEF/mpv; building just `-p xtask` is enough to validate this task.)

- [ ] **Step 8: Commit**

```bash
git add src/xtask
git commit -m "feat(xtask): add --system-mpv mode to link system libmpv"
```

---

### Task 2: `dev/linux/deb/` packaging module

**Files:**
- Create: `dev/linux/deb/nfpm.yaml.in`
- Create: `dev/linux/deb/build.sh`
- Create: `dev/linux/deb/deb.just`
- Modify: `dev/linux/linux.just` (append `mod deb`)

**Interfaces:**
- Consumes: `cargo xtask install --system-mpv --prefix <dir>` from Task 1; CEF present in `.cache/cef` (from `cargo xtask fetch-cef`).
- Produces: `dist/jellium-desktop_<version>_<arch>.deb`; env contract `DEB_ARCH` (defaults to `dpkg --print-architecture`).

- [ ] **Step 1: Create the nfpm template**

Create `dev/linux/deb/nfpm.yaml.in`. `${VERSION}`, `${DEB_ARCH}`, `${DEPENDS}` are filled by `build.sh` via `envsubst`. `${DEPENDS}` is substituted with a YAML flow array (e.g. `[ "libc6 (>= 2.34)", "libmpv2" ]`).

```yaml
name: jellium-desktop
arch: ${DEB_ARCH}
version: ${VERSION}
version_schema: none
section: video
priority: optional
maintainer: "Jellium Contributors <net.nullsum@users.noreply.github.com>"
homepage: https://github.com/andrewrabert/jellium-desktop
description: Desktop client for Jellyfin, built on CEF with mpv playback.
license: GPL-2.0-or-later
depends: ${DEPENDS}
contents:
  # Binary + CEF payload (recursive; includes locales/).
  - src: build/deb/staging/opt/jellium-desktop/**
    dst: /opt/jellium-desktop
  - src: resources/linux/net.nullsum.JelliumDesktop.desktop
    dst: /usr/share/applications/net.nullsum.JelliumDesktop.desktop
  - src: resources/linux/net.nullsum.JelliumDesktop.svg
    dst: /usr/share/icons/hicolor/scalable/apps/net.nullsum.JelliumDesktop.svg
  - src: resources/linux/net.nullsum.JelliumDesktop.metainfo.xml
    dst: /usr/share/metainfo/net.nullsum.JelliumDesktop.metainfo.xml
  - src: /opt/jellium-desktop/jellium-desktop
    dst: /usr/bin/jellium-desktop
    type: symlink
```

- [ ] **Step 2: Create `build.sh`**

Create `dev/linux/deb/build.sh` (mode `0755`). Runs on a Debian/Ubuntu host (or container) with `dpkg-dev`, `nfpm`, `gettext-base`, `libmpv-dev`, `libavcodec-dev`, and CEF's runtime-lib providers installed.

```sh
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

# 1. Build + stage binary and CEF payload into /opt/jellium-desktop (no libmpv).
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

# 2. Ensure CEF's runtime-lib providers are installed so dpkg-shlibdeps can
#    map libcef.so's DT_NEEDED sonames to packages. Try the base name, then
#    the t64 variant (Ubuntu 24.04+/Debian 13 time_t transition). A soname
#    with no provider is simply skipped by --ignore-missing-info below.
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

# 3. Compute Depends via dpkg-shlibdeps. -l marks our private lib dir so
#    bundled CEF sonames resolve locally (not as external deps); analysing
#    the binary + bundled .so pulls in libmpv, libavcodec, and CEF's system
#    deps under their distro-correct package names.
WORK="$(mktemp -d)"
mkdir -p "$WORK/debian"
printf 'Source: jellium-desktop\n\nPackage: jellium-desktop\nArchitecture: any\n' \
    > "$WORK/debian/control"
RAW_DEPENDS="$(cd "$WORK" && dpkg-shlibdeps -O --ignore-missing-info \
    -l "$PREFIX" \
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
```

- [ ] **Step 3: Create the just recipe**

Create `dev/linux/deb/deb.just`:

```just
set working-directory := '../../..'

[private]
mod linux_common '../linux_common.just'

[private]
default:
    @just --list deb

# Build the .deb (runs on a Debian/Ubuntu host or container)
[group('package')]
[linux]
build: linux_common::deps
    ./dev/linux/deb/build.sh

# Remove deb build artifacts
[group('maintenance')]
[linux]
clean:
    rm -rf build/deb
```

- [ ] **Step 4: Register the module**

In `dev/linux/linux.just`, after the `flatpak` module registration (~line 51), add:

```just
[group('package')]
mod deb 'deb/deb.just'
```

- [ ] **Step 5: Make `build.sh` executable and verify just wiring**

Run:
```bash
chmod +x dev/linux/deb/build.sh
just --list deb
```
Expected: `just --list deb` shows `build` and `clean` recipes without error.

- [ ] **Step 6: Build a real `.deb` in a Debian container and inspect it**

This is the deliverable test. Uses podman (fallback docker), mirroring the appimage flow. Runs the full pipeline in `debian:13`:

```bash
CImg=debian:13
podman run --rm -v "$PWD":/src -w /src "$CImg" sh -euc '
  apt-get update
  apt-get install -y --no-install-recommends \
    ca-certificates curl git jq build-essential pkg-config \
    clang libclang-dev libmpv-dev libavcodec-dev dpkg-dev gettext-base
  curl --proto "=https" --tlsv1.2 -sSf https://sh.rustup.rs \
    | sh -s -- -y --profile minimal --default-toolchain stable
  . "$HOME/.cargo/env"
  curl -sSL "https://github.com/goreleaser/nfpm/releases/download/v2.43.0/nfpm_2.43.0_$(dpkg --print-architecture).deb" -o /tmp/nfpm.deb
  apt-get install -y /tmp/nfpm.deb
  cargo run -q --manifest-path src/xtask/Cargo.toml -- fetch-cef
  ./dev/linux/deb/build.sh
  echo "=== dpkg -c ==="; dpkg -c dist/*.deb
  echo "=== control ==="; dpkg -I dist/*.deb
'
```
Expected:
- A `dist/*.deb` is produced.
- `dpkg -c` shows `/opt/jellium-desktop/jellium-desktop`, `/opt/jellium-desktop/libcef.so`, `locales/`, the `/usr/share/...` files, and `/usr/bin/jellium-desktop -> /opt/jellium-desktop/jellium-desktop`.
- `dpkg -I` `Depends:` contains `libmpv2` (trixie) and `libavcodec*`, plus CEF's system libs. No `libmpv` copy appears under `/opt`.

- [ ] **Step 7: Verify install + link resolution (retires the fork risk)**

Append to the same container command (or a second run) after building:

```bash
podman run --rm -v "$PWD":/src -w /src debian:13 sh -euc '
  apt-get update
  apt-get install -y ./dist/*.deb
  echo "=== ldd ==="; ldd /opt/jellium-desktop/jellium-desktop
  ldd /opt/jellium-desktop/jellium-desktop | grep -q "not found" && { echo FAIL; exit 1; } || echo "OK: all libs resolved"
'
```
Expected: `apt` pulls the declared `Depends` (including stock libmpv), and `ldd` shows **no "not found"** — proving the binary links against the distro's libmpv. (`dist/*.deb` must be the one just built; run this right after Step 6 in the same checkout.)

- [ ] **Step 8: Commit**

```bash
git add dev/linux/deb dev/linux/linux.just
git commit -m "feat(linux): add nfpm-based .deb packaging module"
```

---

### Task 3: GitHub Actions workflow

**Files:**
- Create: `.github/workflows/build-linux-deb.yml`

**Interfaces:**
- Consumes: `dev/linux/deb/build.sh` (Task 2), `./.github/actions/setup-cef` (existing), `DEB_ARCH` env.
- Produces: per-cell artifacts `linux-deb-<codename>-<arch>` from `dist/*.deb`.

- [ ] **Step 1: Create the workflow**

Create `.github/workflows/build-linux-deb.yml`:

```yaml
name: build-linux-deb

on:
  workflow_dispatch:
  pull_request:
  push:
    branches:
      - main
    tags:
      - 'v*'

concurrency:
  group: ${{ github.workflow }}-${{ github.ref }}
  cancel-in-progress: true

jobs:
  build:
    strategy:
      fail-fast: false
      matrix:
        include:
          - { distro: 'debian:12',   codename: bookworm,  deb_arch: amd64, runner: ubuntu-24.04 }
          - { distro: 'debian:12',   codename: bookworm,  deb_arch: arm64, runner: ubuntu-24.04-arm }
          - { distro: 'debian:13',   codename: trixie,    deb_arch: amd64, runner: ubuntu-24.04 }
          - { distro: 'debian:13',   codename: trixie,    deb_arch: arm64, runner: ubuntu-24.04-arm }
          - { distro: 'ubuntu:24.04', codename: noble,    deb_arch: amd64, runner: ubuntu-24.04 }
          - { distro: 'ubuntu:24.04', codename: noble,    deb_arch: arm64, runner: ubuntu-24.04-arm }
          - { distro: 'ubuntu:26.04', codename: resolute, deb_arch: amd64, runner: ubuntu-24.04 }
          - { distro: 'ubuntu:26.04', codename: resolute, deb_arch: arm64, runner: ubuntu-24.04-arm }
    runs-on: ${{ matrix.runner }}
    container: ${{ matrix.distro }}

    steps:
      - name: Install base tooling
        run: |
          apt-get update
          apt-get install -y --no-install-recommends \
            ca-certificates curl git jq build-essential pkg-config \
            clang libclang-dev \
            libmpv-dev libavcodec-dev \
            dpkg-dev gettext-base

      - name: Checkout
        uses: actions/checkout@v7

      - name: Install Rust toolchain
        run: |
          curl --proto '=https' --tlsv1.2 -sSf https://sh.rustup.rs \
            | sh -s -- -y --profile minimal --default-toolchain stable
          echo "$HOME/.cargo/bin" >> "$GITHUB_PATH"

      - name: Install nfpm
        run: |
          ver=2.43.0
          arch="$(dpkg --print-architecture)"
          curl -sSL "https://github.com/goreleaser/nfpm/releases/download/v${ver}/nfpm_${ver}_${arch}.deb" -o /tmp/nfpm.deb
          apt-get install -y /tmp/nfpm.deb

      - uses: ./.github/actions/setup-cef
        with:
          platform: ${{ github.workflow }}-${{ matrix.codename }}-${{ matrix.deb_arch }}

      - name: Build .deb
        run: ./dev/linux/deb/build.sh
        env:
          DEB_ARCH: ${{ matrix.deb_arch }}

      - name: Verify install + link resolution
        run: |
          apt-get install -y ./dist/*.deb
          ldd /opt/jellium-desktop/jellium-desktop
          if ldd /opt/jellium-desktop/jellium-desktop | grep -q 'not found'; then
            echo "unresolved libraries"; exit 1
          fi

      - name: Upload artifact
        uses: actions/upload-artifact@v7
        with:
          name: linux-deb-${{ matrix.codename }}-${{ matrix.deb_arch }}
          path: dist/*.deb
```

- [ ] **Step 2: Validate the workflow YAML**

Run: `python3 -c "import yaml,sys; yaml.safe_load(open('.github/workflows/build-linux-deb.yml'))" && echo OK`
Expected: `OK` (well-formed YAML). If `actionlint` is available, run it too: `actionlint .github/workflows/build-linux-deb.yml`.

- [ ] **Step 3: Commit**

```bash
git add .github/workflows/build-linux-deb.yml
git commit -m "ci: add Debian/Ubuntu .deb build workflow"
```

- [ ] **Step 4: Push and observe CI (requires user approval to push)**

Do **not** push without explicit user approval (branch is not `main`; pushing publishes to the remote). Once approved:

```bash
git push -u origin HEAD
```
Then watch the run (e.g. `gh run watch`). Expected: all 8 cells green; each uploads `linux-deb-<codename>-<arch>`. If the `ubuntu:26.04` image is not yet published on Docker Hub, those two cells will fail at container pull — see the spec's note (temporarily pin a `devel` tag or drop those two rows).

---

## Self-Review

**Spec coverage:**
- xtask `--system-mpv` (spec Component 1) → Task 1. ✓
- Package layout `/opt` + `/usr/bin` symlink + `/usr/share` (Component 2) → Task 2 (nfpm `contents`), verified Step 6. ✓
- `dev/linux/deb/` module, deb.just, template (Component 3) → Task 2. ✓
- `dpkg-shlibdeps` deriving Depends, ignoring bundled sonames (Component 3 notes) → Task 2 Step 3 (`build.sh` step 3). ✓
- CI matrix 4 distros × 2 arch, rustup, setup-cef, artifacts (Component 4) → Task 3. ✓
- Testing: build green + `ldd` smoke test (Testing strategy) → Task 2 Step 7, Task 3 Verify step. ✓
- bookworm libmpv1 handled automatically by shlibdeps → no hand-listed deps (verified by inspecting `dpkg -I` per distro). ✓
- Ubuntu 26.04 tag risk → Task 3 Step 4 note. ✓

**Placeholder scan:** No `TBD`/`TODO`/"add appropriate…" — all code and package metadata are concrete. Maintainer/homepage are real, working values (adjustable but not placeholders).

**Type consistency:** `system_mpv` is the field name used identically in Task 1 Steps 3-5 (`args.system_mpv`) and threaded through the existing `&BuildArgs` params of `build::run`/`platform_linux::install`. `DEB_ARCH`/`VERSION`/`DEPENDS` env names match between `nfpm.yaml.in`, `build.sh`, and the workflow.

**Notes for the executor:**
- nfpm's `**` glob (Task 2 Step 1) preserves the tree relative to the fixed prefix; Task 2 Step 6's `dpkg -c` is the check that it mapped correctly. If nfpm places files wrongly, switch the `/opt` entry to explicit per-file entries.
- `build.sh` may need `apt-get install` privileges for the CEF-lib step; in CI the container runs as root (fine). Locally it's exercised via the container command in Task 2 Step 6.
