# GT-BE98 mainline OS 1.0-rc14 - release notes

Date: 2026-11-25 · Status: **release candidate 14**, tagged `gt-be98-rc14`.

Evidence is named by the orchestrator's queue (`qNNN`). The run directories
stay on the orchestrator's machine and are not in this repository. Every
number comes with the run that measured it, and "not measured" never means
0. Lab image `imgint15a` is the lab-mode build of the RC14 sources (same
commits, lab keys). The release images below are the `RELEASE=1` build of
those sources.

RC14 on top of RC13, in short:

- **Zero-wait DFS at 80 MHz, with a 40 MHz standby (opt-in).** An 80 MHz
  access point on the 5 GHz-high radio keeps a narrower 40 MHz channel
  cleared in the background. After a radar it moves there without
  stopping, and once the radar ban on its own channel ends it moves back
  to 80 MHz, again without stopping. The default is unchanged: zero-wait
  stays off.
- **Radar-ban fixes.** The end of the radio firmware's own radar ban is no
  longer mistaken for a new radar, so a channel is no longer banned a
  second time for nothing. A background check started while the access
  point was still coming up is no longer lost.
- **Networks are objects of their own.** A network has its own bridge,
  several Wi-Fi names (SSIDs) can share one network, and the box's own
  addresses and services (admin page, SSH, DHCP, RADIUS) are set per
  network.
- **Detect VLANs on a wired port.** The web UI can listen on a jack for a
  short time, list the VLANs it sees there and add one as a network.
- **The radio environment (Frequencies page).** How busy each channel is,
  the Wi-Fi networks nearby, and a scan that does not drop connected
  clients.
- **Client Wi-Fi and Multi-AP backhaul.** A Wi-Fi uplink that cannot be
  bridged falls back to an unbridged connection that still carries the
  box's own traffic. A wired network can be extended through a Multi-AP
  backhaul station.
- **Safer admin changes.** SSH answers on every address while no SSH row is
  set, and the web UI refuses a change that would cut the admin page or SSH
  from the address the request came from.

## Images

| File | sha256 |
|---|---|
| `rootfs.squashfs` | `9390ebb7796cf51f97b66498d45f8267c3d813a25e20425854097a87fdf4beb2` |
| `ml-bootfs.itb` | `0d64b1f63609b853b785b9d3086705bb2e4bf58802d44f61a9a9e733313e2378` |

Build id (DT): `20261125T142640Z-775c11c59a57-rw-jffs`

Built with `RELEASE=1` (`ml-bootfs.info`: `release mode: yes`) from
`br-rc14-r-2026-11-25` `74b3505`. Later commits of that branch change only
`docs/`.

- **Release check:** `release-check.sh` returned PASS (selftest 21/21) with RC7's lab-pattern list.
- **Lab control:** the lab image imgint15a fails the same check with 15 findings, as it should.
- **Exact-pattern list:** finds only the lab public key, as in RC7–RC13.
- **Modules against the tested lab image (imgint15a)**, checked by the
  release recipe's section gate (`kocmp.py`, the rule RC12 accepted):
  - `rtl8372.ko` is byte-identical (`7010af97`).
  - `bca_pcie_ipc.ko` (release `9d744e89`, lab `088cd0d2`): 34 of 37
    sections byte-identical.
  - `bcm4916-runner.ko` (release `4a6aa3d5`, lab `c000a45b`): 38 of 41
    sections byte-identical.
  - In both, every code and relocation section is identical, `.rodata` is
    identical once the build-path prefix is swapped, `.symtab` differs only
    in `.rodata` symbol values, and the build-id follows.
- **The rest of the rootfs against imgint15a**, file by file: hostapd, the
  web UI, the Wi-Fi generator and every OS script are byte-identical. The
  release image has no SSH host keys and no web UI password file (7 fewer
  entries), the lab test key, and `release-mode yes`. Other userland
  binaries differ only in layout: Buildroot replaces the build path in them
  by padding of the same length, and the release build directory's path
  has a different length from the lab one.

**These images are a TEST build.** Their `SSH_AUTHORIZED_KEYS` is the
lab's public key, so they are never handed over. A hand-over build is the
same sources with the recipient's keys, checked again with
`release-check.sh`. The images contain no SSH host keys, no web UI
password and no rootfs URL. They contain proprietary vendor firmware, so
they are handed over privately and never published (`docs/RELEASE-BUILD.md`).

