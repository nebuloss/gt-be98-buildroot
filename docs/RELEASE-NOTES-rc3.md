# GT-BE98 mainline OS 1.0-rc3 - release notes

Date: 2026-11-09 · Status: **release candidate 3**, tagged `gt-be98-rc3`
in all four repositories. **DRAFT**: the on-box test of the release
images (below) has not run yet.

Evidence is named by the orchestrator's run directory (`MMDD-HHMM-<arm>`).
The run directories stay on the orchestrator's machine and are not in
this repository. Every number comes with the run that measured it, and
"not measured" never means 0. Image #37 is the lab-mode build of the RC3
sources: same commits, lab keys. The release images below are the
`RELEASE=1` build of those sources.

## Images

| File | sha256 |
|---|---|
| `rootfs.squashfs` | `a8dc3d7a257d48b4f872b6ad0131fea2a6bce490758981bb770f1dd532a88a3f` |
| `ml-bootfs.itb` | `af0b8d49982018ce1102e4ab7ce0cabfe8650c27619757e6dca6b3fb2038338f` |

Build id (DT): `20261109T091937Z-95a3fd764013-rw-jffs`

Built with `RELEASE=1` (`ml-bootfs.info`: `release mode: yes`), and
`release-check.sh` returned PASS (selftest 21/21; built-in checks and all lab patterns absent). **These images are a TEST build**:
their `SSH_AUTHORIZED_KEYS` is the lab's public key, so the orchestrator
can run the on-box test. They are never handed over. A hand-over build
is the same sources with the recipient's keys, checked again with
`release-check.sh`. The images contain no SSH host keys, no web UI
password and no rootfs URL. The default Wi-Fi country is FR. The images
contain proprietary vendor firmware: they are handed over privately and
never published (`docs/RELEASE-BUILD.md`).

Built from (`gt-be98-rc3` tags):

| Component | Commit |
|---|---|
| gt-be98-buildroot `mainline-os` | `8e38ad2` |
| open-wifi (`bca_pcie_ipc.ko`) | `cb1c8952` |
| open-ethernet (Runner, kernel series, `rtl8372.ko`) | `1968937` |
| web UI (gt-be98-webui-go) | `3f5c839` |
| Linux / Buildroot | 7.2.9 / 2026.08 |

The web UI in the release image is byte-identical to the one in image
#37 (`webui` sha256 `8e7c4b81...`): it was rebuilt from `3f5c839` with
`tools/build-mainline.sh` and compared. That build has the first-login
setup token (`webui -features` prints `setup-token`), so no release-only
web UI build is needed. The three driver modules have the same `.text` as
in image #37; their `.rodata`, symbol table and build id differ (build path
and release build identity).

## Scope (owner decisions)

- D15: the mainline OS is booted **one-shot** from stock. Every reset,
  including a power cut, returns the box to the stock firmware.
- D16: **access point with a wired uplink** is the default and the
  tested scope. The 10 Gbit/s port (`rnr0`) is the uplink (DHCP client).
  WAN modes and router mode exist (opt-in since RC2); see D22 for their
  firewall.
- D17 / D24: **no MLO** in the release. MLO stays a bench feature.
- D18: HE, EHT and TWT stay on by default on every radio (as stock), and
  can be switched per radio. **New in RC3:** the access points
  advertise and use stock's transmit beamforming (below).
- D20: the default country is FR.
- D22: in AP mode the box is meant to sit **on a trusted LAN** (no input
  firewall on the uplink). **New in RC3:** router mode always brings an
  input firewall on its WAN (below).

## Installing, booting, going back

Follow `docs/FLASHING.md` (repository commit `8e38ad2`). Verify the
sha256s above, then flash slot 1 from stock with `gt-be98-flash.sh`. Boot
it once (`gt-be98-flash.sh boot`), and `reboot` to return to stock. The
next mainline boot needs `gt-be98-flash.sh boot` again.

On first boot the box makes its own SSH host keys (ssh shows a new host
key once). The web UI asks for a password, which can be set only with
the one-time token in `/run/webui/setup-token` (read it over ssh as
root).

Flash and rollback on the box:
- The release helper's end-to-end run (`release-flash-e2e`, stock to
  release to stock to release) passed on the RC1 release images
  (`1103-1620`). Not repeated on RC3: the flash procedure is unchanged.
- **Not run yet on RC3:** the release-image test below.

## Release image on the box

Not run yet. Planned: the same checks as RC1 (`release-build-arms.sh`:
prep, flash, first boot, second boot, restore). RC1's results
(`1103-1546-release-build-first`, `1103-1549-release-build-second`):
host keys made on the box and kept across a reboot, web UI closed until
the password is set with the one-time token.

