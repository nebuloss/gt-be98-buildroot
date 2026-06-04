#!/bin/sh
# Buildroot ROOTFS_POST_IMAGE_SCRIPT for GT-BE98.  $1 = images dir ($BINARIES_DIR).
#
# Step 2a: wrap Buildroot's rootfs.squashfs with the GT-BE98 boot chain into a
# flashable .pkgtb, reproducing the merlin bundle exactly.
#
# The GT-BE98 image is a two-layer FIT (verified against the merlin artifacts):
#   .itb  (bootfs) = ATF + U-Boot + aarch64 kernel(lzo) + per-board DTBs + OP-TEE
#   .pkgtb (bundle) = [loader] + bootfs(.itb) + rootfs(squashfs)   <- flashable
# The bundle is NOT signed (only the inner .itb is), so it's just an mkimage of a
# FIT that /incbin/s the prebuilt bootfs .itb and Buildroot's squashfs.
#
# Until Buildroot builds the aarch64 kernel/ATF/U-Boot itself (Step 2b), we reuse
# merlin's PREBUILT bootfs .itb + the u-boot mkimage. Override their locations
# with the env vars below (e.g. once they're gt-be98-packages Release blobs). If
# they're not found, we skip packaging with a clear notice rather than failing —
# a plain rootfs build still succeeds.
#
#   GT_BE98_BOOTFS_ITB  prebuilt bootfs .itb (ATF+U-Boot+kernel+dtbs)
#   GT_BE98_MKIMAGE     u-boot mkimage host binary
#   GT_BE98_LOADER      optional SPL loader blob -> also emit the _loader bundle
#   GT_BE98_MERLIN_ROOT merlin src-rt tree used to auto-locate the above
set -e

BINARIES_DIR="$1"
: "${BINARIES_DIR:?post-image.sh: BINARIES_DIR not given}"
# Canonicalize to absolute: we run mkimage from a temp CWD, so all input/output
# paths and /incbin/ symlink targets must be absolute.
BINARIES_DIR="$(CDPATH= cd -- "$BINARIES_DIR" && pwd)"

ROOTFS="$BINARIES_DIR/rootfs.squashfs"

# GT-BE98 bundle identity (verified from merlin's generated .pkgts).
CHIP="${GT_BE98_CHIP:-6813}"
PROFILE="${GT_BE98_PROFILE:-96813GW}"
REV="${GT_BE98_REV:-a0+}"
COMPATSTR="${GT_BE98_COMPATSTR:-rev=a0+;ip=ipv6,ipv4;ddr=ddr4}"

# Auto-locate the prebuilt boot chain in the sibling merlin tree if not given.
EXT="${BR2_EXTERNAL_GT_BE98_PATH:-$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)}"
MERLIN_ROOT="${GT_BE98_MERLIN_ROOT:-$EXT/../gt-be98-firmware/vendor/asuswrt-merlin.ng/release/src-rt-5.04behnd.4916}"

# bootfs .itb source, in priority order:
#   1. GT_BE98_BOOTFS_ITB env override
#   2. the gt-be98-bootfs package (installs it into BINARIES_DIR) — no merlin tree
#   3. auto-locate the sibling merlin tree (fallback for local dev)
if [ -n "${GT_BE98_BOOTFS_ITB:-}" ]; then BOOTFS_ITB="$GT_BE98_BOOTFS_ITB"
elif [ -f "$BINARIES_DIR/bcm${PROFILE}_uboot_linux.itb" ]; then BOOTFS_ITB="$BINARIES_DIR/bcm${PROFILE}_uboot_linux.itb"
else BOOTFS_ITB="$MERLIN_ROOT/targets/$PROFILE/bcm${PROFILE}_uboot_linux.itb"; fi

