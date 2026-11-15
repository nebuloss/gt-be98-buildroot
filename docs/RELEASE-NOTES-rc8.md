# GT-BE98 mainline OS 1.0-rc8 - release notes

Date: 2026-11-15 · Status: **release candidate 8**, tagged `gt-be98-rc8`.

Evidence is named by the orchestrator's run directory (`MMDD-HHMM-<arm>`)
or its queue (`qNNN`). The run directories stay on the orchestrator's
machine and are not in this repository. Every number comes with the run
that measured it, and "not measured" never means 0. Image #48 is the
lab-mode build of the RC8 sources: same commits, lab keys. The release
images below are the `RELEASE=1` build of those sources.

RC8 is RC7 with three changes. The Wi-Fi driver (open-wifi) moves from
`7c78601a` to `5378a951`: WPS push-button pairing and 802.11k/v. The
Ethernet driver (open-ethernet) moves from `6d922a8` to `9e797fd`: the
RTL8372 switch configurator, which makes the 2.5G LAN ports carry traffic.
The OS (buildroot) gains the WPS and 802.11k/v helpers and the wired-LAN
service changes. The web UI, hostapd and the kernel configuration are the
same as RC7.

## Images

| File | sha256 |
|---|---|
| `rootfs.squashfs` | `6418be28657fd4f77fc9f46ffd2aa107456d30d27a86dbc6d4089c24d0b1793a` |
| `ml-bootfs.itb` | `621be9b717ffa6eb8d2e34317ae342e30d39318b0170eabad8ad7a4d0ac9de5f` |

Build id (DT): `20261115T155944Z-791040739807-rw-jffs`

Built with `RELEASE=1` (`ml-bootfs.info`: `release mode: yes`).
`release-check.sh` returned PASS (selftest 21/21) with RC7's lab-pattern
list, and the lab image #48 fails it with 13 findings, as expected. The
exact-pattern list finds one item, the lab public key in
`etc/ssh/authorized_keys/root`; RC7 shows the same single item. **These
images are a TEST build**: their `SSH_AUTHORIZED_KEYS` is the lab's public
key, so the orchestrator can run the on-box test. They are never handed
over. A hand-over build is the same sources with the recipient's keys,
checked again with `release-check.sh`. The images contain no SSH host
keys, no web UI password and no rootfs URL. The default Wi-Fi country is
FR. The images contain proprietary vendor firmware: they are handed over
privately and never published (`docs/RELEASE-BUILD.md`).

Lab image #48: `rootfs.squashfs`
`e3f8e772d256657697f3afe3679cb4726fad6a2b53f42bc4975d29c2e3f486b0`,
build id `20261115T151714Z-eca152d5916e-rw-jffs`. Its Wi-Fi module
(`578bd384`) is byte-identical to the one box-tested in q249.

Built from (`gt-be98-rc8` tags):

