# GT-BE98 mainline OS 1.0-rc10 - release notes

Date: 2026-11-16 · Status: **release candidate 10**, tagged `gt-be98-rc10`.

Evidence is named by the orchestrator's run directory (`MMDD-HHMM-<arm>`)
or its queue (`qNNN`). The run directories stay on the orchestrator's
machine and are not in this repository. Every number comes with the run
that measured it, and "not measured" never means 0. Lab image "vj2b" is
the lab-mode build of the RC10 sources (same commits, lab keys). The
release images below are the `RELEASE=1` build of those sources.

RC10 is RC9 with three changes:

- **Each 2.5G LAN jack has its own native VLAN.** RC9 put all four jacks
  on one VLAN.
- **Jack ↔ WAN-trunk traffic is hardware-offloaded.** Before RC10 the CPU
  forwarded it.
- **Tagged 802.3/LLC frames are no longer dropped on receive.** This
  includes real spanning-tree BPDUs.

The web UI moves from `0897d1d` to `bb9dc15`, with one row per jack. The
Wi-Fi driver, the kernel configuration and hostapd are the same as RC9.

## Images

| File | sha256 |
|---|---|
| `rootfs.squashfs` | `233c8ab1fb0800dc52495072bcf0718a3f8849ebc08ce557bf1245e210b4815e` |
| `ml-bootfs.itb` | `80c0bc2683683f55799a2ad388436290789f9b3ca1b2570020be254bdbf8744b` |

Build id (DT): `20261116T140019Z-d21ef61389c9-rw-jffs`

Built with `RELEASE=1` (`ml-bootfs.info`: `release mode: yes`).

- **Release check:** `release-check.sh` returned PASS (selftest 21/21)
  with RC7's lab-pattern list.
- **Lab control:** the lab image vj2b fails the same check with 13
  findings, as it should.
- **Exact-pattern list:** finds only the lab public key, as in RC7-RC9.

**These images are a TEST build.** Their `SSH_AUTHORIZED_KEYS` is the
lab's public key, so they are never handed over. A hand-over build is the
same sources with the recipient's keys, checked again with
`release-check.sh`. The images contain no SSH host keys, no web UI
password and no rootfs URL. They contain proprietary vendor firmware, so
they are handed over privately and never published (`docs/RELEASE-BUILD.md`).

Lab image vj2b: `rootfs.squashfs`
`4ccaf52a6550b7388c830229c1a663532ac605c042245243c3c41039417cf27f`,
build id `20261116T111529Z-f453a393ee81-rw-jffs`. It is the image every
RC10 feature arm ran on.

Built from (`gt-be98-rc10` tags):

| Component | Commit |
|---|---|
| gt-be98-buildroot | `7d4676d` (RC9 `eea38b2` + `br-lan-jacks-2026-11-16` + the open-ethernet pin) |
| open-wifi (`bca_pcie_ipc.ko`) | `2456cda8` (unchanged since RC9) |
| open-ethernet (Runner, kernel series, `rtl8372.ko`) | `645237a` |
| web UI (gt-be98-webui-go) | `bb9dc15` |
| hostapd | 2.12 with the local patches `0001` and `0002` - unchanged |
| Linux / Buildroot | 7.2.9 / 2026.08 |

## Changes since RC9

### Per-jack native VLAN (driver `rtl8372`, OS, web UI)

**Configuration and forwarding**
- Each jack has a profile in `/etc/conf.d/gt-be98-lan`:
  `LAN_JACK_<4..7>="native=<vid> tagged=none enabled=0|1"`.
- RC9's single `LAN_PORT_rnr1` line is still read: it means all four
  jacks on that VLAN.
- The RTL8372 switch tags each jack's traffic with its VLAN on the
  internal 10G link to the SoC.
- The OS bridges `rnr1.<vid>` into the network bridge of that VLAN,
  together with its Wi-Fi networks and the WAN trunk `rnr0.<vid>`.
- Jacks on the same VLAN switch directly inside the RTL8372.
- The switch's VLAN table is written as one whole set in a safe order and
  read back.
- Jacks accept untagged frames only, which also matches stock's port
  setting (0x4e10 = 0xaa00).