# mkimage: explicit override, else Buildroot host, else merlin, else PATH.
if [ -n "${GT_BE98_MKIMAGE:-}" ]; then MKIMAGE="$GT_BE98_MKIMAGE"
elif [ -x "${HOST_DIR:-/nonexistent}/bin/mkimage" ]; then MKIMAGE="$HOST_DIR/bin/mkimage"
elif [ -x "$MERLIN_ROOT/bootloaders/obj/uboot/tools/mkimage" ]; then MKIMAGE="$MERLIN_ROOT/bootloaders/obj/uboot/tools/mkimage"
else MKIMAGE="$(command -v mkimage 2>/dev/null || true)"; fi

skip() { echo "GT-BE98 post-image: SKIP .pkgtb — $1"; echo "  (set GT_BE98_BOOTFS_ITB / GT_BE98_MKIMAGE to enable; rootfs.squashfs is still built)"; exit 0; }

[ -f "$ROOTFS" ]      || skip "no rootfs.squashfs in $BINARIES_DIR (enable BR2_TARGET_ROOTFS_SQUASHFS)"
[ -f "$BOOTFS_ITB" ]  || skip "prebuilt bootfs .itb not found at $BOOTFS_ITB"
[ -n "$MKIMAGE" ] && [ -x "$MKIMAGE" ] || skip "mkimage not found"

# Emit the bundle FIT source (matches merlin's generate_bundle_itb output) and
# pack it.  $loader_img/$loader_ref are empty for the plain (non-loader) bundle.
make_pkgtb() {
	out="$1"; loader="$2"
	work="$(mktemp -d)"
	# symlink inputs so /incbin/ uses short relative names (as merlin did)
	ln -sf "$BOOTFS_ITB" "$work/bootfs.itb"
	ln -sf "$ROOTFS"     "$work/rootfs.squashfs"
	loader_img=""; loader_ref=""
	if [ -n "$loader" ]; then
		ln -sf "$loader" "$work/loader.bin"
		loader_img="
		loader_${CHIP}_${REV} {
			description = \"loader\";
			data = /incbin/(\"loader.bin\");
			type = \"firmware\";
			compression = \"none\";
			hash-1 { algo = \"sha256\"; };
		};"
		loader_ref="
			loader = \"loader_${CHIP}_${REV}\";"
	fi
	cat > "$work/bundle.pkgts" <<EOF
/dts-v1/;
/ {
	description = "GT-BE98";
	asus = "ASUSFLAG#1";
	#address-cells = <1>;
	images {$loader_img
		bootfs_${CHIP}_${REV} {
			description = "bootfs";
			data = /incbin/("bootfs.itb");
			type = "multi";
			compression = "none";
			hash-1 { algo = "sha256"; };
		};
		nand_squashfs {
			description = "rootfs";
			type = "filesystem";
			data = /incbin/("rootfs.squashfs");
			compression = "none";
			hash-1 { algo = "sha256"; };
		};
	};
	configurations {
		default = "conf_${CHIP}_${REV}_nand_squashfs";
		conf_${CHIP}_${REV}_nand_squashfs {
			description = "Brcm Image Bundle";$loader_ref
			bootfs = "bootfs_${CHIP}_${REV}";
			rootfs = "nand_squashfs";
			compatible = "flash=nand;chip=${CHIP};${COMPATSTR};fstype=squashfs";
		};
	};
};
EOF
	( cd "$work" && "$MKIMAGE" -f bundle.pkgts -E "$out" >/dev/null )
	rm -rf "$work"
	echo "GT-BE98 post-image: wrote $(basename "$out") ($(du -h "$out" | cut -f1))"
}

echo "GT-BE98 post-image: bundling .pkgtb (bootfs=$(basename "$BOOTFS_ITB"), mkimage=$MKIMAGE)"
make_pkgtb "$BINARIES_DIR/GT-BE98_nand_squashfs.pkgtb" ""
if [ -n "${GT_BE98_LOADER:-}" ] && [ -f "${GT_BE98_LOADER}" ]; then
	make_pkgtb "$BINARIES_DIR/GT-BE98_nand_squashfs_loader.pkgtb" "$GT_BE98_LOADER"
fi
exit 0
