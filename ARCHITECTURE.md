# GT-BE98 — repo architecture & Buildroot migration plan

_Canonical copy lives in every GT-BE98 repo; keep them in sync._

## Goal

Migrate the GT-BE98 (ASUS GT-BE98, Broadcom BCM6813) firmware build from the
**asuswrt-merlin SDK** (current, working) to a clean **Buildroot** build, with a
maintainable multi-repo layout that separates recipes (text) from blobs (binary).

## The repos

```
gt-be98-firmware     asuswrt-merlin SDK build — patches + scripts. WORKS TODAY.
                     Produces a verified GT-BE98_*.pkgtb on Debian.
                     This is the reference / fallback during migration.

gt-be98-buildroot    BR2_EXTERNAL tree (the migration target). Recipes ONLY:
                     external.{desc,mk}, Config.in, package/*/, board/gt-be98/,
                     configs/gt-be98_defconfig. Pure text, normal PR review.

gt-be98-toolchain    Prebuilt cross-toolchain (Broadcom ARM-HND, minimal 4
                     variants, 423M). Consumed as a Buildroot external toolchain
                     via BR2_TOOLCHAIN_EXTERNAL_URL.

gt-be98-packages     Proprietary / custom package SOURCES + firmware blobs that
                     Buildroot can't fetch from public upstream (wl, dhd
                     rtecdc.bin, web-broadcom_private.o, bcm bootloader bits…).
                     Per-package manifests; tarballs hosted as release assets.
```

### Why split this way (concern + change-rate)

- **Recipes vs blobs.** Buildroot's external tree is small text fetched-by-URL at
  build time; it must not carry multi-GB binaries. Blobs live in the toolchain /
  packages repos.
- **Toolchain** changes rarely (per SDK/gcc bump) and is huge → its own repo.
- **Packages** carry license-encumbered Broadcom blobs → isolated for licensing
  and size.

## Hosting: prefer GitHub Releases over Git LFS

Buildroot downloads sources/toolchains by URL (`*_SITE`,
`BR2_TOOLCHAIN_EXTERNAL_URL`). **GitHub Release assets** are the better fit than
Git LFS: stable immutable URLs, no monthly LFS bandwidth quota (which bites in
CI), no git-history bloat. The toolchain is on LFS today as a bootstrap; migrate
to a Release asset (`scripts/upload-release.sh`). New blobs in gt-be98-packages
should go straight to Releases.

## Toolchain facts (from a full merlin build trace)

Primary tuple `arm-buildroot-linux-gnueabi` — GCC 10.3, binutils 2.36.1,
glibc 2.32, kernel-headers 4.19. Mixed 32/64: `arm_softfp-gcc-10.3` dominates,
`aarch64-gcc-10.3` also used. The 4 bundled crosstools and their invocation
counts are in `gt-be98-toolchain/toolchain/README.md`.

## Migration roadmap (suggested order)

1. **External toolchain first.** Wire `gt-be98-buildroot` to consume
   `gt-be98-toolchain` as `BR2_TOOLCHAIN_EXTERNAL_CUSTOM`; get a trivial Buildroot
   defconfig (busybox + base) to compile & boot a kernel for BCM6813. Proves the
   toolchain + target arch.
2. **Kernel + bootloader.** The hard 80%: Broadcom's 4.19 kernel, the bcm
   bootloader/ATF, and the `.itb`/`.pkgtb` image format. Reuse merlin's prebuilt
   ATF/U-Boot + ITB packaging initially (board/gt-be98/ post-image scripts).
3. **Wireless.** dhd/wl drivers + `rtecdc.bin` firmware (6717a0 + 6726b0) as
   gt-be98-packages blobs. This is proprietary and the riskiest piece.
4. **Userspace.** Port the packages that matter (httpd/web UI, nvram, services,
   openvpn, samba, lighttpd). Many have upstream Buildroot equivalents; the
   asus-specific ones become gt-be98-packages recipes.
5. **Parity check.** Compare against `gt-be98-firmware`'s verified artifact
   (`tools/verify-artifact.sh` is a good checklist of required components).

## Reality check

A full Buildroot port of a Broadcom-SDK device is a large effort; the proprietary
kernel/driver/bootloader/image-format integration is the hard part, not the
userspace packages. Keep `gt-be98-firmware` as the working reference until
Buildroot reaches artifact parity.

## Reference: what a working image must contain

From `gt-be98-firmware/tools/verify-artifact.sh` (clean build, NFS off by default):
busybox, rc (init/services), libc + dynamic linker, wl + dhd + `rtecdc.bin`
(6717a0/6726b0), httpd + web UI, openvpn, samba (smbd), nvram, cjson, lighttpd,
strongswan (charon/stroke); boot chain ATF + U-Boot + kernel + fdt in the ITB;
pkgtb embeds the squashfs rootfs. Target ~74M pkgtb / ~61M rootfs.
