# GT-BE98 IO-coherency BENCH image (D31) — bench only, never a release

The design, the safeguards and how NAND is kept out: open-wifi `docs/re/RE-2026-11-09-IO-COHERENT-PCIE.md` and
`docs/re/RE-2026-11-09-COHERENT-BENCH-IMAGE.md`. This branch (`br-cohbench-2026-11-10`, off img39 `0a1bbcf`) records
the bench as a Buildroot recipe:

- `gt-be98-open-ethernet.mk`: open-ethernet `oe-cohbench-2026-11-10` (= img39's `a9960de` + `series.coh-bench`:
  0990 Normal memory outer shareable, 0991 BCM6813 root complex IO-coherent when its node is `dma-coherent`), the
  series appended after `series.pcie`.
- `post-image.sh`: `COH_BENCH=1` (local conf) adds `dma-coherent` + `brcm,ubus-master/cci/cci-cpu-si` on `&pcie0..3`
  and `dma-coherent` on `&runner` (`ML_DMA_COHERENT`). It refuses `COH_BENCH=1` unless `NAND=off` or `NAND=ro`,
  `IMAGE=netroot` and not a release, so a coherency bench never carries a writable NAND, and its NAND node (if any)
  is never `dma-coherent`.
- `conf.d/gt-be98-drivers`: `cci_snoop=1` in `RUNNER_ARGS`, so the Runner, coherent in the bench DT, enables the CPU
  snoop itself even if no root complex came up.

`build-coh.sh` is what produced the bench image on dev-build: a second 14 GB Buildroot output does not fit there, so
it rebuilds only what differs from img39 — the kernel (img39's `.config`, the bench series), every module against it,
img39's rootfs with `/lib/modules` replaced and `cci_snoop=1`, the DTB with the overlay above, the FIT — and writes
`~/orch/os/img-coh-ro`.

**NAND=ro (variant 2, after q164).** The first bench image (`NAND=off`) could only fetch its rootfs over the
USB-Ethernet lifeline, which no img39 boot ever used, and it died unobserved: its console is netconsole, a rootfs
service sent through the Runner, so a boot that never reaches the rootfs sends nothing. Variant 2 reads its own
rootfs from slot 1's UBI vol 4 as img39 does (read-only attach, copy to RAM, sha256 against the value built into
the initramfs; `flash_dir` writes vol 4), with every NAND partition read-only in the DT. `ROOTFS_URL` (`/os-coh/`)
is kept only as the fallback.

**Observing a failed boot without the network.** The be98pc post-code byte, `0xff802628[31:24]`, survives the
watchdog reset into stock (open-ethernet `re-notes/realhw/203-mainline-boots.md`, stage 0b); `flash_dir` clears it
to 0x00 before the trial boot. Read it on stock BEFORE anything boots slot 1 again: `0x00` the kernel never
registered its earlycon; `0x01..0xbf` the kernel ran but no milestone; `cd` died inside 0991's coherency setup;
`ce` setup done, died before `/init`; `c0..` `/init` codes (`db`/`dc` vol 4 read, `eb` sha mismatch, `e9`/`ee`
no rootfs source); `f1..f3` switch_root; `f4` watchdog daemon, `f5` dhcpcd, `f6` sshd, `f7` Runner loaded (`e7`
insmod failed), `fa` default runlevel, `fb` healthy, `fd` unhealthy (petting stopped).
