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

### Why toolchain/packages are NOT git submodules

They're consumed **by URL**, not as submodules, and this is deliberate:

- Buildroot's external-tree model fetches the toolchain (`BR2_TOOLCHAIN_EXTERNAL_URL`)
  and each package source (`<PKG>_SITE` + `<PKG>_HASH`) as **tarballs-by-URL with
  hash verification** — it never builds from a submodule checkout.
- The buildroot external tree is **recipes only / small text** (its `.gitignore`
  blocks `*.tar*`, `*.bin`, `*.o`). Submoduling the 423M LFS toolchain and the
  proprietary blob repo would drag hundreds of MB of binaries into every clone and
  CI run — exactly what the repo split (and the Releases-over-LFS move) avoids.
- `docs/device` **is** a submodule because it's the opposite case: small shared
  **text** docs, pinned and read in-tree, identical across the family.

For a one-shot dev checkout of the whole family, use a separate umbrella repo (all
family repos as submodules) rather than submoduling into the recipe tree.

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

## Step 1 status + Step 2b — kernel build: detailed plan

**Step 1 (external toolchain): DONE.** Both variants are published as
`gt-be98-toolchain` Release assets and consumed by URL:
`arm_softfp-gcc10.3` (userspace, prefix `arm-buildroot-linux-gnueabi`) and
`aarch64-gcc10.3` (kernel, prefix `aarch64-buildroot-linux-gnu`, sha256
`ffde9b4c…ed7e`). The `gt-be98-kernel` repo already builds the kernel against the
aarch64 Release end-to-end: `TC_FROM_RELEASE=1 scripts/build-kernel.sh kernel`
fetches it (`scripts/fetch-toolchain.sh`) and forces `KCROSS_COMPILE` onto it —
verified to produce a fresh GT-BE98 aarch64 Image (with kprobes), kernel-space
only (the SDK `recipe_kernel` phase; `userspace` not run).

### The hard part of Step 2b
The GT-BE98 kernel is **not** a stock `make defconfig && make`. `BCM_KF=y`
compiles **bcmdrivers into the kernel** (`brcmdrivers-y`), needs bcmkernel headers
(`-I .../kernel/bcmkernel/include`), the merlin kbuild vars (`BCM_KF`,
`BRCM_CHIP=6813`, `LINUX_VER_STR=4.19.294`, `MODEL=GTBE98`), and the **closed
prebuilt `.o`** (bpm/cmdlist/wl/dhd…). Of the 196 `CONFIG_BCM_*`: 68 `BCM_KF_*`
are core-kernel patches (intrinsic), 94 are `=y` platform/accel drivers (in
vmlinux), only 34 are `=m` modules. So Buildroot's stock `linux` package cannot
express this build.

### Approaches
- **A — custom `linux` package** replicating the merlin kbuild (most BR-native;
  must encode all the BCM glue).
- **B — thin wrapper**: Buildroot drives the merlin kernel build (`recipe_kernel`)
  with BR2's external toolchain (pragmatic; "reuse merlin initially").
- **C — decoupled**: `gt-be98-kernel`'s `build-kernel.sh kernel TC_FROM_RELEASE=1`
  runs as a post-step; Buildroot owns userspace/rootfs only (cleanest given the
  kernel can't be stock-Buildroot). **Already working today.**

### Inputs to move into gt-be98-packages
bcmdrivers + bcmkernel + the closed prebuilt `.o` (bpm/cmdlist/wl/dhd/`rtecdc.bin`)
+ the kernel-source delta (`gt-be98-kernel`'s `patches/` + `overlay/`). Currently
sourced ad-hoc from `~/re-sdk`; package as Release blobs.

### Milestones — status (2026-06-24)
1. **Foundation** ✅ — upstream Buildroot 2026.02.2 + `BR2_EXTERNAL=$(this repo)`
   + `gt-be98_defconfig` + the published `arm_softfp` external toolchain builds a
   busybox+base ARM rootfs (proven; busybox is ELF ARM EABI5).
2. **Blobs** ✅ — all 4 `gt-be98-packages` Release assets live (`bootfs-0031`,
   `dhd-firmware-1.0`, `userspace-base-1.0`, `samba-1.0`); the full
   `gt-be98_defconfig` build produces a 27M flashable `.pkgtb` (= **Step 2a**:
   Buildroot rootfs + prebuilt bootfs).
3. **Kernel from source (Step 2b)** ✅ *integration proven* — `gt-be98-kernel`
   builds the kernel against the external aarch64 toolchain
   (`TC_FROM_RELEASE=1 build-kernel.sh full` → bootfs `.itb`), and
   `scripts/step2b-pkgtb.sh <bootfs.itb>` wraps Buildroot's rootfs around it via
   the `GT_BE98_BOOTFS_ITB` override (prebuilt `gt-be98-bootfs` disabled). Verified:
   the pkgtb's embedded bootfs sha = the from-source bootfs, not the prebuilt.
   TODO: a lightweight kernel→FIT-only target (standalone merlin `image_linux`
   needs the full `IMAGE_GOAL`/`BCM_FLASH_LAYOUTS` context) so we don't run `full`.
4. **Image** ✅ — `board/gt-be98/post-image.sh` bundles the `.pkgtb` (bootfs `.itb`
   + Buildroot `rootfs.squashfs`) with the u-boot `mkimage`, reproducing the merlin
   bundle; emits bootfs-FIT + rootfs-squashfs + combined pkgtb.
5. **Parity** ⏭ — boot the BR-built kernel on slot1; diff vs the merlin artifact.

### Risks
Closed-prebuilt ABI tie to the exact kernel; extent of the merlin kbuild glue;
reproducing the ITB/pkgtb format. Keep `gt-be98-firmware` as the reference until
parity.
