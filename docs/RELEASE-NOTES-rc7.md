# GT-BE98 mainline OS 1.0-rc7 - release notes

Date: 2026-11-14 · Status: **release candidate 7**, tagged `gt-be98-rc7`.

Evidence is named by the orchestrator's run directory (`MMDD-HHMM-<arm>`)
or its queue (`qNNN`). The run directories stay on the orchestrator's
machine and are not in this repository. Every number comes with the run
that measured it, and "not measured" never means 0. Image #47 is the
lab-mode build of the RC7 sources: same commits, lab keys. The release
images below are the `RELEASE=1` build of those sources.

RC7 is RC6 with three changes: the OS (buildroot) gains six commits
(Wi-Fi channel and width defaults, automatic channel selection, multicast
to Wi-Fi clients, multicast routing, jumbo frames), the Wi-Fi driver
(open-wifi) moves from `4ec3bcd6` to `7c78601a`, and the Ethernet / Runner
driver (open-ethernet) moves from `a9960de` to `6d922a8`. The web UI and
hostapd are the same as RC6. The kernel configuration changes (multicast
routing, `CONFIG_IP_MROUTE` / `CONFIG_IPV6_MROUTE`).

## Images

| File | sha256 |
|---|---|
| `rootfs.squashfs` | `07c5be24e07f1aad55d828094fc48970b296c80b202f6a4eaac4c14b366ed722` |
| `ml-bootfs.itb` | `36458b6799023fbc774bb05dd527264d53c5c35b7d546ed65a0add6936575632` |

Build id (DT): `20261114T154803Z-135d68dc717f-rw-jffs`

Built with `RELEASE=1` (`ml-bootfs.info`: `release mode: yes`), and
`release-check.sh` returned PASS (44 ok / 0 FAIL, selftest 21/21) with a rebuilt
lab-pattern list (the list RC4..RC6 used no longer exists; the new one
also passes RC5's and RC6's release images and fails the lab image). **These
images are a TEST build**: their `SSH_AUTHORIZED_KEYS` is the lab's public
key, so the orchestrator can run the on-box test. They are never handed
over. A hand-over build is the same sources with the recipient's keys,
checked again with `release-check.sh`. The images contain no SSH host
keys, no web UI password and no rootfs URL. The default Wi-Fi country is
FR. The images contain proprietary vendor firmware: they are handed over
privately and never published (`docs/RELEASE-BUILD.md`).

Lab image #47: `rootfs.squashfs` `2e52f197212d77ab58724df433854c935b39defadf0d7a3bc24b3108b574ca1d`,
`ml-bootfs.itb` `682464d8a9e5dc2006cd5952a23a941499464540fa6e19a6af0d6c4a57fad21f`,
build id `20261114T151547Z-b864f7b89f87-rw-jffs`. Its root filesystem
holds the same files as image #46 (the OS-feature lab image the OS changes
were measured on) and differs from it in exactly three:
`/etc/gt-be98-release`, the Wi-Fi driver module and the Runner module.

Built from (`gt-be98-rc7` tags):