| Component | Commit |
|---|---|
| gt-be98-buildroot | `44a20ef` (`br-rc8-2026-11-15` = RC7's `aebe797` + `br-rtl8372-2026-11-14` + `br-wps-2026-11-13` + `br-kv-2026-11-13` + the open-wifi pin) |
| open-wifi (`bca_pcie_ipc.ko`) | `5378a951` |
| open-ethernet (Runner, kernel series, `rtl8372.ko`) | `9e797fd` (open-ethernet `main`) |
| web UI (gt-be98-webui-go) | `5d1697b`, version string `gt-be98-rc4-4-g5d1697b` (unchanged since RC5) |
| hostapd | 2.12 with the local patches `0001` and `0002` - unchanged |
| Linux / Buildroot | 7.2.9 / 2026.08 |

## Changes since RC7

### Wi-Fi driver (open-wifi `5378a951`)

- **WPS push-button pairing.** The firmware's probe-request event (44) is
  delivered to hostapd while a BSS runs WPS, so hostapd sees enrollees.
  A client enrolls with the button and joins (q236, q249: OC PASS).
  Overlap detection (two clients pressing at once) is **probabilistic and
  not proven**: the firmware delivers an enrollee's full WPS probe only
  about once every 25-60 s, so a short burst from a second client can be
  missed. In q236 and q249 the overlap case was never observed (UNSEEN),
  which is a coverage limit, not a failure. Event 200 is never subscribed:
  it stops the firmware on both radios.
- **802.11k/v.** BSS-transition management (802.11v) works: the AP asks a
  client to move, the client moves within 2 s, and its response reaches
  hostapd (q218, q249: B PASS, 0 bad frames). The AP advertises
  BSS-transition support (extended capability bit 19). **Neighbour reports
  (802.11k) do not work yet**: the firmware does not advertise the
  radio-measurement capability, so clients never ask (known gap,
  KV-RMCAP).

### Ethernet driver (open-ethernet `9e797fd`)

- **RTL8372 configurator: the 2.5G LAN ports carry traffic.** The module
  now brings the switch up by replaying stock's bring-up sequence, then
  starts the switch's PHY poller once more after the LAN PHYs report up.
  Without that second start the switch never registered a port's link
  (root cause found in q241-q244). Box evidence: q245 LANDING PASS (two
  cold loads, port 6 links, 20/20 pings each). No new module parameter;
  the lab write interface is compiled out of the shipped module.
- Tested at 1 Gbit/s on one port only. 2.5 Gbit/s line rate, ports 4, 5
  and 7, and several ports at once are **not tested**.

### OS (buildroot)

- WPS and 802.11k/v helpers (`gt-be98-wps`, generator `wps=` and `kv=` keys).
  **Band steering stays off**: the generator drops `kv=1` by default and the
  steering daemon never starts on a default configuration.
- `gt-be98-lan` can now run the wired LAN as an address-translated LAN
  (only when `LAN_ADDR` is set): NAT out of the uplink, a refusal when the
  WAN or a Wi-Fi station network overlaps the LAN subnet, and a guard in
  `gt-be98-router`. Box evidence: LAN1 (q247) and LAN2 (q248) PASS. **This is
  off by default**, and the wired LAN service is not in the default
  runlevel: on a default RC8 box the 2.5G jacks stay unpowered, as in RC7.
  The owner chose to configure the jacks by native VLAN (UniFi-style port
  profiles); that work is planned for RC9.

## Box evidence (image #48 unless noted)

- Regression set (q250): web UI degraded-apply PASS; idle load 0.09 (0
  rxpoll threads in D); L1 two cycles real 0/0; Wi-Fi stop/restore PASS +
  restore byte-identical; soak DRY-OK; perf SMOKE NO-REGRESSION on all 12
  rows (2 DIP rows, both CPU per Gbit/s on the noisy 2.4 GHz RTL cell).
- 180-minute release soak (`rc8-soak-img48.sh`, identity checked: commits,
  build id, rootfs volume, web UI and Wi-Fi module): **PASS**, 0 crashes,
  0 firmware faults, load max 0.88, hardware offload active throughout,
  CLEAN-OK (q250).
- Release-image box phases (first / second, build id checked before
  `first`): first 15/15 ok, second 6/6 ok, lab image restored (q252).
- Feature arms: q236 / q249 (WPS), q218 / q249 (802.11k/v), q245
  (RTL8372), q247 / q248 (wired LAN): PASS (above).

## Known open

- **Not in RC8**: band steering, 802.11k neighbour reports, and the 2.5G
  jacks on by default. The jacks will be configured per port by native
  VLAN in RC9 (native VLAN joins the same bridge as that VLAN's Wi-Fi
  networks, with a loop guard). Different VLANs per jack and tagged VLAN
  lists need the switch's VLAN table, which stock never programs: later.
- WPS overlap detection is unproven (see above).
- **MLO on 5 GHz is pending** (parked after safety-classifier blocks on the
  firmware reverse engineering). MLO is not in the product.
- Radio recovery by rebind (`radio_rebind`) stays off (as RC7).
- 2.4 GHz with the RTL lab client is a noisy cell. Never gated on alone.
- IO-coherent PCIe stays bench-only.
- Web UI tests: `go test -race` fails on RC4..RC8 alike (test isolation,
  not a product defect).
- A config-line failure makes start report degraded, but
  `rc-service gt-be98-wifi status` still exits 0 (as RC7).
- hostapd local patch `0002` (failed AP MLD ADD) unchanged, not reported
  upstream (owner, 2026-11-12).
- Saved state can predate new configuration keys: a `/etc/conf.d` file
  saved under an older image replaces the new image's default at boot. A
  missing key behaves like an empty one, so nothing breaks, but writers
  must add a missing key rather than only replace it.