| Check | Result | Run |
|---|---|---|
| release mode | not run yet | |
| SSH host keys, first boot (H1, H2, H3, H6) | not run yet | |
| web UI first login (W1 to W7, W5b) | not run yet | |
| second boot (H5, H5b, H6, W8, W8b, W8c) | not run yet | |

## What works

Regression of image #37 (the RC3 sources in lab mode), unless a row says
otherwise.

| Area | Feature | Evidence |
|---|---|---|
| Regression | driver load/unload health (L1), a web-UI-created network goes on air (WIFISTOP), soak dry run, station deauthentication | `1108-1907-l1r` (real bad lines 0), `1108-1912-wifistop` (PASS), `1108-1913-release-soak-dry` (DRY-OK), `1108-1918-sta-defects` (D1 fix side ok) |
| Wi-Fi | 4 radios (2.4 GHz, 5 GHz low, 5 GHz high, 6 GHz), 8 networks over the 4 radios, WPA2-PSK, WPA3-SAE, OWE, each network bridged to its VLAN | soak `1108-1945-release-soak` (8 of 8 BSS enabled, OWE and SAE joins 5 of 5 rotations) |
| Wi-Fi | up to 8 networks on every radio, 6 GHz included (since RC2) | `bssid` arm on image #26 (B2 PASS, 8 on 6 GHz) |
| Wi-Fi | transmit beamforming as stock (D18, new) | `1106-1502-d18-bf` on image #35 (PASS, 13 held: SU/MU beamformer bits in the 5 GHz and 6 GHz beacons, SU only on 2.4 GHz as stock; the driver sends stock's values and the firmware reads them back; MT7925 joins on 3 bands and RTL8188 on 2.4 GHz with 0 % loss) |
| Wi-Fi | HE/EHT switch on 5 GHz high, with beamforming kept | `1106-1508-d18-5gh-heeht` on image #35 (PASS, 17 held: on, off, on; beacon, driver and client generation follow) |
| Router | router mode loads an input firewall on its WAN (D22, new) | `1106-1514-d22-router-input` on image #35 (D0 to D4 PASS, cleanup clean): AP mode filters nothing; router mode drops new connections to the box on the WAN and answers ICMP; an allow-listed address gets in; stopping removes the filter; a bad allow-list keeps router mode down (no filter, no NAT, no forwarding) |
| Ethernet | 10 Gbit/s uplink, Runner offload of Wi-Fi traffic (IPv4 and, since RC3, routed IPv6), jumbo frames (MTU 9000 tested; the driver accepts up to stock's 10240) | soak `1108-1945-release-soak` (offload +2.47 M hardware packets, Wi-Fi offload counters on all 4 radios); RUNNER-GAPS V6 PASS and jumbo arms PASS (image #31/#32 era, open-ethernet `1968937`/`510ed30`) |
| Stability | 3 h soak, every radio | below |

## Measured numbers

| Measurement | Value | Run |
|---|---|---|
| **soak on #37**, 180 min, 4 radios, 8 networks, 2 clients | 0 crashes, 0 firmware traps, 0 TX-DEAD (dmesg and netconsole, 0 unread minutes); 0 unplanned disconnects; MT7925 median 84.9 to 85.0 Mbit/s on 5 GHz low, 5 GHz high and 6 GHz (offered 80, minimum 83.4); RTL8188 median 17.1 Mbit/s on 2.4 GHz for 180 minutes (offered 16, no minute below half the median); MemAvailable slope 0.81 MB/h; OWE probes 5 of 5 | `1108-1945-release-soak` |
| beamforming A/B, 5 GHz low, MT7925 at one position | downlink 850 vs 833 Mbit/s (ratio 1.021, PASS no harm; no gain is claimed from one position) | `1106-1504-d18-range-ab` (image #35) |
| 2.4 GHz RTL8188, image #36 driver vs image #37 driver, same session | downlink 35 to 40 Mbit/s on both; uplink swings 18 to 31 Mbit/s minute to minute (weak signal), no regression | `1108-1934` to `1108-1942-perf-matrix-r24c1` |

## Known limits

- **One-shot boot** (D15): any reset or power cut returns the box to stock
  until `gt-be98-flash.sh boot` runs again (`docs/FLASHING.md`, "Making
  the mainline OS the default boot").
- **No input firewall on the uplink in AP mode** (owner D22, option a).
  Release 1 is an access point on a trusted LAN, and management (ssh,
  the web UI) is reachable on the uplink `rnr0`. Do not connect `rnr0` to
  the internet directly. Router mode always brings an input firewall on
  its WAN: `gt-be98-router` loads `table inet gt_be98_router_in` (replies,
  ICMP, DHCP client replies; management only from `ROUTER_WAN_ALLOW` in
  `/etc/gt-be98-router/router.conf`, empty by default) before it turns
  forwarding on, and does not start without it. Limits of that filter:
  on a VLAN or PPPoE WAN, `gt_be98_wan`'s own drop still applies, so the
  allow-list cannot open management there; Wi-Fi station routed networks
  (`gt-be98-wifi-sta`) still NAT out of a `bcawl*` station with no input
  filter. The arm drove `gt-be98-router` directly; router mode started
  from the web UI was not tested separately.
- **Beamforming (D18):** the `[SU-BEAMFORMEE]` line is written as stock's
  and has no effect (the driver always uses stock's beamformee setting per
  band). The EHT SU-beamformer bit on air is set by the firmware. On 5 GHz
  high the radio first comes up without HE/EHT from hostapd and gets them
  after the CAC (cause not read).
- **Idle clients are not aged out** (D27): hostapd's inactivity check is
  off in the shipped driver, so a client that disappears without leaving
  is not removed for inactivity. The defect found while testing the
  change (a dead client reported as acknowledging the poll) is not
  reachable while ageing is off.
- **One unexplained miss:** on image #36, a network created from the web
  UI right after a flash did not appear on air once (`wifistop`). It did
  not reproduce in 9 runs since, image #37 included (`1108-1912-wifistop`
  PASS).
- **MLO: not available** (D24). It is a bench feature; its teardown is not
  safe while MLO is active.
- **Station mode:** OWE as a station is not supported. A deauthentication
  from the uplink AP is now reported to the OS (`1108-1918-sta-defects`,
  D1 fix side); an uplink AP that disappears without a deauthentication
  was not re-measured since RC1.
- From RC1, not re-measured on RC3 (the driver paths are unchanged):
  monitor captures miss frames larger than the RX buffer (about 1.8 kB);
  airtime fairness helps a slow client only when it has a backlog; on 5
  GHz high the wiphy country label can show the previous ETSI country
  (cosmetic within ETSI); about 1.5 % of 6 GHz radio-downs get no answer
  from the firmware (slower unload, nothing lost).
- **Open issue from RC1, not seen since:** 2.4 GHz bridged traffic once
  stopped while the client stayed associated (image #22, after the full
  regression chain). It did not reproduce in the RC1, RC2 or RC3 soaks
  (RC3: `1108-1945-release-soak`, RTL8188 180 of 180 minutes).

## Changes since RC1 (`gt-be98-rc1` / `gt-be98-v1.0`)

- **gt-be98-buildroot** `a3ebb9ea..8e38ad2` (19 first-parent commits):
  - RC2: 6 GHz broadcast probe responses / FILS discovery, 8 networks
    on 6 GHz (BSSIDs from the anchor's address block), WAN modes and
    PPPoE (opt-in), 4-address repeater with hostapd's Multi-AP patch
    (opt-in);
  - one Wi-Fi network that fails its checks is skipped instead of
    stopping every radio;
  - zero-wait DFS dropped with a warning in an ETSI region; each 5 GHz
    radio gets its own channel list;
  - D18 transmit beamformer lines; D22 router-mode input firewall;
  - pins of open-wifi `cb1c8952` and open-ethernet `1968937`.
- **open-wifi** `18e96ed2..cb1c8952` (170 first-parent commits), among
  them:
  - Runner offload of secondary networks (RUNNER-G2) and the first
    network's address (BSS0-MAC);
  - 4-address repeater (AP side) and OWE stale-leave fix;
  - station: deauthentication reported, country on a station-only radio,
    faster 6 GHz SAE re-association;
  - RX interrupts restored (RXPERF-2) with interrupt moderation (D29:
    200 us), lower uplink CPU;
  - TX/RX completion items read once (tx-cpu C1);
  - stock parity: AP-role prologue, `wsec_info` framing, preinit once,
    power-save pretend 5, multicast statistics;
  - firmware contract fixes (refused control items fail fast).
- **open-ethernet** `b3ca337..1968937` (7 commits): secondary networks
  join the Runner Wi-Fi radio (ABI 4), jumbo frames up to MTU 10240,
  routed IPv6 Ethernet-to-Wi-Fi offload, TCP pure-ACK key.
- **webui** `9bb193a0..3f5c839` (12 commits): RC2 Wi-Fi page (6 GHz
  BSSID change note), an apply with no runnable network no longer stops
  Wi-Fi, zero-wait DFS refused in ETSI regions.

## Reporting a problem

Include:
- `gt-be98-status` (on mainline), or `gt-be98-flash.sh status` (on stock);
- the post-code byte read on stock after a failed boot;
- `ml-bootfs.info`;
- what was done since the boot.
