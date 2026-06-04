# gt-be98-buildroot

Buildroot **external tree** (`BR2_EXTERNAL`) for the ASUS **GT-BE98** router
(Broadcom BCM6813). The migration target that will replace the asuswrt-merlin SDK
build in `gt-be98-firmware`.

> **Status: skeleton.** This is a valid (empty) BR2_EXTERNAL that `make
> menuconfig` recognizes. The kernel, bootloader, image format, and wireless
> drivers are TODO — the hard part. See **[ARCHITECTURE.md](ARCHITECTURE.md)** for
> the full plan and **[AGENTS.md](AGENTS.md)** for the handoff.

## Repo family

| Repo | Role |
|------|------|
| `gt-be98-firmware`   | Current merlin SDK build — **works today**, reference/fallback. |
| **`gt-be98-buildroot`** | **This repo — the Buildroot external tree.** |
| `gt-be98-toolchain`  | Prebuilt external cross-toolchain. |
| `gt-be98-packages`   | Proprietary/custom package sources + firmware blobs (Release assets). |

## Layout

```
external.desc                 BR2_EXTERNAL name (GT_BE98) + description
external.mk                   includes package/*/*.mk
Config.in                     menuconfig entry (source per-package Config.in here)
configs/gt-be98_defconfig     WIP defconfig (external toolchain wired; rest TODO)
board/gt-be98/                post-build.sh, post-image.sh, rootfs_overlay/, readme
package/                      GT-BE98 package recipes (README has the template)
```

## Use

```bash
git clone https://github.com/buildroot/buildroot
cd buildroot
make BR2_EXTERNAL=/path/to/gt-be98-buildroot gt-be98_defconfig
make menuconfig    # GT-BE98 options appear under their own menu
make
```

## First milestone

Get the **external toolchain** (`gt-be98-toolchain`) accepted and a minimal
busybox rootfs + kernel to compile for BCM6813 — proves toolchain + target arch
before tackling the Broadcom kernel/bootloader/wireless integration.