| Component | Commit |
|---|---|
| gt-be98-buildroot | `ed6f5ba` (`br-img47-2026-11-14` = `br-os-qw-2026-11-13` `13397ac` + the open-wifi and open-ethernet pins; `13397ac` = RC6's `1ebc819` + 6 OS commits) |
| open-wifi (`bca_pcie_ipc.ko`) | `7c78601a` |
| open-ethernet (Runner, kernel series, `rtl8372.ko`) | `6d922a8` (`oe-rc7-2026-11-14`) |
| web UI (gt-be98-webui-go) | `5d1697b`, version string `gt-be98-rc4-4-g5d1697b` (unchanged since RC5) |
| hostapd | 2.12 with the local patches `0001` (device-SME Multi-AP) and `0002` (a failed AP MLD ADD keeps the process) - unchanged |
| Linux / Buildroot | 7.2.9 / 2026.08 |

The web UI is the same reproducible delivery as RC5 and RC6
(`tools/build-delivery.sh`, `BUILDINFO`), binary
`1a46ceca9e5d5d48565065c81ecf84433fc05002af31729d16a8bb1c207846e7` in both
the lab and release images. Its version string stays
`gt-be98-rc4-4-g5d1697b`.

The lab Wi-Fi driver module is `923615565843c3cdcb579ce04539b5e3d73738bc339a4f16157a43ecf7d7bed4`,
byte-identical to the shipped module run on the box in q217. The lab
Runner module is `91dad16347abe4b63597f0c8295fc17b7a1890a4d642a671cb64f0c599bae2ab`,
byte-identical to the module staged for RC7 (`oe-rc7`). The release
image's modules (Wi-Fi `59bc6d3e...`, Runner `367e1641...`) have the same
code and data (`.text`, `.data`, `.modinfo` identical); they differ only
in the build-path strings of kernel-header warning sites in `.rodata`, as
in RC6.

## Changes since RC6

### Wi-Fi (OS)

- **5 GHz-low uses 160 MHz by default** when the country is set (80 MHz
  without a country); a `width=` written in the configuration is kept
  (buildroot `d782ac9`). Box: q214 A1 PASS (image #46, run
  `1113-2055-os-qw-r3-A1A2A3A4`): the AP and the client both at 160 MHz.
- **`channel=auto` picks the channel itself** (hostapd's automatic channel
  selection, ACS) on 2.4 GHz, 5 GHz-low and 5 GHz-high; it is refused on
  6 GHz, and a radio used as a station or monitor keeps a fixed channel
  (`5a59406`). Box: q214 A2 PASS (2.4 GHz picked channel 1, 5 GHz-low
  channel 44).
- **On 5 GHz-high, automatic selection never picks a block containing the
  weather-radar channels 120-128** (their radar check lasts 10 minutes
  instead of 1); at 160 MHz the automatic 5 GHz-high radio runs at 80 MHz.
  A radar-triggered channel move still uses the full channel list
  (`13397ac`). Box: q214 A2-5GH PASS (picked channel 112, AP enabled).
- **Multicast reaches Wi-Fi clients as unicast** (multicast-to-unicast on
  every network's bridge port, with IGMP snooping): a multicast stream
  (IPTV, discovery) is sent to each subscribed client at its own rate
  instead of at the slow basic rate to all. The routed bridges send IGMPv3
  queries; VLAN bridges leave that to the LAN's querier unless
  `WIFI_MCAST_QUERIER=1` (`9ee44f9`). Box: q214 A3 rescored PASS (image
  #46: 4000/4000 packets delivered as unicast copies to both clients; the
  RTL client went from 1857 to 4000 received); the q219 re-run read 0.949
  for one client, INCONCLUSIVE, not a failure.

### Network (OS)

- **Multicast routing for IPTV over a routed WAN**: the kernel gains
  multicast routing (`CONFIG_IP_MROUTE`, `CONFIG_IPV6_MROUTE`) and the
  image ships `igmpproxy`; router mode runs it with `ROUTER_IGMP_PROXY=1`
  (off by default) (`41f213f`). Box: q219 A4 PASS (run
  `1113-2149-os-qw-r4-A3A4`: 3994/4000 multicast packets from the WAN
  reached the LAN with the proxy, 0/4000 without).
- **Jumbo frames**: `WAN_MTU` up to 10240 (the Runner's maximum),
  `PPPOE_MTU` up to 1500 (RFC 4638), a new `LAN_MTU` for the LAN bridge;
  defaults unchanged and every MTU restored when the service stops
  (`c2a6e08`). Box: q209 A5 PASS (image #45, run
  `1113-1808-os-qw-A1A2A3A4A5`: the WAN port went to 9000 and back to
  1500). An end-to-end jumbo ping was not measured (the lab peer's MTU is
  1500).

### Ethernet / Runner offload (open-ethernet `6d922a8`)

- **The hardware flow table holds stock's 16384 flow directions** (about
  8000 connections) instead of about 512 (`cf46388`). Box: q212 flowcap
  PASS (run `1113-1830-eth-qw-arm-r3`: 3072 generated directions all in
  hardware, 0 table-full; the old module capped at 1024 with 17242
  table-full events).
- **`ip -s link` counts the traffic the Runner forwards** (from the MAC's
  hardware counters), so a port carrying offloaded traffic no longer reads
  idle (`b595821`). Box: q212 counters PASS (within 5 % of the traffic
  generator: 1.045 down, 1.040 up; the old module counted ~0).
- **A traffic shaper (tc) on an outgoing interface is honoured**: an
  offloaded flow bypassed every qdisc, so a configured shaper did nothing
  to it; such a flow now stays on the CPU path, and its hardware entry is
  dropped when a shaper appears. A Wi-Fi egress stays offloaded, because
  its offloaded frames already pass the Wi-Fi interface's qdisc
  (`3f075fc`, `83b052e`). Box: q212 shaping PASS (shaped flows held their
  rate and were not offloaded; unshaped flows offloaded; a shaper added
  live removed the entry).
- No regression: q212 regression PASS (routed throughput within 0.9x of
  the old module everywhere: 869 vs 871 Mbit/s down and 812 vs 810 up on
  1 GbE, 5121 vs 5117 down and 4294 vs 4252 up on the 10 GbE path; CPU
  within 3 points).
- **Routed traffic through a VLAN WAN (`rnr0.<VID>`) is offloaded**, the
  Runner pushing and popping the 802.1Q tag; before, a tagged WAN ran
  entirely on the CPU. On by default (`0661ff5`, `6d922a8`). Box: q216
  PASS (run `1113-2112-eth-wan-arm`: one hand-programmed entry carried
  1000/1000 frames tagged and well-formed; the learner offloaded both
  directions with the VLAN device's CPU packets at most 10 % of the CPU
  path and no malformed frame). That run used the lane's module with the
  feature enabled; RC7's module has the same code with the feature on by
  default and the bench switch removed. The RC7 module itself runs on the
  box first in the image #47 regression set (q226: L1, Wi-Fi stop/restore, smoke and the 180-minute soak all ran on it; PASS).

### Wi-Fi driver (open-wifi `7c78601a`)

- **WMM: the access point's traffic-class parameters reach the radio**
  (`032a8bd0`). hostapd's EDCA settings (`tx_queue_*` for the AP,
  `wmm_ac_*` advertised to clients) were dropped by the driver; they now
  reach the firmware, and the beacon's WMM element carries hostapd's
  values, at start and when changed live. Box: q212 PASS (run
  `1113-1845-wqw-B-wmm-r2`) and q217 PASS on this exact module (run
  `1113-2120-wqw-B-wmm-r2`, module `92361556...`), with L1 0 real lines
  and the baseline PASS.
- Radio recovery (INV-RECOVERY, `1b1eab62`): the rebind give-up limit no
  longer re-opens every 10 minutes, and a firmware trap on a running radio
  is detected without a control call. Both are active only when
  `radio_rebind > 0`, which stays 0 in this release: no behaviour change by
  default.
- Multi-link (MLO) bench progress (r5-3: AP MLD address, group-frame
  sequence numbers): bench/group build only, not in the product.

## Box evidence (image #47 unless noted)

- Regression set (q226): web UI degraded-apply PASS, idle load 0.05 (0 rxpoll threads in D), L1 two cycles real 0/0, Wi-Fi stop/restore PASS + restore byte-identical, soak DRY-OK, perf SMOKE vs RC6 NO-REGRESSION on all 12 rows (5gl up +11 %, 6g dn -3 % within noise).
- 180-minute release soak (`rc7-soak-img47.sh`, identity checked: web UI,
  Wi-Fi driver, rootfs volume (which also covers the Runner module), build
  id; the soak's own networks checked deleted, live and in the saved
  state, at the end): **PASS**, CLEAN-OK (q226).
- Release-image box phases (first / second, build id checked before
  `first`): first 15/15 ok, second 6/6 ok (q224).
- Feature arms, before this image: q209 A5, q212 (Ethernet and WMM), q214
  A1 / A2 / A2-5GH / A3 rescored, q216, q217, q219 A4: PASS (above).

## Known open

- **Not in RC7**: WPS (push-button pairing), 802.11k/v (neighbour reports,
  BSS transition), the band-steering daemon, the RTL8372 switch
  configurator. WPS and 802.11k/v are pending (built, box arms in
  progress) and planned for RC8.
- **The 2.5G LAN ports** (behind the RTL8372 switch) are pending: the
  configurator brought the switch's uplink up on the bench (q208), but it
  is not in the product and the ports are not usable in RC7.
- **MLO on 5 GHz is pending**: the 6 GHz link of a multi-link AP connects
  and carries data on the bench; the 5 GHz link is an open firmware
  question. MLO is not in the product.
- Radio recovery by rebind (`radio_rebind`) stays off: after a rebind on
  5 GHz-low channel 40 a client stayed scanning for 147 s in q212 (channel
  36 was fine); being localised.
- 2.4 GHz with the RTL lab client is a noisy cell: download/upload swing
  ±10 % between runs of the same image. Never gated on alone.
- IO-coherent PCIe (D31) stays bench-only (D35).
- Web UI tests: `go test -race` fails on RC4..RC7 alike (a background
  watcher outlives a test's fake command runner): a test-isolation issue,
  not a product defect; not fixed.
- A config-line failure (as opposed to a radio failure) makes start report
  degraded, but `rc-service gt-be98-wifi status` still exits 0 (no failed
  radio record to list).
- hostapd: a failed AP MLD ADD crashed `hostapd -g` (two NULL dereferences);
  fixed in this image by the local patch `0002` (unchanged since RC5), still
  present upstream; documented in `docs/HOSTAPD-MLD-FAILED-ADD.md`, not
  reported upstream (owner, 2026-11-12). MLD is bench-only.
- The RC5 test-harness gap (soak networks coming back after the release
  phases) is closed: RC6's soak cleaned and saved the state (q205
  CLEAN-OK).
