# GT-BE98 mainline OS 1.0-rc6 - release notes

Date: 2026-11-13 · Status: **release candidate 6**, tagged `gt-be98-rc6`.

Evidence is named by the orchestrator's run directory (`MMDD-HHMM-<arm>`)
or its queue (`qNNN`). The run directories stay on the orchestrator's
machine and are not in this repository. Every number comes with the run
that measured it, and "not measured" never means 0. Image #44 is the
lab-mode build of the RC6 sources: same commits, lab keys. The release
images below are the `RELEASE=1` build of those sources.

RC6 is RC5 with one change: the Wi-Fi driver (open-wifi) moves from
`20ef74c9` to `4ec3bcd6`. The buildroot content, the web UI, open-ethernet
and hostapd are the same as RC5.

## Images

| File | sha256 |
|---|---|
| `rootfs.squashfs` | `0fda0934c0633f87c14ae814114586d14434b35395bb2d2adfad2cfeb36265ad` |
| `ml-bootfs.itb` | `a6bbe50f6d180eb2ae2b81632f8f6ec3b6e5c847d43b6a50be362a48ce6f3e9c` |

Build id (DT): `20261113T112435Z-e940ffefcc1f-rw-jffs`

Built with `RELEASE=1` (`ml-bootfs.info`: `release mode: yes`), and
`release-check.sh` returned PASS (40 ok / 0 FAIL, selftest 21/21). **These
images are a TEST build**: their `SSH_AUTHORIZED_KEYS` is the lab's public
key, so the orchestrator can run the on-box test. They are never handed
over. A hand-over build is the same sources with the recipient's keys,
checked again with `release-check.sh`. The images contain no SSH host
keys, no web UI password and no rootfs URL. The default Wi-Fi country is
FR. The images contain proprietary vendor firmware: they are handed over
privately and never published (`docs/RELEASE-BUILD.md`).

Lab image #44: `rootfs.squashfs` `f13c2deebc308fcc528c846fd92eefabf9b5ddb3bc7b4bc87b0467de2ae7a56d`,
`ml-bootfs.itb` `39c3c097d58d25491bd0736215609bf5a108bd49a11f11935ac9d8f916babe55`,
build id `20261113T105346Z-a9d702426ed6-rw-jffs`. Its root filesystem
differs from image #43's (RC5's lab image) in exactly two files:
`/etc/gt-be98-release` and the Wi-Fi driver module.

Built from (`gt-be98-rc6` tags):

