# AGENTS.md: gt-be98-buildroot

Operating notes for agents working in this repo. Keep it short and current; it
is not a log. History lives in `docs/journal/` (the June 2026 state log of the
merlin 4.19 work is `docs/journal/2026-06-agents-state.md`).

## What this repo is

A Buildroot `BR2_EXTERNAL` tree (name `GT_BE98`) for the ASUS GT-BE98. It holds
two independent flows:

| flow | defconfig | board dir | status |
|---|---|---|---|
| **mainline OS** (Linux 7.2.9, Buildroot 2026.08, internal GCC toolchain, OpenRC) | `configs/gt-be98_mainline_defconfig` | `board/gt-be98-mainline/` | **active**: the dev OS the open drivers run on |
| legacy merlin 4.19 images | `gt-be98_defconfig`, `_full`, `_fromsrc`, `_openrc-init`, `_pkgtest` | `board/gt-be98/` | dormant; kept buildable as reference |

`board/gt-be98-mainline/README.md` is the real documentation of the mainline
OS (contents, image layout, boot, network, Wi-Fi, persistence, safety rules).
`TESTPLAN.md`, `NAND.md`, `NAND-PHASE2.md` and `PERSISTENCE.md` sit next to it.
The root `README.md` and `ARCHITECTURE.md` describe the original June plan.

## Branches

- The GitHub default branch (`master`) is the June state. Live work happens on
  dated topic branches, `<topic>-<YYYY-MM-DD>`. The build host's `~/os-build/gt-be98-buildroot` checkout shows
  which branch the current OS image is built from.
- One topic per branch. Commit subjects carry the verdict
  (`mainline OS: <what changed and why it matters>`), bodies carry the root
  cause and how it was checked.
- Never force-push, never push to `master`, never `git add -A`.

## Where things build

- **Never build on the dev machine.** All builds run on the build host, through
  `rtk`: `rtk sh board/gt-be98-mainline/build.sh [make targets]`.
- `build.sh` reads the local configuration `$GT_BE98_LOCAL_CONF` (default
  `~/.config/gt-be98-os/local.conf`; template `board/gt-be98-mainline/local.conf.example`).
  It holds every lab-specific value: the Buildroot tree (`BR2_SRC`), the
  output dir (`OUT`), the download cache (`BR2_DL_DIR`), the stock bootfs FIT,
  the vendor firmware dirs, SSH keys, the web UI delivery dir. The filled-in
  copy is never committed.
- Result: `$OUT/images/ml-bootfs.itb`, `rootfs.squashfs` (+ `.sha256`),
  `ml-bootfs.info`. `qemu-smoke.sh` boots the rootfs in QEMU (userspace
  only); `qemu-slot1.sh` and `nand/rehearsal/run.sh` test the slot-1 boot
  and the NAND restore under QEMU + nandsim against a NAND backup on the
  build host (`$BACKUP` / first argument).
- Out-of-tree modules for the box are built against `$OUT/build/linux-7.2.9`
  with `$OUT/host/bin/aarch64-buildroot-linux-gnu-` (exact vermagic).

## What the mainline OS pulls in

| input | how it is pinned | where |
|---|---|---|
| gt-be98-open-ethernet (Runner driver + the kernel series applied to 7.2.9) | commit SHA, `SITE_METHOD = git` (private repo, SSH) | `package/gt-be98-open-ethernet/gt-be98-open-ethernet.mk` |
| gt-be98-open-wifi (`bca_pcie_ipc.ko`) | commit SHA, `SITE_METHOD = git` (private repo, SSH) | `package/gt-be98-open-wifi/gt-be98-open-wifi.mk` |
| web UI (gt-be98-webui-go) | **no pin**: a prebuilt delivery dir (`WEBUI_DIR` in local.conf); the package version is a digest of its files | `package/gt-be98-webui/` |
| vendor firmware (Runner/SerDes, PHY, Wi-Fi `rtecdc.bin`, nvram) | sha256-checked copies from local dirs (`FW_*_DIR`, `STOCK_BOOTFS`); proprietary, never committed | `package/gt-be98-vendor-firmware/` |
| Linux 7.2.9 | tarball sha256 | `board/gt-be98-mainline/patches/linux/linux.hash` |

The web UI binary carries its own source commit: `go version -m webui` (or
`strings webui | grep '^mod'`) names the webui-go revision it was built from.

## Changing a pin

1. Push the driver commit to GitHub first; Buildroot fetches the pinned SHA.
2. Edit `GT_BE98_OPEN_{ETHERNET,WIFI}_VERSION` in the `.mk`.
3. On the build host: `rtk sh board/gt-be98-mainline/build.sh <pkg>-rebuild all`.
   If the open-ethernet pin changes `kernel-patches/mainline`, the kernel must
   be re-extracted to re-apply the series (`linux-dirclean` first).
4. Commit the `.mk` change with the pinned branch name and what it brings.

For driver iteration without a pin, `$OUT/local.mk` can point
`GT_BE98_OPEN_{ETHERNET,WIFI}_OVERRIDE_SRCDIR` at a working tree (build host
only; see the board README). Never commit a build made that way as a pin.

## Kernel config

`board/gt-be98-mainline/linux/linux.config` is **generated, never edited**:
change a fragment (`linux/gt-be98-os.config` or open-ethernet's), then rerun
`linux/gen-linux-config.sh` (its header has the procedure and a `--check`).

## The legacy 4.19 flow

- Consumes GitHub release assets of **gt-be98-packages** (`bootfs`, `rootfs`,
  `dhd-firmware`, `samba`, `userspace-base`; sha256 in each package's `.hash`)
  and the **gt-be98-toolchain** release `arm_softfp-gcc10.3`
  (`BR2_TOOLCHAIN_EXTERNAL_URL` in the legacy defconfigs).
- `gt-be98-{hostapd,libshared,rc}` build from the merlin SDK of a
  sibling checkout, `../gt-be98-firmware` (its ignored `vendor/` tree on the
  build host). Some `board/gt-be98/kernel-cve` and `phase3` scripts still
  carry absolute build-host paths.

## Rules

- **Public repository.** No IP addresses, MACs, user names, host names,
  passphrases, keys, e-mail addresses or firmware blobs in files or commit
  messages. Lab values belong in the local configuration; use `$HOME`/`~`
  paths and placeholders such as `<build-host>`.
- Hardware safety rules of the OS are listed at the end of the board README
  ("Safety rules this OS keeps"); keep them when touching init scripts,
  `devmem`, the watchdog or NAND access.
- `docs/device` is a submodule (gt-be98-docs, public). Its working tree may
  hold untracked local notes: never `git clean` in this repo.
- `rtk` filters output silently. When a count or a file's exact content
  matters, use `python3` or `rtk proxy`.
