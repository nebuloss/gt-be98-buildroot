# Agent handoff — gt-be98-buildroot

You're working in the **Buildroot external tree** that will replace the
asuswrt-merlin SDK build. Read `ARCHITECTURE.md` first.

## State (2026-06-04)

**Step 1 DONE & verified** — the external toolchain builds a minimal busybox
glibc rootfs with the exact merlin target ABI (ARMv7-A cortex-a9, EABI softfp,
VFPv3, glibc 2.32, interp `/lib/ld-linux.so.3`).

**Step 2a DONE (packaging pipeline)** — `make` now also produces
`output/images/GT-BE98_nand_squashfs.pkgtb`: `board/gt-be98/post-image.sh` wraps
Buildroot's `rootfs.squashfs` with a prebuilt bootfs `.itb` (ATF+U-Boot+aarch64
kernel+dtbs+OP-TEE, borrowed from the sibling merlin tree) via u-boot `mkimage`,
reproducing merlin's exact bundle FIT. Verified structurally: all metadata tokens
present, squashfs magic once, embedded rootfs byte-identical, `dumpimage` parses.
HONEST limits: not boot-tested on hardware; the rootfs is still busybox-only
(userspace parity = Steps 3-4); the kernel/ATF/U-Boot are reused prebuilt, not
yet Buildroot-built (Step 2b). Blobs currently come from the merlin tree — should
move to gt-be98-packages Release assets.

- `external.desc` (name `GT_BE98`), `external.mk`, `Config.in` — wired.
- `configs/gt-be98_defconfig` — arch/ABI **confirmed from the real compiler**:
  `BR2_arm` + `BR2_cortex_a9` + `BR2_ARM_EABI` + `BR2_ARM_ENABLE_VFP` +
  `BR2_ARM_FPU_VFPV3`, external glibc 10.3/2.32/hdr-4.19, `INET_RPC` disabled.
  Toolchain SOURCE intentionally left unset (pick URL or PATH locally — see file).
- `board/gt-be98/` — post-build/post-image **placeholders** (no-ops).
- `package/README.md` — recipe template referencing `gt-be98-packages` Releases.

### How Step 1 was built / reproduced
- Buildroot upstream cloned at tag **2021.02.4** in `~/be98/buildroot` (matches
  the toolchain's own Buildroot version).
- Build it via a LOCAL test defconfig that appends
  `BR2_TOOLCHAIN_EXTERNAL_PATH=<firmware's extracted crosstools-arm_softfp dir>`
  (the firmware repo already extracts the toolchain), then `make defconfig && make`.
- **Host-tool fix required** on Debian 13 (glibc 2.41/gcc 14): host-fakeroot
  1.25.3 won't compile → bumped the clone's `package/fakeroot` to **1.31** with
  `AUTORECONF=NO` and patches removed. This patch lives in the Buildroot clone,
  not here (recipes-only). A 2021 Buildroot on a 2025 host may need more such
  fixes; if they cascade, consider a modern Buildroot LTS (the external toolchain
  + custom kernel tarball are version-independent).

### Remaining Step-1 polish (before Step 2)
- Repackage ONE crosstools variant into a Buildroot-download-ready single tarball
  (root = `bin/ lib/ ...`) and upload as a `gt-be98-toolchain` Release asset, then
  set `BR2_TOOLCHAIN_EXTERNAL_URL` in the committed defconfig so it builds without
  the firmware repo present. (Upload needs the user — no `gh` CLI.)

## Step 2 plan (VERIFIED against the merlin artifacts)

Key finding: the architecture is **mixed** — **kernel = aarch64**, **userspace =
32-bit ARM softfp** (`file` on merlin's `vmlinux` = ELF 64-bit aarch64; busybox =
ELF 32-bit ARM). So Buildroot's BR2_arm target is right for the rootfs, but its
normal kernel flow would wrongly build a 32-bit kernel. Defer kernel-from-source.

Image is a **two-layer FIT** (verified via `dumpimage -l`):
- `.itb` (bootfs, 13M) = atf + uboot + fdt_uboot + kernel(lzo,aarch64,@0x200000)
  + many per-board aarch64 DTBs (incl. `fdt_GT-BE98`) + optional OP-TEE.
  **No rootfs in here.**
- `.pkgtb` (74M, the flashable bundle) = loader + bootfs(.itb) + **rootfs.squashfs**.

merlin tooling (under `…/src-rt-5.04behnd.4916/bootloaders`): `build/work/
generate_linux_its`, `build/work/generate_bundle_itb`, `build/work/
fit_header_tool`, `obj/uboot/tools/{mkimage,dumpimage}`; config `build/configs/
options_6813_nand.conf.GT-BE98`. rootfs = `mksquashfs … -noappend -all-root
-comp xz` (v4.0, 128K block, ~61M).

**Step 2a (fastest flashable image):** Buildroot builds ONLY the 32-bit rootfs →
squashfs(xz/all-root); `board/gt-be98/post-image.sh` calls `generate_bundle_itb`
to wrap merlin's **prebuilt** `.itb` + loader (→ gt-be98-packages blobs) around
Buildroot's rootfs → mkimage → `.pkgtb`. Proves the packaging pipeline end-to-end
with our rootfs. **Step 2b (deferred):** build aarch64 kernel + ATF + U-Boot from
source. NB: `generate_*` are Perl with specific args — READ them before wiring
post-image.sh (don't trust second-hand arg lists).

## Reference: the working build

`../gt-be98-firmware` produces a verified `GT-BE98_*.pkgtb` on Debian today
(asuswrt-merlin). It is the source of truth for everything Buildroot must
reproduce. Especially:
- `tools/verify-artifact.sh` — the required-component checklist + image layout.
- `vendor/.../targets/96813GW/` — the real `.itb` / `.pkgtb` / kernel / dts.
- Toolchain facts + the prebuilt cross-toolchain are in `gt-be98-toolchain`.

## Roadmap (do in this order — see ARCHITECTURE.md for detail)

1. **External toolchain works.** Decide the target tuple/CPU for BCM6813 (the
   merlin build is mixed 32/64; primary is `arm-buildroot-linux-gnueabi`, ARMv7
   softfp). Repackage one crosstools dir or use `BR2_TOOLCHAIN_EXTERNAL_PATH`.
   Goal: `make` produces a busybox rootfs with this toolchain.
2. **Kernel + bootloader.** Broadcom 4.19 vendor kernel + ATF/U-Boot + the
   `.itb`/`.pkgtb` packaging. Reuse merlin's tooling from `post-image.sh`.
3. **Wireless.** dhd/wl + `rtecdc.bin` (6717a0/6726b0) as gt-be98-packages.
4. **Userspace.** httpd/web UI, nvram, services, openvpn, samba, lighttpd.
5. **Parity.** Diff against gt-be98-firmware's verified artifact.

## Conventions

- **Recipes only here** — never commit blobs/sources (`.gitignore` enforces).
  Sources/firmware → `gt-be98-packages` Release assets; toolchain →
  `gt-be98-toolchain`.
- Package symbol namespace: `BR2_PACKAGE_GT_BE98_*`; path var
  `$(BR2_EXTERNAL_GT_BE98_PATH)`.
- Keep `ARCHITECTURE.md` identical across the repo family if you edit it.

## Honest scope note

A full Buildroot port of a Broadcom-SDK device is large; the proprietary
kernel/driver/bootloader/image integration is ~80% of the work. Keep
`gt-be98-firmware` as the working product until this reaches artifact parity.