| Component | Commit |
|---|---|
| gt-be98-buildroot | `1ebc819` (`br-img44-2026-11-13` = RC5's `211c7ee` + the open-wifi pin) |
| open-wifi (`bca_pcie_ipc.ko`) | `4ec3bcd6` |
| open-ethernet (Runner, kernel series, `rtl8372.ko`) | `a9960de` (unchanged since RC4) |
| web UI (gt-be98-webui-go) | `5d1697b`, version string `gt-be98-rc4-4-g5d1697b` (unchanged since RC5) |
| hostapd | 2.12 with the local patches `0001` (device-SME Multi-AP) and `0002` (a failed AP MLD ADD keeps the process) - unchanged |
| Linux / Buildroot | 7.2.9 / 2026.08 |

The web UI is the same reproducible delivery as RC5 (`tools/build-delivery.sh`,
`BUILDINFO`), binary `1a46ceca9e5d5d48565065c81ecf84433fc05002af31729d16a8bb1c207846e7`
in both the lab and release images. Its version string stays
`gt-be98-rc4-4-g5d1697b`: a rebuild uses that string, not a later
`git describe`, or it stamps a different binary.

The lab driver module is `51e84cccb7f2bf63f1ea8c586000a2e29d2208ea2386b5273313d87335c4d129`,
byte-identical to the shipped module run on the box in q198 (SHIP). The release image's (`0dd9f601...`) has the same code and data
(`.text`, `.data`, `.modinfo` identical); it differs only in the build-path
strings of kernel-header warning sites in `.rodata`.

## Changes since RC5

- **A radar or firmware abort early in a DFS channel check no longer leaves
  the 5 GHz radio without an access point** (open-wifi `d9399891`, landed
  as `4ec3bcd6`, DFS-CAC-ABORT-WARN). On a DFS channel (for example 5 GHz
  channel 100) the radio must listen for radar before it may transmit (the
  channel availability check, CAC). When the firmware ended that check
  within the first second (a radar detected right away, or an abort), the
  driver reported it to the kernel before the kernel had recorded that a
  check was running. The kernel logged a warning (`net/wireless/mlme.c:1199`)
  and dropped the event, hostapd's start failed, and the 5 GHz radio stayed
  without an AP until the Wi-Fi service was restarted. The radar was also
  announced as a channel move of a network that had never started. The
  driver now holds the end of the check and the radar report until the
  kernel has recorded the check, then reports them in the kernel's order
  (check aborted, then radar), and the start succeeds once the firmware was
  seen in its check; hostapd then moves to another channel as it should.
  Box evidence (q198, run 1112-1703-dfs-cac-abort): with the abort and the
  radar injected at the same point on bench builds, the control (old
  driver) reproduced the warning and left the radio without an AP; with
  the fix there was no warning, the abort was reported before the radar,
  and the second check on channel 108 (5540 MHz) ended with the AP enabled.
  The shipped module itself (the one in image #44) ran a normal check
  without radar and brought the AP up on channel 100 (5500 MHz).
- **MLO (multi-link) bench progress, not in the product** (open-wifi
  `9cfc9f71` .. `44cd9f97`, MLO R5-2 v2 .. v3-r3). The multi-link AP is
  now provisioned in the firmware in each member radio's down window, and
  the group's MLO start waits for the AP MLD links: the first AP MLD was
  adopted by the firmware and its multi-link element was on the air (q191).
  All of this is compiled only into the bench/group build: the shipped
  driver's executable code is unchanged by it (gate G5). MLO stays a bench
  feature (D17/D24) and is not enabled by the product.

## Box evidence (image #44 unless noted)

- Regression set (q205): L1 two cycles real 0/0, Wi-Fi stop/restore PASS + restore
  byte-identical, soak DRY-OK, UI degraded-apply PASS, idle load 0.29 (0 rxpoll threads in D).
- 6 GHz A/B against the RC5 driver on the same box (q206, interleaved): RC5 1453 / 1446,
  RC6 1455 / 1468 Mbit/s download, no regression. Both read about 1450 against about 1570
  a few days earlier: the drift is the bench (radio environment or client), not the driver.
- 180-minute release soak (`rc6-soak-img44.sh`, identity checked: web UI,
  driver, rootfs volume, build id; and the soak's own networks checked
  deleted, live and in the saved state, at the end): **PASS**, CLEAN-OK (q205).
- Release-image box phases (first / second, build id checked before
  `first`): first 15/15 ok, second 6/6 ok (q206).
- DFS-CAC-ABORT-WARN: q198 CONTROL-CONFIRMS, FIX PASS, SHIP PASS (above).

## Known open

- 2.4 GHz with the RTL lab client is a noisy cell: download/upload swing
  ±10 % between runs of the same image (+13 % / -9 % / -11 % on q182/q184/
  q185). Never gated on alone.
- MLO is not in the product. The R5-2 work resumed after RC5 (owner
  decisions D36/D37/D38: continue) and its bench progress is in this
  driver (above); multi-link client data was first measured on the bench
  after this driver (q201, a later branch, not in RC6). Not a release item.
- IO-coherent PCIe (D31) stays bench-only (D35).
- Web UI tests: `go test -race` fails on RC4, RC5 and RC6 alike (a
  background watcher outlives a test's fake command runner): a
  test-isolation issue, not a product defect; not fixed.
- A config-line failure (as opposed to a radio failure) makes start report
  degraded, but `rc-service gt-be98-wifi status` still exits 0 (no failed
  radio record to list).
- hostapd: a failed AP MLD ADD crashed `hostapd -g` (two NULL dereferences);
  fixed in this image by the local patch `0002` (unchanged since RC5), still
  present upstream; documented in `docs/HOSTAPD-MLD-FAILED-ADD.md`, not
  reported upstream (owner, 2026-11-12). MLD is bench-only.
- Test harness (not the product): the RC5 release soak's networks were found
  again on the lab box after the release phases, although the soak had
  deleted them through the web UI. The RC6 soak deletes them, saves the
  state with the product's own save, and reads both back.
