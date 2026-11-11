# GT-BE98 mainline OS 1.0-rc5 - release notes

Date: 2026-11-11 · Status: **release candidate 5**, tagged `gt-be98-rc5`.

Evidence is named by the orchestrator's run directory (`MMDD-HHMM-<arm>`)
or its queue (`qNNN`). The run directories stay on the orchestrator's
machine and are not in this repository. Every number comes with the run
that measured it, and "not measured" never means 0. Image #43 is the
lab-mode build of the RC5 sources: same commits, lab keys. The release
images below are the `RELEASE=1` build of those sources.

## Images

| File | sha256 |
|---|---|
| `rootfs.squashfs` | `75dee9c192e225762a47417241d7636c35b1d5301c0b1b5e0d4501e8061d272e` |
| `ml-bootfs.itb` | `09fbff37ad350c8d31c78577a2ea1411ceb9284d1ee7b8a5119e76267ce80941` |

Build id (DT): `20261111T073816Z-85de8edf22ec-rw-jffs`

Built with `RELEASE=1` (`ml-bootfs.info`: `release mode: yes`), and
`release-check.sh` returned PASS (40 ok / 0 FAIL, selftest 21/21). **These
images are a TEST build**: their `SSH_AUTHORIZED_KEYS` is the lab's public
key, so the orchestrator can run the on-box test. They are never handed
over. A hand-over build is the same sources with the recipient's keys,
checked again with `release-check.sh`. The images contain no SSH host
keys, no web UI password and no rootfs URL. The default Wi-Fi country is
FR. The images contain proprietary vendor firmware: they are handed over
privately and never published (`docs/RELEASE-BUILD.md`).

Lab image #43: `rootfs.squashfs` `1a3b4b4f0de7e09c7ec99551c6a3fa811a6b85b364c78b333bba26b38606ebf9`,
`ml-bootfs.itb` `c9e5a386947d75e8fe6b136a72a7298f2efd9175afaa86c27f8729f0edca0e41`,
build id `20261111T070319Z-c414417e48db-rw-jffs`.

Built from (`gt-be98-rc5` tags):

| Component | Commit |
|---|---|
| gt-be98-buildroot | `211c7ee` (`br-img42-2026-11-11`; merged into `mainline-os`) |
| open-wifi (`bca_pcie_ipc.ko`) | `20ef74c9` |
| open-ethernet (Runner, kernel series, `rtl8372.ko`) | `a9960de` (unchanged since RC4) |
| web UI (gt-be98-webui-go) | `5d1697b`, version string `gt-be98-rc4-4-g5d1697b` |
| hostapd | 2.12 with the local patches `0001` (device-SME Multi-AP) and `0002` (a failed AP MLD ADD keeps the process) - unchanged |
| Linux / Buildroot | 7.2.9 / 2026.08 |

**The web UI is now reproducible.** It is built by the web UI repository's
`tools/build-delivery.sh` (pinned toolchain go1.26.0 and flags; see its
`RELEASE.md`), and the delivery carries a `BUILDINFO`. The binary in both
the lab and release images is `1a46ceca9e5d5d48565065c81ecf84433fc05002af31729d16a8bb1c207846e7`.
Its version string is the one stamped at build time, `gt-be98-rc4-4-g5d1697b`;
a later `git describe` of the same commit returns `gt-be98-rc5`, and would
stamp a different binary. The same script rebuilds RC4's web UI byte for
byte (with RC4's stamp `gt-be98-rc3-6-g370d523`).

The lab driver module is `2158a86c...`; the release image's
(`a72888b8...`) differs only by build path and release build identity.

## Changes since RC4

All found on the box by measurement; each fix verified on the box against
a control that reproduced the defect first.

- **Idle load average 4.0 → 0.05** (open-wifi `20ef74c9`, RXPOLL-IDLE).
  Each radio's `bcawl_rxpoll` thread slept between sweeps with
  `usleep_range()` (TASK_UNINTERRUPTIBLE), so four nearly-idle threads read
  as load 4.00. They now sleep TASK_IDLE; sweep cadence and CPU unchanged
  (rxpoll cores 0.0159 → 0.0158). Run 1111-0409-rxpoll-idle: FIXED, drop
  3.88; image #43 idle 0.05 with 0 threads in D (q185).
- **The Wi-Fi service no longer leaves orphan daemons** (buildroot
  `ee2915f`). A start in which one radio failed returned non-zero, so
  OpenRC marked the service stopped while hostapd and its two supervisor
  daemons kept running; `stop` then did nothing ("already stopped") and
  every supervised retry was refused. A partial failure now leaves the
  service started and reported **degraded**; start, stop and reload share
  one lock; stop and start kill unowned service processes; the supervisor
  holds its reloads while a radio's interface or the driver is absent.
  Control on image #40 reproduced it (1111-0628, CONTROL-AS-PREDICTED);
  fixed on #41/#42 (1111-0635 and q184: PASS, 3/3 stop-during-reload races).
- **A settings change while one radio is degraded is applied** (web UI
  `ebacaf4`). The web UI judged "started" from `rc-service status`'s exit
  code, which is non-zero for a started service with a failed radio; it
  then issued a no-op `start` instead of `reload`, so the change was
  silently dropped and the UI showed Wi-Fi off. It now reads OpenRC's
  started marker, and every Wi-Fi save returns the failed radios as
  warnings. Control on #41 reproduced it; PASS on #42 and #43.
- **Supervisor idle CPU 0.085 → 0.003 of a core** (buildroot `92b3cdd`,
  `c1de00f`): the re-probe watcher and netguard fork nothing in the steady
  state (q182/q184 reprobe-cost: FIXED).
- MLO: R4 steps 2-3, R5-0/R5-1 (first real ML client association) and
  INV-PAGER-RACE (fixed after RC4) are in `20ef74c9`. MLO stays a bench
  feature (D17/D24): not enabled by the product.

## Box evidence (image #43 unless noted)

- Regression: L1 two cycles real 0/0, Wi-Fi stop/restore PASS + restore
  byte-identical, soak DRY-OK, station D1 joins (A/A), UI degraded-apply
  PASS, perf SMOKE: 5 GHz and 6 GHz throughput and CPU within noise
  (6g160 dn 1579 / up 1071 Mbit/s; 5gl80 dn 871 / up 775).
- **180-minute release soak PASS** (q185, `rc5-soak-img43.sh`, identity
  checked: web UI, driver, rootfs volume, build id).
- Release-image box phases: first 15/15 ok, second 6/6 ok (q186).
- Service lifecycle F/S1/S2/S3 and supervision restart PASS (#42).

## Known open

- 2.4 GHz with the RTL lab client is a noisy cell: download/upload swing
  ±10 % between runs of the same image (+13 % / -9 % / -11 % on q182/q184/
  q185). Never gated on alone.
- MLO R5-2 (multi-link AP provisioning) is parked pending an owner decision
  (D36). MLO is not in the product.
- IO-coherent PCIe (D31) stays bench-only (D35).
- Web UI tests: `go test -race` fails on RC4 and RC5 alike (a background
  watcher outlives a test's fake command runner): a test-isolation issue,
  not a product defect; not fixed.
- A config-line failure (as opposed to a radio failure) makes start report
  degraded, but `rc-service gt-be98-wifi status` still exits 0 (no failed
  radio record to list).
