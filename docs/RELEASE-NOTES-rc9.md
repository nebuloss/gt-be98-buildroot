# GT-BE98 mainline OS 1.0-rc9 - release notes

Date: 2026-11-16 · Status: **release candidate 9**, tagged `gt-be98-rc9`.

Evidence is named by the orchestrator's run directory (`MMDD-HHMM-<arm>`)
or its queue (`qNNN`). The run directories stay on the orchestrator's
machine and are not in this repository. Every number comes with the run
that measured it, and "not measured" never means 0. Image #51 is the
lab-mode build of the RC9 sources: same commits, lab keys. The release
images below are the `RELEASE=1` build of those sources.

RC9 is RC8 with three changes:
- **Wired LAN ports by native VLAN.** The 2.5G jacks join the same network
  (bridge) as the Wi-Fi SSIDs on a chosen VLAN, configured per port in the
  web UI like the UniFi console. A loop guard protects them.
- **The web UI** moves from `5d1697b` to `0897d1d`, adding the Ports page.
- **The Wi-Fi driver** moves from `5378a951` to `2456cda8`: after a radar
  detection, the 5 GHz-high radio can no longer move onto the 5 GHz-low
  radio's channels. This defect is also present in RC8.

The kernel configuration and hostapd are the same as RC8.

## Images

| File | sha256 |
|---|---|
| `rootfs.squashfs` | `a8604610c9cea1f8bffb62c766d61049a63fd778d1cb6c44c47676d23cda4e42` |
| `ml-bootfs.itb` | `fa841ceaa19bbd8ad14e2f9a972b19e55acabf43264334e3f20b8524ffcafd2b` |

Build id (DT): `20261115T232148Z-54127d3dd403-rw-jffs`

The build used `RELEASE=1` (`ml-bootfs.info`: `release mode: yes`).
- **Release check:** `release-check.sh` returned PASS with RC7's
  lab-pattern list; its self-test passed 21/21.
- **Lab image control:** the lab image #51 fails the same check with 13
  findings, as expected.
- **Exact-pattern list:** it finds only the lab public key in
  `etc/ssh/authorized_keys/root`, as in RC7 and RC8.

**These images are a TEST build.** Their `SSH_AUTHORIZED_KEYS` is the
lab's public key, so the orchestrator can run the on-box test, and they
are never handed over. A hand-over build is the same sources with the
recipient's keys, checked again with `release-check.sh`.

The images contain no SSH host keys, no web UI password and no rootfs
URL. The default Wi-Fi country is FR. The images contain proprietary
vendor firmware, so they are handed over privately and never published
(`docs/RELEASE-BUILD.md`).

Lab image #51: `rootfs.squashfs`
`f87a83724b68c6ab9df2f58efbe7bcf4de8b34100f008e440396edc4a1a79394`,
build id `20261115T225049Z-c5d3537c7aa2-rw-jffs`. Its Wi-Fi module
(`13732e2f`) is the shipped build of the fix that was box-tested in
q258.

Built from (`gt-be98-rc9` tags):

