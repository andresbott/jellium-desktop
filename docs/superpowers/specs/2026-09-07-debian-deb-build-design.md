# Debian/Ubuntu `.deb` build design

**Date:** 2026-09-07
**Status:** Approved for planning

## Goal

Produce native `.deb` packages of `jellium-desktop` for four target distros —
Debian 12 (oldstable, bookworm), Debian 13 (stable, trixie), Ubuntu 24.04, and
Ubuntu 26.04 — on both `amd64` and `arm64`, driven from a GitHub Actions
workflow that mirrors the existing AppImage/Flatpak workflows. Packages are
assembled with [nfpm](https://nfpm.goreleaser.com/).

Unlike the AppImage and Flatpak (which build libmpv from the `third_party/mpv`
fork and bundle it), the `.deb` **depends on the distro's own libmpv** and
bundles only CEF.

## Investigation: why system libmpv is sufficient

The concern was that embedding mpv's video into the app's Wayland subsurface
might require the `third_party/mpv` fork. It does not:

- **Wayland**: `WaylandMpvHost` does *not* override `embed_wid`
  (`src/wayland/src/mpv_host.rs`; the trait default in
  `src/platform_abi/src/mpv_host.rs:35` returns `None`). The app instead stands
  up a **Wayland proxy** and points mpv at it via `WAYLAND_DISPLAY`
  (`src/wayland/src/mpv_host.rs:51`). mpv connects as a stock, unmodified
  Wayland client; the proxy reparents its surface. No mpv patch is involved.
- **X11**: embedding uses mpv's standard `--wid` option
  (`src/x11/src/mpv_host.rs`) — a long-supported stock feature.
- The mpv boot path (`src/mpv/src/boot.rs`) sets **only stock libmpv options**,
  and `set_option_or_skip` tolerates any option a given libmpv build lacks
  (`MPV_ERROR_OPTION_NOT_FOUND`). It already runs against libmpv versions that
  differ from the fork.
- `src/mpv/build.rs` already supports linking system libmpv via **pkg-config**
  (source order #3).

**Conclusion:** the `.deb` can depend on the distro libmpv. The residual risk
(some fork-specific behaviour) is retired by a playback/link smoke test in the
build matrix rather than a source diff.

### The SONAME split (drives the per-distro matrix)

| Distro | mpv (approx) | libmpv SONAME | apt package |
|---|---|---|---|
| Debian 12 (oldstable, bookworm) | ~0.35 | `libmpv.so.1` | `libmpv1` |
| Debian 13 (stable, trixie) | ~0.39 | `libmpv.so.2` | `libmpv2` |
| Ubuntu 24.04 (noble) | ~0.38 | `libmpv.so.2` | `libmpv2` |
| Ubuntu 26.04 | newer | `libmpv.so.2` | `libmpv2` |

bookworm is one SONAME behind the others. This rules out any "build once, ship
everywhere" approach and is the reason each `.deb` is built inside its own
distro container: the binary's `DT_NEEDED` and the generated `Depends:` then
come out correct automatically (`libmpv1` on bookworm, `libmpv2` elsewhere).

## Data flow (per matrix job)

```
checkout
  ─▶ apt: build deps + libmpv-dev + libavcodec-dev + CEF runtime libs
         + dpkg-dev + nfpm
  ─▶ rustup (toolchain ≥ 1.85 — edition 2024; distro rust is too old, esp. bookworm)
  ─▶ setup-cef (actions/cache + cargo xtask fetch-cef)
  ─▶ cargo xtask install --system-mpv --prefix build/deb/opt/jellium-desktop
  ─▶ dpkg-shlibdeps → compute Depends
  ─▶ render nfpm.yaml (version, arch, depends) ─▶ nfpm pkg ─▶ dist/*.deb
  ─▶ verify: apt install ./*.deb ; ldd shows libmpv resolved, no "not found"
  ─▶ upload artifact
```

## Component 1 — xtask `--system-mpv` mode (only Rust change)

Today `cargo xtask build` has two mpv modes: an in-tree meson build of the fork
(default) and `--external-mpv <dir>` (fork built out of tree, used by Flatpak).
Neither uses the distro's libmpv, and `install` always copies a libmpv into the
prefix. Add a third mode.

New `BuildArgs::system_mpv` flag (`--system-mpv`). When set:

- **`src/xtask/src/build.rs`**: skip `mpv::build`; do **not** set
  `JFN_MPV_INCLUDE_DIR` / `JFN_MPV_LIB_DIR` / `EXTERNAL_MPV_DIR` (so
  `src/mpv/build.rs` falls through to its pkg-config path and links the system
  `libmpv`); skip `stage_mpv`; add no mpv rpath entry.
- **`src/xtask/src/platform_linux.rs::install`**: when `system_mpv`, do not copy
  any libmpv into the prefix.
- **libavcodec**: no change needed — `src/mpv/build.rs` already falls back to
  pkg-config `libavcodec`, so the distro's `libavcodec-dev` supplies the
  capability-detection bindings. This is the same ffmpeg the distro libmpv uses,
  which avoids the rpath-link workaround the Flatpak needs.

The flag is threaded through `InstallArgs`/`PackageArgs` via the existing
`#[command(flatten)]` on `BuildArgs`.

## Component 2 — package layout

Install target `/opt/jellium-desktop` (self-contained; matches the
`/opt/jellium-desktop/...` convention already referenced in
`src/jfn_rust/build.rs`; `$ORIGIN` rpath resolves `libcef.so` with no wrapper).

```
/opt/jellium-desktop/
    jellium-desktop                 # binary, rpath $ORIGIN
    libcef.so
    libEGL.so  libGLESv2.so  libvk_swiftshader.so
    *.pak  icudtl.dat  v8_context_snapshot.bin  vk_swiftshader_icd.json
    locales/
/usr/bin/jellium-desktop            # symlink → /opt/jellium-desktop/jellium-desktop
/usr/share/applications/net.nullsum.JelliumDesktop.desktop
/usr/share/icons/hicolor/scalable/apps/net.nullsum.JelliumDesktop.svg
/usr/share/metainfo/net.nullsum.JelliumDesktop.metainfo.xml
```

No libmpv is shipped. The `/usr/bin` symlink (not a copy) keeps `$ORIGIN`
pointing at `/opt/jellium-desktop`, so `libcef.so` still resolves.

`cargo xtask install --system-mpv --prefix build/deb/opt/jellium-desktop`
produces the `/opt` subtree (binary + CEF, no libmpv). The `/usr/share` files
and the symlink are supplied by the nfpm `contents` mapping (source files come
straight from `resources/linux/`).

## Component 3 — `dev/linux/deb/` module (local + CI parity)

Mirrors `dev/linux/appimage/` and `dev/linux/flatpak/`:

- **`deb.just`** — `just deb build` and `just deb clean`, OS-gated `[linux]`,
  registered in `dev/linux/linux.just` as `mod deb`. `build` depends on
  `linux_common::deps` (submodules/CEF) and calls `build.sh`.
- **`build.sh`** — the packaging driver:
  1. `cargo xtask install --system-mpv --prefix <stage>/opt/jellium-desktop`.
  2. Stage `/usr/share` files + the `/usr/bin` symlink (or leave the symlink to
     nfpm `contents`).
  3. Compute `Depends:` with `dpkg-shlibdeps`, analyzing the **binary and
     `libcef.so`**. Our own bundled sonames (`libcef.so`, `libEGL.so`, …) have
     no owning package and are ignored; genuine system deps emerge from
     `libcef.so`'s `DT_NEEDED` (nss, nspr, gtk/at-spi2, cairo, cups, pango, X11
     libs) plus the binary's (`libmpv.so.N`, `libavcodec.so.N`, …).
  4. Render the final `nfpm.yaml` from the template, injecting `VERSION`
     (`cargo xtask version`), `DEB_ARCH`, and the computed `DEPENDS`.
  5. `nfpm pkg --packager deb --target dist/`.
- **`nfpm.yaml.in`** — template with `${VERSION}`, `${DEB_ARCH}`, `${DEPENDS}`
  placeholders; `contents` maps the staged `/opt` tree, the `resources/linux`
  files to `/usr/share/...`, and the `/usr/bin` symlink. Package metadata:
  `name: jellium-desktop`, `section: video`, `priority: optional`, maintainer,
  homepage, description.

### dpkg-shlibdeps notes

- Requires `dpkg-dev` installed and the referenced system libraries present in
  the container (they are — installed as build/runtime deps), so the dpkg
  database can map each `DT_NEEDED` soname to its owning package.
- Bundled CEF sonames will produce "no dependency information" warnings; these
  are expected and ignored (we ship those libs inside the package). Use the
  package's own private lib dir on the search path / `--ignore-missing-info` so
  only real system deps are emitted.

## Component 4 — CI workflow `.github/workflows/build-linux-deb.yml`

Same triggers, concurrency group, and `setup-cef` composite action as
`build-linux-appimage.yml`. Matrix (8 cells):

| distro (container image) | codename | deb arch | runner |
|---|---|---|---|
| `debian:12` | bookworm | amd64 | ubuntu-24.04 |
| `debian:12` | bookworm | arm64 | ubuntu-24.04-arm |
| `debian:13` | trixie | amd64 | ubuntu-24.04 |
| `debian:13` | trixie | arm64 | ubuntu-24.04-arm |
| `ubuntu:24.04` | noble | amd64 | ubuntu-24.04 |
| `ubuntu:24.04` | noble | arm64 | ubuntu-24.04-arm |
| `ubuntu:26.04` | (resolute) | amd64 | ubuntu-24.04 |
| `ubuntu:26.04` | (resolute) | arm64 | ubuntu-24.04-arm |

- Jobs run inside `container: <image>`; arm64 builds natively on `*-arm`
  runners (no cross-compilation).
- Steps: checkout → install `rustup` + toolchain + build deps + `nfpm` →
  `setup-cef` → `just deb build` (or `build.sh` directly) → verify → upload.
- Toolchain via **rustup** (not distro rust) in every container — edition 2024
  needs Rust ≥ 1.85, and bookworm's packaged rust is far older.
- `libclang`/`clang` installed for bindgen (`src/mpv/build.rs`,
  `src/jfn_cef/build.rs`).
- Submodules are not required for a `--system-mpv` build; checkout can skip
  `submodules: recursive` (CEF comes from `setup-cef`).
- Artifacts named `linux-deb-<codename>-<arch>`, path `dist/*.deb`.

## Testing strategy

- Build green on all 8 matrix cells.
- **Fork-risk guardrail** (per cell): `apt install ./*.deb` inside the container
  (pulls the generated `Depends:`, including stock libmpv), then
  `ldd /opt/jellium-desktop/jellium-desktop` shows **no "not found"** and libmpv
  resolved to the distro `.so`. This proves the app links cleanly against stock
  libmpv on each distro.
- `dpkg -c` layout check; optional `lintian` (non-blocking).
- Full GUI/playback verification stays manual (needs a display + GPU), same as
  AppImage/Flatpak.

## Risks and notes

- **bookworm libmpv 0.35 / libmpv1**: one SONAME behind. Handled by the
  per-distro build; option differences already tolerated by
  `set_option_or_skip`. The `ldd` smoke test is the guardrail.
- **CEF runtime GPU libs**: come from the host at runtime (same as AppImage);
  not fully testable headless in CI.
- **Ubuntu 26.04 container tag**: must be published when implemented. If the
  `ubuntu:26.04` image is not yet available, that cell may temporarily use a
  `devel` tag or be deferred; the other seven cells are unaffected.

## Out of scope

- APT repository / signing / distribution (build + artifact only).
- Cross-compilation (arm64 builds natively).
- Changes to the AppImage/Flatpak pipelines or the mpv fork.
