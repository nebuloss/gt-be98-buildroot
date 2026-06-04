GT-BE98 board support (Buildroot external tree)
===============================================

Device : ASUS GT-BE98 (WiFi 7 router)
SoC    : Broadcom BCM6813 (ARM)
Status : SKELETON — migration in progress (see ../../ARCHITECTURE.md)

Files
-----
post-build.sh    rootfs tweaks before image creation (placeholder)
post-image.sh    .itb + .pkgtb assembly after image creation (placeholder)
rootfs_overlay/  files copied verbatim onto the target rootfs
linux/           (add) kernel defconfig + .dts / config fragments for BCM6813

Reference build
---------------
The working asuswrt-merlin build lives in ../../../gt-be98-firmware. Use it as the
source of truth for: kernel config, the .itb/.pkgtb image format, wlan firmware
(rtecdc.bin for 6717a0/6726b0), nvram defaults, and the required-component list
(tools/verify-artifact.sh).