| Component | Commit |
|---|---|
| gt-be98-buildroot | `5237eb9` (`br-rc9-2026-11-15` = RC8's `029516a` + `br-lan-vlan-2026-11-15` `6c45376` + the open-wifi pin) |
| open-wifi (`bca_pcie_ipc.ko`) | `2456cda8` |
| open-ethernet (Runner, kernel series, `rtl8372.ko`) | `9e797fd` (unchanged since RC8) |
| web UI (gt-be98-webui-go) | `0897d1d`, version string `gt-be98-rc8-4-g0897d1d` |
| hostapd | 2.12 with the local patches `0001` and `0002` - unchanged |
| Linux / Buildroot | 7.2.9 / 2026.08 |

## Changes since RC8

### Wired LAN ports by native VLAN (OS, web UI)

**Port profile.** Each port has a profile in `/etc/conf.d/gt-be98-lan`,
written by the web UI's Ports page:
`LAN_PORT_<port>="native=<vlan> tagged=none enabled=0|1"`. The port
joins the bridge of the Wi-Fi network on that VLAN, so the port and the
SSID share one LAN, bridged, not routed. A new shared bridge owner
(`gt-be98-l2`) keeps the bridge up while either Wi-Fi or a port needs
it, so a Wi-Fi restart no longer drops the wired ports.

**Box evidence:**
- **LAN3 r5 (q256):**
  - After a cold boot, a device on a 2.5G jack got its address from a
    Wi-Fi client on the same network (20/20).
  - Ping went 10/10 both ways.
  - Bridged, not routed: the client saw the device's own MAC, and the box
    forwarded 0 IP packets.
- **Web UI Ports (q259):** apply, disable, all three reverts, and
  persistence across a cold boot: PASS.

**The web UI.** Choosing the native network from the list of Wi-Fi
networks writes the profile.
- A change reverts by itself after 120 s unless confirmed, even across a
  web UI restart or a reboot.
- The page shows whether each port is forwarding.
- The old Ports path, which built its own bridges that the OS's network
  guard undid, is removed on this platform.

**Loop guard.** A port that receives a spanning-tree frame (BPDU) is
taken out of its bridge. This also drops its hardware-offloaded flows:
bridge-only blocking does not stop traffic the Runner already forwards.
The port stays out until the service is restarted (the Ports page offers
"Clear guard").
- Box evidence: q256. Ping after the trip was 0/5, and the peer's
  hardware flows went from 2 to 0.

**Off until configured.** `gt-be98-lan` now starts at boot, but does
nothing until a port has a profile. On a fresh box the jacks stay off
until a network is chosen on the Ports page.

**Limits:**
- The four 2.5G jacks share one internal link to the SoC, so in this
  release they share one native VLAN.
- Per-jack VLANs and tagged VLANs ("All", "Custom") need the switch's VLAN
  table and are shown as not yet available.
- The 1G and 10G ports have not been tested with a cable on this OS.
- The loop guard catches loops through equipment that sends BPDUs. A loop
  through a switch that sends none is not detected.

### Wi-Fi driver (open-wifi `2456cda8`)

**The defect (DFS5GH-BAND).** The 5 GHz-high radio advertised the 5 GHz-low
channels 36-64 as well as its own.
- The driver gave the firmware a list of fallback channels for use after
  a radar detection, and for this radio every entry was a 5 GHz-low
  channel.
- After a radar detection on channel 100, the firmware moved the radio to
  channel 36, and hostapd followed. The radio then shared the 5 GHz-low
  radio's channel and reached clients poorly.
- This was seen on img49 (same Wi-Fi driver as RC8) and reproduced on
  demand with the firmware's radar simulation (q258).

**The fix.** Each 5 GHz radio now advertises only its own half:
- 5 GHz-low: 5150-5350 MHz;
- 5 GHz-high: 5470-5895 MHz.

No new module parameter.

**Box evidence (q258):**
- With the fix, the firmware still picked channel 36, the driver refused
  it, and the AP came back up in its own band (channel 116).
- The 5 GHz-low radio was unaffected.

**Side effects:**
- A 5 GHz radio used as a Wi-Fi uplink (station) scans only its own half.
- The 5 GHz-high radio with radar channels disabled has no usable channel
  in ETSI countries.

## Box evidence (image #51 unless noted)

**Regression set (q260):**
- Web UI degraded-apply PASS.
- L1 two cycles real 0/0.
- Wi-Fi stop/restore PASS, and the restore was byte-identical.
- Soak DRY-OK.
- Perf smoke: 1 REGRESSION row and 1 DIP row, both on the 2.4 GHz RTL
  lab client:
  - upload 23.8 against 26.8 Mbit/s;
  - download 38.9 against 43.4 Mbit/s.

  This cell is a standing known exception. It has swung between 18 and 31
  Mbit/s within a single session, and since RC3 no image is gated on it
  alone. Nothing in RC9 touches 2.4 GHz. All 5 GHz and 6 GHz rows are
  within 4 % of RC8.

**180-minute release soak** (`rc9-soak-img51.sh`), with the identity
checked first (commits, build id, rootfs volume, web UI and Wi-Fi module):
- **PASS:** 0 unplanned disconnects on either client, load max 0.53,
  CLEAN-OK (q260).

**Release-image box phases (q261):** first 15/15 ok, second 6/6 ok, and
the lab image was restored.

## Known open

- Per-jack VLANs, tagged VLANs on the jacks, and the 1G/10G ports with a
  cable are not done or not tested (see above).
- After a radar detection on the 5 GHz-high radio at channel 100 in DE,
  the firmware has no in-band fallback channel. It can stop the AP
  briefly while hostapd restarts in band (ledger ZW-N5).
- WPS overlap detection is unproven (as RC8).
- 802.11k neighbour reports do not work yet; band steering is off (as RC8).
- MLO on 5 GHz is pending; MLO is not in the product.
- Radio recovery by rebind stays off; IO-coherent PCIe stays bench-only.
- Web UI tests: `go test -race` still reports races in older code (test
  isolation, not a product defect). A flaky Wi-Fi test caused by a
  leftover background watcher is fixed in this release.
- hostapd local patch `0002` is unchanged and not reported upstream.
- Saved state can predate new configuration keys. A missing key behaves
  like an empty one. The web UI adds a missing port line rather than only
  replacing an existing one.