**Loop guard**
- A BPDU arriving on a jack is counted on its VLAN.
- The switch's address table names the jack it came from.
- That jack alone is blocked at the switch, by STP-disabling it.
- `rc-service gt-be98-lan restart` (the Ports page's "Clear guard")
  clears the block.
- If the lookup fails, every jack on that VLAN is blocked.

**Box evidence (q272):**
- **Cold-boot persistence:** passed.
- **VLAN table:** exact.
- **Jack ↔ Wi-Fi client, same VLAN:** DHCP and 20/20 ping, bridged.
- **Full-size frames:** 1472-byte DF ping passed.
- **Isolation:** only the jack's own VLAN reaches it; another jack's VLAN
  and an unused VLAN do not.
- **Moving a jack to another VLAN:** works both ways.
- **Loop guard:** blocked the jack 5 s after the BPDUs, 0/20 ping while
  blocked, and 20/20 again after restart.

**Web UI:** one row per jack (2.5G LAN 1-4), each with its native
network, enabled state and status.

### Jack ↔ WAN-trunk hardware offload (driver `runner`, RUNNER-E2E-VLAN)

**What changed:** the Runner flow cache now offloads bridged traffic
between two Runner Ethernet ports when both sides carry the same VLAN.
That is jack VLAN ↔ trunk VLAN; the frame is forwarded unchanged. Before
RC10 this traffic stayed on the CPU path and was not even counted.

**Box evidence (q268):** at the jack's 1G line rate (941 Mbit/s):

| Measure | Before RC10 | With RC10 |
|---|---|---|
| CPU cost per Gbit/s | 0.36 cores | 0.02 cores |
| CPU-path packets per 20 s | 1.62 million | 4 |
| Small-packet UDP (128 B) | 110 Mbit/s at 6.7 cores/Gbit | 554 Mbit/s at 0.03 cores/Gbit |

Jack ↔ Wi-Fi and Wi-Fi ↔ trunk were already offloaded and stay so.

### Tagged 802.3 frames on receive (driver `runner`, RUNNER-RX-TAG-8023)

**The defect:** the MAC's receive-error mask was never written. One of
its bits, a length check that ignores the VLAN tag, flagged short tagged
802.3 frames as errors, and they were dropped. Real BPDUs are frames of
this kind. On RC9's untagged jack path the check never fired.

**The fix:** the driver clears that bit on the 10G-class ports (`rnr0`,
`rnr1`, `rnr3`).

**Box evidence:**
- q267: the frames were dropped on the jack, before the fix.
- q270: all were delivered on the jack and on the trunk, with the
  length-check counter proving the check fired.
- q272: real BPDUs then reached the loop guard end to end.
- Not proven: whether the trunk side dropped these frames before the fix.

## Box evidence (lab image vj2b unless noted)

**Regression set (q273 / q276):**
- Web UI degraded-apply PASS.
- L1 two cycles real 0/0.
- Wi-Fi stop/restore PASS and byte-identical restore on the re-run
  (q276).
  - The first run (q273) missed its own test SSID in a passive scan on
    channel 36. The radio was confirmed on channel 36, and the re-run
    passed, so the miss was the MT7925 lab client's intermittent
    scanning.
- Soak DRY-OK.
- Perf smoke NO-REGRESSION on all 12 rows, with no DIP.
  - The 2.4 GHz RTL cell that RC9 flagged is back up (44.5 / 29.0 Mbit/s
    against RC9's 38.9 / 23.8), confirming RC9's flag was that noisy
    cell.

**180-minute release soak** (`rc10-soak-imgvj2b.sh`), with the identity
checked first: **PASS**. 0 unplanned disconnects on either client, load
max 0.69, CLEAN-OK (q276).

**Release-image box phases (q274):** first 15/15 ok, second 6/6 ok.

## Known open

**Jacks**
- **Off until configured:** on a fresh box the jacks stay off until a
  network is chosen for them on the Ports page.
- **Tagged VLAN lists on a jack** ("All", "Custom") are not in RC10. They
  are built and under test for RC11, together with UniFi-style networks
  (name + VLAN + subnet) in the web UI.
- **Default network:** VLAN 1, the untagged management link of the trunk,
  can't be used by a jack or SSID, because it is never bridged.
- **Untested:** 2.5 Gbit/s line rate, and more than one cabled jack. The
  only lab peer links at 1 Gbit/s on one jack.
- **Jack labels:** the label ↔ switch port mapping (LAN1 = 5, LAN2 = 6,
  LAN3 = 7, LAN4 = 4) comes from stock's configuration and is not checked
  against the front panel.
- **Untested ports:** the 1G and 10G ports have not carried traffic on
  this OS.
- **Hardware offload:** a jack frame with a non-zero 802.1p priority would
  stay on the CPU path. The RTL8372 sends priority 0.

**Carried over from RC9**
- 5 GHz-high: after a radar detection at channel 100 in DE the firmware
  has no in-band fallback channel. It can stop the AP briefly while
  hostapd restarts in band (ZW-N5).
- WPS overlap detection is unproven.
- 802.11k neighbour reports are not available.
- Band steering stays off.
- MLO on 5 GHz is pending.
- Radio recovery by rebind stays off.
- IO-coherent PCIe stays bench-only.
- Web UI `go test -race`: unchanged isolation issue in older tests.
- hostapd patch `0002` is not reported upstream.
