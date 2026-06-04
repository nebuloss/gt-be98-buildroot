#!/bin/sh
# Buildroot ROOTFS_POST_BUILD_SCRIPT for GT-BE98.
# Runs after the target rootfs is assembled, before image creation.
# $1 = target directory ($TARGET_DIR).
#
# TODO: asus/merlin-specific rootfs tweaks (nvram defaults, /etc/init.d wiring,
# rom/etc layout, wlan firmware placement). See gt-be98-firmware's fs.install
# layout and tools/verify-artifact.sh for the expected contents.
set -e
TARGET_DIR="$1"
: "${TARGET_DIR:?post-build.sh: TARGET_DIR not given}"

# (placeholder — no-op until userspace porting begins)
exit 0