Lab image imgint15a: `rootfs.squashfs`
`dc3ef97cdbf225ac0b702642db899a92285bb70edcfc4f55e631248c75c6d736`, build id
`20261125T022617Z-6522da1ad5ad-rw-jffs`. File by file (1764 entries each),
imgint15a differs from imgint14d (the image of the network-object, radio
environment and Detect VLANs tests) in exactly:
- `/usr/sbin/hostapd` (`9b7d4d53` → `fefda460`, patch `0005`; byte-identical
  to the hostapd of the zero-wait lab test q402);
- the Wi-Fi module `bca_pcie_ipc.ko` (`fdab2e7a` → `088cd0d2`, the shipped
  build of open-wifi `b3a483c1`, reproduced byte for byte from that commit);
- `/etc/gt-be98-release`.

Built from (`gt-be98-rc14` tags):

| Component | Commit |
|---|---|
| gt-be98-buildroot | `br-rc14-r-2026-11-25` = `br-int15a-2026-11-25` `f81f430` (= `mainline-os` `ec2f79c` (`gt-be98-rc13`) + the network objects, services on addresses, client Wi-Fi fallback, Multi-AP backhaul, radio environment, Detect VLANs, hostapd `0005`, and the open-wifi / open-ethernet pins) + these notes |
| open-wifi (`bca_pcie_ipc.ko`) | `om-zw80-int-2026-11-24` `b3a483c1` (= RC13's `0a7588d3` + RFSCAN + ZW-ARM-UP + DFS-NOP-END); module `088cd0d2` |
| open-ethernet (Runner, kernel series, `rtl8372.ko`) | `oe-detect-2026-11-23` `ba2aae8` (= RC13's `c56b79b` + RTL8372 jack_detect); Runner module `c000a45b` (unchanged), switch module `7010af97` |
| web UI (gt-be98-webui-go) | `wu-int14d-2026-11-24` `3009db2` (= RC13's `8dacddf` + networks as objects, addresses and services, radio survey/scan, Detect VLANs) |
| hostapd | 2.12 with the local patches `0001`–`0004` and, new, `0005` |
| Linux / Buildroot | 7.2.9 / 2026.08 (kernel configuration unchanged since RC7) |

**Shipped Wi-Fi driver parameters:** 36, unchanged. No module parameter
was added; the open-wifi gates on `b3a483c1` are GREEN.

## Changes since RC13

### Zero-wait DFS at 80 MHz with a 40 MHz standby (hostapd `0005`, open-wifi)

**The problem.** In Europe (ETSI) every 5 GHz-high channel needs a radar
check before use. RC13's zero-wait mode keeps a second channel checked in
the background so the access point can move there after a radar without
stopping. At 80 MHz on channel 100 there is no second clean 80 MHz block
on that radio, so RC13 could do zero-wait only at 40 MHz.

**Now.** An 80 MHz access point keeps a **40 MHz standby** checked in the
background (channel 132, never a weather-radar channel). After a radar on
its 80 MHz channel it moves to the standby at 40 MHz without stopping.
When the 30-minute radar ban on its own channel ends, it checks that
channel again in the background (the 6-minute ETSI minimum) and moves back
to 80 MHz, again without stopping. A way back that the radio refuses is
retried every 30 s, at most 20 times.

**Opt-in, default unchanged.** Zero-wait stays **off** by default in ETSI
(the owner's decision): the generator switch `zwetsi5gh` is 0, as in RC13.
With `zwetsi5gh=1` and the radio's `zwdfs=1`, the generator writes the
background radar on the 5 GHz-high radio with channels 100–112 and 132–136.

**Tests.** `hostapd-dfs-bg-test` (the scenario on the radio's own channel
table) is GREEN on `0005`, and RED on each earlier revision of the patch.
`gt-be98-wifi-gen-test`: 1961 checks, including the zero-wait cases.

**Box evidence**
- q402 (imgint14d + the lab hostapd, the same binary as RC14's): W1 and W2
  PASS.
- **q415 (imgint15a, its own hostapd; the radar injected with the bench
  build of the same open-wifi commit):**
  - W1 PASS: the standby cleared in 360.2 s; radar → move to 5660 MHz
    (40 MHz) in 0.6 s; never stopped (395 samples, all serving);
  - W2 PASS: one attempt, back at 80 MHz on 5500 MHz after the 6-minute
    background check; no unrequested radar; never stopped (2638 samples).

### Radar-ban fixes (open-wifi `b3a483c1`)

- **DFS-NOP-END.** The radio firmware keeps its own radar ban of 31
  minutes (1860 s) and reports its end with the same event as a radar.
  The driver reported it as a radar, so a channel whose ban had just ended
  was banned again for another 30 minutes, and the way back to 80 MHz
  failed. The driver now recognises the end of the ban and does not report
  it. Seen on the box in q415 W2: the end of the ban at +1862 s, handled,
  no new radar.
- **ZW-ARM-UP.** At start-up the background check was requested while the
  access point was still being brought up, and the radio refused it. It is
  now armed only once the access point is up.

### Networks as objects; addresses and services per network (OS, web UI)

- One bridge per network (`gt-be98-net`); several SSIDs can share a
  network; unknown settings are kept.
- The box's own addresses (`gt-be98-addr`) and services (admin page, SSH,
  DHCP, RADIUS) are rows of their own, per network.
- SSH answers on every address while no SSH row is set. The web UI refuses
  a change that would cut the admin page or SSH from the address the
  request came from (unless the request confirms it).
- **Box evidence:** netobj arm r7: 11/11 PASS (q363, q367, q415).

### Client Wi-Fi fallback and Multi-AP backhaul (OS)

- A client Wi-Fi uplink that cannot be bridged after 60 s is taken out of
  the bridge and carries the box's own addresses; it is bridged again after
  600 s.
- `wds=1` on a network makes it a Multi-AP backhaul (the device behind a
  backhaul station gets its lease and reaches the wired network).
- **Box evidence:** netobj r6/r7 cell W PASS (q363, q367).

### Detect VLANs on a wired port (open-ethernet, OS, web UI)

- On a jack of the RTL8372 switch, "Detect VLANs" opens a time-boxed
  window, lists the VLANs seen and offers "Add as network". The switch is
  restored at the end, on a stop, a timeout, a profile change, a module
  unload, and after a reboot in the middle of a detection.
- **Box evidence:** netobj-detect r2 S D X R PASS (q367, q415): the table
  written in 2.3 s, restored in 5.4 s.

### The radio environment (Frequencies page) (open-wifi, OS, web UI)

- The channel survey splits a channel's receive time (our own network
  vs others); a scan runs one channel at a time so connected clients stay
  connected; `gt-be98-rfscan` refreshes one channel every 30 s.
- **Box evidence:** rfscan arm PASS on every band (q358, q367, q424):
  0 disconnects during scans.

## Box evidence (imgint15a unless noted)

| Queue | Image | Result |
|---|---|---|
| q363 / q367 | imgint14c / imgint14d | network objects r7 11/11 PASS; Detect VLANs S D X R PASS; rfscan PASS |
| q402 | imgint14d + lab hostapd | zero-wait 80 MHz W1, W2 PASS |
| q415 | imgint15a | zero-wait W1, W2 PASS on the image's hostapd; network objects, Detect VLANs, fixed primary, UI degraded-apply, WIFISTOP PASS; L1 radio cycles clean; its client-dependent steps VOID (a lab-client fault, re-run in q424) |
| q423, q425 | imgint15a | perf smoke NO-REGRESSION (5 GHz-low down 750–761, 6 GHz down 1430 Mbit/s) |
| q424 | imgint15a | rfscan PASS; L1 2 cycles clean; WIFISTOP PASS; soak DRY-OK; **30-minute RC14 soak VERDICT PASS** (0 unplanned disconnects; client traffic medians 84.6 Mbit/s on 5 GHz-low and 17.1 Mbit/s on 2.4 GHz, 29 minutes each; M1 1359 → 1351 MB, first-10 vs last-10 −1.4 MB, SUnreclaim flat; load max 0.55); clean, CHECK and baseline PASS |
| q426 | release | **Release-image phases PASS:** first 16/16, with W2b-BIND: the LAN address bound 0 s after the arm looked, uptime 55.3 s, and every gated action answered need_auth on loopback and the LAN. Second 6/6: host keys kept across the reboot, setup token consumed, still configured. The lab image imgint15a restored afterwards (build `20261125T022617Z-6522da1ad5ad-rw-jffs`, release-mode no) |

## Known open

- **MLO** is not in RC14. It is a separate driver build under test.
- **Zero-wait DFS is off by default** (above).
- **Plain 4-address Wi-Fi clients** cannot be bridged (the radio never
  reports them); use a Multi-AP backhaul station.
- Carried over from RC13: RUNNER-L3-FDB-Q1, the RC11 q305 cores/Gbit dip,
  band steering limited by the client, the untested 1G/10G ports, WPS
  overlap detection unproven, IO-coherent PCIe bench-only, the web UI
  `go test -race` isolation issue, hostapd patches `0002`–`0005` not
  reported upstream.
