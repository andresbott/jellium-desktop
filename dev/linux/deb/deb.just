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
