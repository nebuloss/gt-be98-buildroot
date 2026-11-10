# GT-BE98 IO-coherency BENCH image (D31) — bench only, never a release

The design, the safeguards and how NAND is kept out: open-wifi `docs/re/RE-2026-11-09-IO-COHERENT-PCIE.md` and
`docs/re/RE-2026-11-09-COHERENT-BENCH-IMAGE.md`. This branch (`br-cohbench-2026-11-10`, off img39 `0a1bbcf`) records
the bench as a Buildroot recipe:

- `gt-be98-open-ethernet.mk`: open-ethernet `oe-cohbench-2026-11-10` (= img39's `a9960de` + `series.coh-bench`:
  0990 Normal memory outer shareable, 0991 BCM6813 root complex IO-coherent when its node is `dma-coherent`), the
  series appended after `series.pcie`.
- `post-image.sh`: `COH_BENCH=1` (local conf) adds `dma-coherent` + `brcm,ubus-master/cci/cci-cpu-si` on `&pcie0..3`
  and `dma-coherent` on `&runner` (`ML_DMA_COHERENT`). It refuses `COH_BENCH=1` unless `NAND=off`, `IMAGE=netroot`
  and not a release, so a coherency bench can never carry a NAND node.
- `conf.d/gt-be98-drivers`: `cci_snoop=1` in `RUNNER_ARGS`, so the Runner, coherent in the bench DT, enables the CPU
  snoop itself even if no root complex came up.

`build-coh.sh` is what produced the bench image on dev-build: a second 14 GB Buildroot output does not fit there, so
it rebuilds only what differs from img39 — the kernel (img39's `.config`, the bench series), every module against it,
img39's rootfs with `/lib/modules` replaced and `cci_snoop=1`, the DTB with the overlay above, the FIT — and writes
`~/orch/os/img-coh`. The rootfs is served at the base image's `ROOTFS_URL` with `/os/` replaced by `/os-coh/`.
