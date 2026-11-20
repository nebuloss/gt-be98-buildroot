# GT-BE98 mainline OS 1.0-rc13 - release notes

Date: 2026-11-20 · Status: **DRAFT**, release candidate 13, not tagged.

> DRAFT. Every `⟨…⟩` is a placeholder: fill it from the named run, or drop
> the line. Do not tag until the regression set, the soak and the
> release-image phases have their rows.

Evidence is named by the orchestrator's queue (`qNNN`). The run directories
stay on the orchestrator's machine and are not in this repository. Every
number comes with the run that measured it, and "not measured" never means
0. Lab image `imgint12b` is the lab-mode build of the RC13 sources (same
commits, lab keys). The release images below are the `RELEASE=1` build of
those sources.

RC13 is a small candidate on top of RC12:

- **Runner offload of routed IPv6 over the PPPoE WAN**, uplink and
  downlink. RC12 refused these flows, so they stayed on the CPU.
- **Zero-wait DFS on the 5 GHz-high radio in ETSI, as an opt-in.** The
  product default is unchanged (the owner's decision): 80 MHz, zero-wait
  off.
- **The web UI binds a new DHCP address within about 1 s** (RC12: up to
  5 s).

## Images

| File | sha256 |
|---|---|
| `rootfs.squashfs` | `⟨release rootfs sha256⟩` |
| `ml-bootfs.itb` | `⟨release itb sha256⟩` |

Build id (DT): `⟨release build id⟩`

Built with `RELEASE=1` (`ml-bootfs.info`: `release mode: yes`).

- **Release check:** `⟨release-check.sh result, selftest n/n⟩` with RC7's lab-pattern list.
- **Lab control:** `⟨the lab image imgint12b fails the same check with N findings⟩`.
- **Exact-pattern list:** `⟨expected: finds only the lab public key, as in RC7–RC12⟩`.
- **Modules against the tested lab image:** `⟨rtl8372 byte-identical; bca and runner: code and relocations identical, .rodata modulo the build path (as RC12)⟩`.

**These images are a TEST build.** Their `SSH_AUTHORIZED_KEYS` is the
lab's public key, so they are never handed over. A hand-over build is the
same sources with the recipient's keys, checked again with
`release-check.sh`. The images contain no SSH host keys, no web UI
password and no rootfs URL. They contain proprietary vendor firmware, so
they are handed over privately and never published (`docs/RELEASE-BUILD.md`).

Lab image imgint12b: `rootfs.squashfs`
`c23168cce38e1c9c0f0a99a8838e4b76a9f2d785ef72ef8aaf88517f8a6667b2`,
build id `20261119T214556Z-1dc6a6bdb0de-rw-jffs`. Against RC12's lab image
imgint11 its rootfs differs in:
- `/usr/sbin/webui`;
- `/usr/sbin/hostapd` (patch 0004);
- `/usr/sbin/gt-be98-wifi-gen`;
- the Wi-Fi module `bca_pcie_ipc.ko`;
- the Runner module `bcm4916-runner.ko`;
- `/etc/gt-be98-release`.

The switch module is byte-identical.

Built from (`gt-be98-rc13` tags, ⟨to be set⟩):

| Component | Commit |
|---|---|
| gt-be98-buildroot | `br-rc13-r-2026-11-20` (= `br-int12b-2026-11-19` `e82b979` + these notes). `br-int12b` = `mainline-os` `d4cf0a4` (`gt-be98-rc12`) + the open-ethernet pin `c56b79b` + `br-bgcac-hostapd-r2-2026-11-19` `a547ba7` (with `br-bgcac-r2-2026-11-19` `457af66`) + the open-wifi pin `0a7588d3` |
| open-wifi (`bca_pcie_ipc.ko`) | `om-dfs5gh-bgcac-r2-2026-11-19` `0a7588d3` (= RC12's `main` `38e7be78` + ZW-ETSI); module `c4f7adf3` |
| open-ethernet (Runner, kernel series, `rtl8372.ko`) | `oe-pppoe-v6-2026-11-19` `c56b79b` (= RC12's `effa5fa` + RUNNER-PPPOE-V6); Runner module `c000a45b` |
| web UI (gt-be98-webui-go) | `wu-admin-fastwatch-2026-11-19` `8dacddf` (= RC12's `e338c18` + the 1 s boot watcher) |
| hostapd | 2.12 with the local patches `0001`–`0003` and, new, `0004` |
| Linux / Buildroot | 7.2.9 / 2026.08 (kernel configuration unchanged since RC7) |

**Shipped Wi-Fi driver parameters:** 36, unchanged. The open-wifi gates on
`0a7588d3` against `38e7be78` are GREEN, and the parameter surface is
exactly the committed one.

## Changes since RC12

### Runner offload of routed IPv6 over the PPPoE WAN (open-ethernet `driver/runner`)

**What changed (RUNNER-PPPOE-V6, `afe01f7`..`c56b79b`).** A routed IPv6
flow out of the PPPoE WAN is now built in hardware in both directions
(PPPoE push and pull), instead of refused. Four refusals were fixed:
- the resolver;
- the learner, which saw no Ethernet header on PPP receive;
- the flow builder;
- the command list (`0x0057`), with stock's length fill.

IPv4 over PPPoE (RC11) is unchanged.

**Host tests:**
- `fc_pppoe_test`: 3675 plan checks plus 128 family/geometry checks;
- `xpe_rt_check` and `flow_cmdlist_check`, compared against stock's
  command-list emitter;
- `fc_bind_test`: 30 590 checks.

The shipped module `c000a45b` and the bench module `9be9effa` rebuild
byte-identical.

**Box evidence**
- q329 (imgint10, bench module): the IPv6-over-PPPoE OS path works and the
  uplink is offloaded (PV6-up 0.090 cores/Gbit).
- q330 (imgint11, bench module): PV6-up/dn PASS at 0.039 / 0.045
  cores/Gbit.
- **q338 (imgint12b, the shipped module in the image, no reload): PASS**
  ⟨PV6-up/dn cores/Gbit⟩.
- q341 (imgint12b): PASS again ⟨numbers⟩.
- **No D42 regression from the change:** q338 tagrw r5 on the shipped
  module PASS ⟨GW4 / GW6 cores/Gbit⟩.

### Zero-wait DFS on the 5 GHz-high radio in ETSI, as an opt-in (open-wifi, OS `gt-be98-wifi-gen`, hostapd)

**The owner's decision (2026-11-19).** The 5gh default in ETSI stays
**80 MHz with zero-wait off** (`zwetsi5gh=0`, the shipped default).
Zero-wait DFS is available as an opt-in: `zwetsi5gh=1` together with
`zwdfs=1`. Nothing in the default configuration changes.

**What the opt-in does.** The radio runs a background CAC (the ETSI 6 min
off-channel minimum) on a second DFS channel while it serves on the first.
After a radar it moves with a CSA to a channel already cleared in the
background, so the AP never stops.

**Driver (open-wifi `0a7588d3`)**
- A background CAC is allowed in ETSI on the 5 GHz-high radio, for the
  6 min off-channel minimum.
- A background CAC on a channel cfg80211 already holds as DFS-available is
  refused at the op.
- **ZW-ETSI-WHEEL (q291 BG FAIL root-caused):** the driver aborted a good
  6 min background CAC. Its late read was the timer wheel's rounding, not
  the firmware.

**hostapd patch `0004`.** With no available channel at a cold start,
hostapd 2.12 could not start background radar. `0004` runs a normal CAC
first, then the background chain.

**Generator.** The switch `zwetsi5gh` (default 0) lets `zwdfs=1` write
`enable_background_radar=1` on the 5gh radio in ETSI.

**Box evidence**
- q336 (imgint11, bench module `550c6cf8`), BG:
  - the background CAC cleared at 360.3 s (driver time) and the AP moved
    to the cleared channel;
  - a second background CAC ran, then a radar → CSA onto 5660 MHz;
  - the AP never stopped: 772 samples, all ENABLED.
- **q338 (imgint12b, its hostapd with `0004`; the arm's bench module
  `550c6cf8` = the bench build of the in-image `0a7588d3`): C0H, BR and BG
  PASS.** C0H is the ETSI cold start with no channel available.

### The web UI binds a new DHCP address within about 1 s (web UI)

**RC12's known-open item.** The watcher bound new addresses on its 5 s tick,
so for up to 5 s after DHCP the admin UI did not answer on the new address
(q332).

**Now (`wu-admin-fastwatch-2026-11-19` `8dacddf`)**
- The watcher runs every 1 s from start until the first admin address is
  bound, then every 5 s.
- If no address is bound within the 90 s grace, it drops to 5 s and the
  wildcard fallback fires as in RC12.
- Cost: four `ip` runs per second until the lease, only once per boot.

**Box evidence:** q338 W2b on a normal boot PASS ⟨the logged delay between
rnr0's lease and the listener, in s⟩.

## Box evidence (imgint12b unless noted)

| Queue | Image | Result |
|---|---|---|
| q329 | imgint10 + bench Runner module | PPPoE IPv6 OS path works; PV6-up offloaded 0.090 cores/Gbit |
| q330 | imgint11 + bench Runner module | PV6-up/dn PASS 0.039 / 0.045 cores/Gbit |
| q336 | imgint11 + bench Wi-Fi module | zero-wait DFS BG PASS: background CAC cleared, AP moved, radar → CSA, never stopped (772 samples) |
| q338 | imgint12b | **Feature session PASS:** W2b, fixed primary, PPPoE IPv6 (shipped module), tagrw r5 (shipped module, D42), zero-wait C0H/BR/BG, perf smoke ⟨numbers⟩. gw5-ipv6 r12: `na_ok` missed, traced to a dhcpcd lease left by tagrw's WAN trial on the same lab VLAN (see Known open) |
| q341 | imgint12b | PPPoE IPv6 PASS again; gw5-ipv6 r13 FULL PASS |
| ⟨qNNN⟩ | imgint12b | ⟨**RC13 regression set** (RC13-REGRESSION-QUEUE.sh): baselines, UI degraded-apply, L1 two cycles, WIFISTOP r2 + RESTORE-OK, soak DRY, perf smoke⟩ |
| ⟨qNNN⟩ | imgint12b | ⟨**30-minute release soak** (rc13-soak.sh; identity bca `c4f7adf3`, runner `c000a45b`, webui `c614b060`, hostapd `9b7d4d53`, wifi-gen `f15a7010`, wan `b4db4370`, gw `8e664b6a`)⟩ |
| ⟨qNNN⟩ | release | ⟨release-image box phases: first n/n, second n/n; lab image imgint12b restored⟩ |

## Known open

**Offload**
- **RUNNER-L3-FDB-Q1** (a design question): when a client's IP moves to
  another host (N), the old host's uplink entry stays on its bridge port
  until `fc_idle_s`. Q1 is whether L3-FDB should drop it at once (q322/q324
  N REFUTED `post_hw_old`). The FDB move (M) passes.
- **The RC11 q305 cores/Gbit dip** is still unexplained. It was not
  reproduced on imgint8 (q307), imgint9 (q309) or in q326's ABA.

**WAN**
- **A dhcpcd lease from a previous WAN can survive a WAN change** (q338:
  tagrw's WAN trial left one on the same lab VLAN, and the next arm's
  `na_ok` missed). The IPv6 lane is deciding whether gt-be98-wan should
  clear leases on a WAN change. If it should, that is a gt-be98-wan-only
  change re-checked with targeted arms.

**Wi-Fi**
- **Zero-wait DFS is off by default** (above). A narrower (40 MHz)
  background standby for an 80 MHz zero-wait AP, and the way back, (hostapd `0005`, `br-zw80-2026-11-20`) is in test on
  a separate image (imgint12c) and is **not in RC13**.
- **D36–D40:** MLO on 5 GHz is pending.
- **Band steering** works in the daemon but is limited by the client. The
  lab's MT7925 advertises no 5 GHz operating class (q290/q293
  VOID-NOCAP5). The default stays off.

**Ports**
- The cabled 1G (rnr2) and 10G (rnr3) ports have not carried traffic on
  this OS. Their arms need a cable move.
- 2.5 Gbit/s line rate and more than one cabled jack remain untested.

**Repository hygiene:** older commit messages already on public branches
stay in the history: removing them would need a force push, which is not
done.

**Carried over from RC10–RC12**
- WPS overlap detection is unproven.
- IO-coherent PCIe stays bench-only.
- Web UI `go test -race` has an isolation issue in older tests.
- hostapd patches `0002`, `0003` and `0004` are not reported upstream.
