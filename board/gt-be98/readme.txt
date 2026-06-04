GT-BE98 board support (Buildroot external tree)
===============================================

Device : ASUS GT-BE98 (WiFi 7 router)
SoC    : Broadcom BCM6813 (ARM)
Status : SKELETON — migration in progress (see ../../ARCHITECTURE.md)

Files
-----
post-build.sh    rootfs tweaks before image creation (placeholder)
post-image.sh    .pkgtb bundle assembly (Step 2a IMPLEMENTED — wraps the
                 Buildroot rootfs.squashfs with a prebuilt bootfs .itb via
                 u-boot mkimage; see header for GT_BE98_* env overrides)
rootfs_overlay/  files copied verbatim onto the target rootfs
linux/           (add) kernel defconfig + .dts / config fragments for BCM6813

post-image.sh inputs (Step 2a uses merlin's prebuilt boot chain)
----------------------------------------------------------------
By default post-image.sh auto-locates the sibling merlin tree at
../gt-be98-firmware/.../src-rt-5.04behnd.4916 to borrow the prebuilt bootfs .itb
(ATF+U-Boot+aarch64 kernel+dtbs+OP-TEE) and u-boot mkimage. Override with:
  GT_BE98_BOOTFS_ITB   prebuilt bootfs .itb       (-> gt-be98-packages blob)
  GT_BE98_MKIMAGE      u-boot mkimage host binary (or Buildroot host-uboot-tools)
  GT_BE98_LOADER       SPL loader blob -> also emit GT-BE98_nand_squashfs_loader.pkgtb
If the .itb / mkimage aren't found, packaging is skipped with a notice (the plain
rootfs.squashfs still builds). Replacing the prebuilt .itb with a Buildroot-built
aarch64 kernel/ATF/U-Boot is Step 2b.

Reference build
---------------
The working asuswrt-merlin build lives in ../../../gt-be98-firmware. Use it as the
source of truth for: kernel config, the .itb/.pkgtb image format, wlan firmware
(rtecdc.bin for 6717a0/6726b0), nvram defaults, and the required-component list
(tools/verify-artifact.sh).
