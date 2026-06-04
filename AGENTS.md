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
mkimage now comes from Buildroot's host-uboot-tools (merlin only lends the bootfs
`.itb`). HONEST limits: not boot-tested on hardware; kernel/ATF/U-Boot reused
prebuilt (Step 2b deferred — needs Broadcom build wrapper).

**Steps 3-4 IN PROGRESS — userspace landing in the image:**
- Generic (upstream Buildroot pkgs): openssl, cjson, lighttpd, openvpn, dropbear,
  strongswan (charon/stroke). NB **samba4 won't build** with the gcc-10.3 external
  toolchain — its dep cmocka 2.0.2 uses `__attribute__((access(none)))` (GCC 11+).
  This is a general constraint: modern upstream pkgs needing GCC 11+ fail; get
  smbd (and similar) from the ASUS blob instead.
- Proprietary (gt-be98-packages blobs + recipes, fetched by URL+hash):
  - `gt-be98-dhd-firmware` — rtecdc.bin (6717a0/6726b0) -> /rom/etc/wlan/dhd.
  - `gt-be98-userspace-base` — nvram, rc, wl, dhd, httpd + their 34-lib ASUS
    shared-lib closure -> /bin,/sbin,/usr/sbin,/lib,/usr/lib. Verified the
    dynamic-link closure is COMPLETE in the rootfs.
  Blob pattern: `gt-be98-packages/scripts/package-blob.sh` (reproducible tar) ->
  Release asset -> recipe `_SITE`/`.hash`. Tarballs staged locally in `dl/`;
  Release uploads pending (needs the user / no gh CLI).
- Still TODO for functional parity: init/rc wiring, nvram defaults, /www web UI
  assets, wl/dhd config, service start scripts.

- `external.desc` (name `GT_BE98`), `external.mk`, `Config.in` — wired.
- `configs/gt-be98_defconfig` — arch/ABI **confirmed from the real compiler**:
  `BR2_arm` + `BR2_cortex_a9` + `BR2_ARM_EABI` + `BR2_ARM_ENABLE_VFP` +
  `BR2_ARM_FPU_VFPV3`, external glibc 10.3/2.32/hdr-4.19, `INET_RPC` disabled.
  Toolchain SOURCE intentionally left unset (pick URL or PATH locally — see file).
- `board/gt-be98/` — post-build/post-image **placeholders** (no-ops).
- `package/README.md` — recipe template referencing `gt-be98-packages` Releases.

### How Step 1 was built / reproduced
- Buildroot upstream cloned at tag **2026.02.2** (latest stable LTS) in
  `~/be98/buildroot`. The external toolchain (gcc10.3/glibc2.32/hdr4.19) is
  consumed as-is regardless of Buildroot version; 2026.02 still offers
  `BR2_TOOLCHAIN_EXTERNAL_HEADERS_4_19`. The defconfig is **version-portable** —
  it built unchanged on both 2021.02.4 and 2026.02.2.
- Build it via a LOCAL test defconfig that appends
  `BR2_TOOLCHAIN_EXTERNAL_PATH=<firmware's extracted crosstools-arm_softfp dir>`
  (the firmware repo already extracts the toolchain), then `make defconfig && make`.
- On modern Buildroot the host tools build cleanly on Debian 13 (host-fakeroot
  1.37 — no patch). (An older Buildroot like 2021.02 needs a fakeroot bump to
  build on glibc 2.41; avoided by using latest stable.)

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
with our rootfs.

**Step 2b (investigated → DEFERRED).** Building the aarch64 kernel from source is
NOT a standard Buildroot kernel package: a bounded `make ARCH=arm64 olddefconfig`
test fails at Kconfig (`../bcmkernel/Kconfig.bcm_kf.4.19.294`), and the build
consumes dozens of env vars from `build/Bcmkernel.mk` pointing into bcmdrivers/RDP
SDK. Building it means vendoring a large Broadcom subtree + wrapping their build
system (multi-day) for NO functional gain over the prebuilt `.itb` we already
reuse. Keep reusing the prebuilt `.itb`; revisit only if from-source becomes a
hard requirement. (The aarch64 toolchain works: gcc10.3, `aarch64-buildroot-linux-gnu-`.)

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
