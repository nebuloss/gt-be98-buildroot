# Agent handoff — gt-be98-buildroot

You're working in the **Buildroot external tree** that will replace the
asuswrt-merlin SDK build. Read `ARCHITECTURE.md` first.

## State (2026-06-04)

A valid-but-empty `BR2_EXTERNAL`:
- `external.desc` (name `GT_BE98`), `external.mk`, `Config.in` — wired.
- `configs/gt-be98_defconfig` — WIP: external toolchain stanza + TODOs for CPU,
  kernel, bootloader, image.
- `board/gt-be98/` — post-build/post-image **placeholders** (no-ops).
- `package/README.md` — recipe template referencing `gt-be98-packages` Releases.

**Nothing builds end-to-end yet.** This is scaffolding.

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
