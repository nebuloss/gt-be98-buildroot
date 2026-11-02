#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# build-flash-kit.sh - assemble the release flash kit (build host only, after
# board/gt-be98-mainline/build.sh): the directory the owner copies to the
# stock firmware's /tmp to flash slot 1 (docs/FLASHING.md).
#
#   sh board/gt-be98-mainline/flash/build-flash-kit.sh
#
# Output: $KIT_DIR (default $OUT/images/flash-kit):
#   gt-be98-flash.sh              the flash/boot helper (runs on stock)
#   ubirsvol, ubiupdatevol        static aarch64 mtd-utils of this build, for
#                                 a stock firmware that lacks them (the
#                                 Buildroot glibc refuses stock's 4.19, so the
#                                 build host's Debian cross toolchain is used)
#   rootfs.squashfs, ml-bootfs.itb  the images, built together (the itb's
#                                 initramfs boots only this rootfs from vol 4)
#   ml-bootfs.info                the build's own description of the images
#   IMAGES.sha256                 the two image sha256s: the values to publish
#                                 in the release notes and pass to the helper
#   SHA256SUMS                    every file above (transfer check)
# IMAGES: where the images are (default $OUT/images). RELEASE=1 (in the
# configuration or the environment) refuses an image that ml-bootfs.info
# does not mark "release mode: yes" (docs/RELEASE-BUILD.md); without it a
# lab image gets a LAB IMAGE warning. Nothing is written
# outside KIT_DIR. The kit contains proprietary vendor firmware (inside the
# rootfs): never publish it (board/gt-be98-mainline/README.md, licences).
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
CONF=${GT_BE98_LOCAL_CONF:-$HOME/.config/gt-be98-os/local.conf}
OUT=
ENV_RELEASE=${RELEASE:-0}
. "$CONF"
IMG=${IMAGES:-$OUT/images}
D=${KIT_DIR:-$IMG/flash-kit}
CC=${CC:-aarch64-linux-gnu-gcc}
STRIP=${STRIP:-aarch64-linux-gnu-strip}
die() { echo "build-flash-kit: $*" >&2; exit 1; }

for f in rootfs.squashfs ml-bootfs.itb ml-bootfs.info; do
	[ -f "$IMG/$f" ] || die "$IMG/$f missing: run build.sh first"
done
M=$(ls -d "$OUT"/build/mtd-[0-9]* 2>/dev/null | head -n1)
[ -n "$M" ] || die "no mtd-utils build in $OUT/build"
# the itb and the rootfs must come from the same build: ml-bootfs.info names
# the rootfs sha256 that the itb's initramfs accepts from vol 4
RSHA=$(sha256sum "$IMG/rootfs.squashfs" | cut -d' ' -f1)
ISHA=$(sha256sum "$IMG/ml-bootfs.itb" | cut -d' ' -f1)
grep -q "^rootfs.squashfs: .* sha256 $RSHA\$" "$IMG/ml-bootfs.info" ||
	die "rootfs.squashfs ($RSHA) is not the rootfs ml-bootfs.info records: rebuild"
grep -q "^ml-bootfs.itb: .* sha256 $ISHA\$" "$IMG/ml-bootfs.info" ||
	die "ml-bootfs.itb ($ISHA) is not the itb ml-bootfs.info records: rebuild"
# release mode (docs/RELEASE-BUILD.md): RELEASE=1 in the configuration or
# the environment demands a release-mode image; a lab image is only flagged
if grep -q '^release mode: yes$' "$IMG/ml-bootfs.info"; then
	MODE=release
else
	{ [ "${RELEASE:-0}" != 1 ] && [ "$ENV_RELEASE" != 1 ]; } || die "RELEASE=1 but ml-bootfs.info has no 'release mode: yes': not a release build"
	MODE=lab
	echo "build-flash-kit: WARNING: LAB IMAGE (no 'release mode: yes'): it may carry lab keys and addresses; never hand it over" >&2
fi

# replace only a directory this script made (or a new one)
if [ -e "$D" ]; then
	[ -f "$D/.gt-be98-flash-kit" ] || die "$D exists and is not a flash kit: not touching it"
	rm -rf "$D"
fi
mkdir -p "$D"
: > "$D/.gt-be98-flash-kit"
for u in ubirsvol ubiupdatevol; do
	(cd "$M" && $CC -static -O2 -Iinclude -I. -include include/config.h -o "$D/$u" \
		ubi-utils/$u.c lib/libubi.c lib/libmtd.c lib/libmtd_legacy.c lib/common.c lib/libcrc32.c)
done
$STRIP "$D/ubirsvol" "$D/ubiupdatevol"
install -m 0755 "$HERE/gt-be98-flash.sh" "$D/gt-be98-flash.sh"
install -m 0644 "$IMG/rootfs.squashfs" "$IMG/ml-bootfs.itb" "$IMG/ml-bootfs.info" "$D/"
printf '%s  rootfs.squashfs\n%s  ml-bootfs.itb\n' "$RSHA" "$ISHA" > "$D/IMAGES.sha256"
(cd "$D" && sha256sum gt-be98-flash.sh ubirsvol ubiupdatevol rootfs.squashfs ml-bootfs.itb \
	ml-bootfs.info IMAGES.sha256 > SHA256SUMS)
echo "flash kit ($MODE image): $D"
cat "$D/SHA256SUMS"
echo "flash with: /bin/busybox sh ./gt-be98-flash.sh flash --check rootfs.squashfs $RSHA ml-bootfs.itb $ISHA"
