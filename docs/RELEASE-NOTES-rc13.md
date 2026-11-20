# GT-BE98 mainline OS 1.0-rc13 - release notes

Date: 2026-11-20 · Status: **DRAFT**, release candidate 13, not tagged.

> DRAFT. Every `⟨…⟩` is a placeholder: fill it from the named run, or drop
> the line. Do not tag until the regression set, the soak and the
> release-image phases have their rows.

Evidence is named by the orchestrator's queue (`qNNN`). The run directories
stay on the orchestrator's machine and are not in this repository. Every
number comes with the run that measured it, and "not measured" never means
0. Lab image `imgint12e` is the lab-mode build of the RC13 sources (same
commits, lab keys). It is `imgint12b` (the image of the feature session and
the regression set) plus two gt-be98-wan fixes (`imgint12d` carried the
first); see Evidence. The release images below are the `RELEASE=1` build of
those sources.

RC13 is a small candidate on top of RC12:

- **Runner offload of routed IPv6 over the PPPoE WAN**, uplink and
  downlink. RC12 refused these flows, so they stayed on the CPU.
- **Zero-wait DFS on the 5 GHz-high radio in ETSI, as an opt-in.** The
  product default is unchanged (the owner's decision): 80 MHz, zero-wait
  off.
- **The web UI binds a new DHCP address within about 1 s** (RC12: up to
  5 s).
- **Fix: a WAN change drops dhcpcd's stored leases** of the WAN devices the
  OS re-creates, **and the old upstream's delegated prefix**, so a new WAN no
  longer starts from the old network's lease or numbers from its prefix.

## Images

| File | sha256 |
|---|---|
| `rootfs.squashfs` | `⟨release rootfs sha256⟩` |
| `ml-bootfs.itb` | `⟨release itb sha256⟩` |

Build id (DT): `⟨release build id⟩`

Built with `RELEASE=1` (`ml-bootfs.info`: `release mode: yes`).

- **Release check:** `⟨release-check.sh result, selftest n/n⟩` with RC7's lab-pattern list.
- **Lab control:** `⟨the lab image imgint12e fails the same check with N findings⟩`.
- **Exact-pattern list:** `⟨expected: finds only the lab public key, as in RC7–RC12⟩`.
- **Modules against the tested lab image:** `⟨rtl8372 byte-identical; bca and runner: code and relocations identical, .rodata modulo the build path (as RC12)⟩`.

**These images are a TEST build.** Their `SSH_AUTHORIZED_KEYS` is the
lab's public key, so they are never handed over. A hand-over build is the
same sources with the recipient's keys, checked again with
`release-check.sh`. The images contain no SSH host keys, no web UI
password and no rootfs URL. They contain proprietary vendor firmware, so
they are handed over privately and never published (`docs/RELEASE-BUILD.md`).

Lab image imgint12e: `rootfs.squashfs`
`e00ace9d88806a3a7c3b12dcc8091463194ec45506e78696814b287e48a40657`, build id
`20261120T143058Z-bcc596edaa05-rw-jffs`. By a file-by-file comparison:
- **imgint12e vs imgint12d** (`ccd9f396…`, `20261120T112825Z-6665c561333a`,
  the image of q345 and the soak q347) differ only in `/usr/sbin/gt-be98-wan`
  (`27ea112c` → `eec0bf2e`, the second fix) and `/etc/gt-be98-release`.
- **imgint12d vs imgint12b** (`c23168cc…`, `20261119T214556Z-1dc6a6bdb0de`)
  differ only in `/usr/sbin/gt-be98-wan` (`b4db4370` → `27ea112c`, the first
  fix) and `/etc/gt-be98-release`. Against RC12's lab image imgint11, imgint12b's
rootfs differs in:
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
| gt-be98-buildroot | `br-rc13-r-2026-11-20` (= `br-int12b-2026-11-19` `e82b979` + `br-wan-leasedrop-2026-11-20` `48abfc6` and `614cef0` + these notes; imgint12e is built from `614cef0`). `br-int12b` = `mainline-os` `d4cf0a4` (`gt-be98-rc12`) + the open-ethernet pin `c56b79b` + `br-bgcac-hostapd-r2-2026-11-19` `a547ba7` (with `br-bgcac-r2-2026-11-19` `457af66`) + the open-wifi pin `0a7588d3` |
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

### Fix: a WAN change drops dhcpcd's stored leases (OS `gt-be98-wan`)

**The defect (q338).** dhcpcd 10.2.4 keeps one lease file per interface
name (`/var/db/dhcpcd/<if>.lease`, `.lease6`). It removes the file only on a
release or a timeout, so an interface that goes away keeps it. A WAN change
deletes `rnr0.<VID>`, and a later WAN re-creates a device of the same name.
dhcpcd then found the old lease and Rebound it against the new network.
- **An RFC-correct server** ends that at once.
- **A silent one** costs up to 10 s before dhcpcd solicits.
- **q338's** gw5 arm lost its IPv6 address after tagrw's WAN trial on the
  same lab VLAN.

**The fix (`br-wan-leasedrop-2026-11-20` `48abfc6`).** On every change of
the WAN settings (a trial, a revert, an apply with other settings),
gt-be98-wan deletes the stored leases of the old and new WAN devices it
creates (`rnr0.<VID>`, `pppoe-wan`). This happens after the old device is
gone and before the new one exists.
- The same settings applied again keep the lease: a rebind is right then.
- A bare port (`rnr0`..`rnr3`, the management port among them) is never
  touched.

Tests:
- `gt-be98-wan-test`: 267/267 (sh, bash, dash).
- `gt-be98-gw-mutants`: 73/73, including three new lease-drop mutants.

**The second defect (q345, found by the arm's first revision).** gt-be98-wan
also records the delegated prefix per WAN device (`$RUN/pd6`). It cleared
that record only on dhcpcd's expire, release or stop events, and a revert
raises none of them for the VLAN device. So a WAN change that came back to
the same device (`rnr0.30`) still reported the old upstream's prefix.
gt-be98-gw numbered its /64s and RAs from it until the new lease bound, or
up to the prefix's valid lifetime if the new upstream delegates nothing.

**The second fix (`614cef0`).** The recorded prefix is removed together with
the stored leases when the WAN settings change. The same settings applied
again keep it.

Tests:
- `gt-be98-wan-test`: 270/270.
- `gt-be98-gw-mutants`: 74/74, one more mutant.

**Box evidence**
- q345 (imgint12d, the first fix): wan-leasedrop r1 LDF PASS. Its LDR
  REFUTED `b_pd_ok` was the stale prefix above: the second defect, found
  there.
- ⟨q349 (imgint12e): wan-leasedrop r2 LDF + LDR PASS (`SHA_WAN eec0bf2e…`); gw5-ipv6 r13; pppoe6 r3 (the PPPoE WAN path); WAN admin reach⟩

**The soak and the gt-be98-wan delta.** RC13's 30-minute soak ran on
imgint12d (q347). imgint12e differs from it only in gt-be98-wan, which runs
on WAN events only. A soak makes none, so that soak stands for imgint12e, as
RC12's regression set stood for its web UI-only delta.

## Box evidence (imgint12b unless noted)

| Queue | Image | Result |
|---|---|---|
| q329 | imgint10 + bench Runner module | PPPoE IPv6 OS path works; PV6-up offloaded 0.090 cores/Gbit |
| q330 | imgint11 + bench Runner module | PV6-up/dn PASS 0.039 / 0.045 cores/Gbit |
| q336 | imgint11 + bench Wi-Fi module | zero-wait DFS BG PASS: background CAC cleared, AP moved, radar → CSA, never stopped (772 samples) |
| q338 | imgint12b | **Feature session PASS:** W2b, fixed primary, PPPoE IPv6 (shipped module), tagrw r5 (shipped module, D42), zero-wait C0H/BR/BG, perf smoke ⟨numbers⟩. gw5-ipv6 r12: `na_ok` missed, traced to a dhcpcd lease left by tagrw's WAN trial on the same lab VLAN (see Known open) |
| q341 | imgint12b | PPPoE IPv6 PASS again; gw5-ipv6 r13 FULL PASS |
| ⟨qNNN⟩ | imgint12b | ⟨**RC13 regression set** (RC13-REGRESSION-QUEUE.sh): baselines, UI degraded-apply, L1 two cycles, WIFISTOP r2 + RESTORE-OK, soak DRY, perf smoke⟩ |
| q342 | imgint12b | **RC13 regression set PASS:** baselines; UI degraded-apply; L1 real 0/0; WIFISTOP r2 + RESTORE-OK; soak DRY-OK; perf smoke: gated 5gl/6g rows OK, only the 2.4 GHz RTL up row flagged (ungated noise). Its 30-minute soak PASS (M1 −3.2 MB/h); the soak wrapper failed after the run, a harness edit made while it ran |
| q345 | imgint12d | wan-leasedrop r1 LDF PASS, LDR REFUTED (the stale prefix: the second defect); gw5-ipv6 r13 FULL PASS; pppoe6 r3 ship mode PV6-up/dn PASS (0.035 / 0.039 cores/Gbit, CPU path 0.92 / 0.38); WAN admin reach PASS (WAN :80/:22 dropped, path live 5/5, management connected). Its soak: INCONCLUSIVE on M1 (−104.7 MB/h; flat for 15 min, then −97 MB/h; SUnreclaim flat), re-run in q347 |
| ⟨q347⟩ | imgint12d | ⟨**RC13 30-minute soak** after a clean and a 10 min settle, with memory readings⟩ |
| ⟨q349⟩ | imgint12e | ⟨**the second fix, targeted:** wan-leasedrop r2 LDF + LDR, gw5-ipv6 r13, pppoe6 r3, WAN admin reach⟩ |
| ⟨qNNN⟩ | release | ⟨release-image box phases: first n/n, second n/n; lab image imgint12e restored⟩ |

## Known open

**Offload**
- **RUNNER-L3-FDB-Q1** (a design question): when a client's IP moves to
  another host (N), the old host's uplink entry stays on its bridge port
  until `fc_idle_s`. Q1 is whether L3-FDB should drop it at once (q322/q324
  N REFUTED `post_hw_old`). The FDB move (M) passes.
- **The RC11 q305 cores/Gbit dip** is still unexplained. It was not
  reproduced on imgint8 (q307), imgint9 (q309) or in q326's ABA.

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
