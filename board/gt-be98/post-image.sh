#!/bin/sh
# Buildroot ROOTFS_POST_IMAGE_SCRIPT for GT-BE98.
# Runs after images are built. $1 = images dir ($BINARIES_DIR).
#
# This is where the Broadcom .itb (ATF + U-Boot + kernel + fdt) and the final
# GT-BE98_*.pkgtb bundle get assembled. The merlin SDK does this with bcm tools
# (mkfit / pkgtb packaging + sgdisk GPT). Initial strategy: shell out to the
# merlin image tooling against the Buildroot-produced kernel + squashfs, then
# verify against gt-be98-firmware/tools/verify-artifact.sh.
#
# TODO: implement. See ARCHITECTURE.md roadmap step 2. Until then this is a no-op
# so `make` doesn't fail at the post-image stage.
set -e
BINARIES_DIR="$1"
: "${BINARIES_DIR:?post-image.sh: BINARIES_DIR not given}"

echo "GT-BE98 post-image: TODO — assemble .itb + .pkgtb (see board/gt-be98/post-image.sh)"
exit 0
