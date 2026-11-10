# GT-BE98 mainline OS 1.0-rc4 - release notes

Date: 2026-11-10 · Status: **release candidate 4 - DRAFT**. Not tagged yet:
the regression set (q148) and the 180-minute soak of image #39 are not
finished, and the release images have not been tested on the box. Lines
marked PENDING are filled in from those runs.

Evidence is named by the orchestrator's run directory (`MMDD-HHMM-<arm>`).
The run directories stay on the orchestrator's machine and are not in
this repository. Every number comes with the run that measured it, and
"not measured" never means 0. Image #39 is the lab-mode build of the RC4
sources: same commits, lab keys. The release images below are the
`RELEASE=1` build of those sources.

## Images

| File | sha256 |
|---|---|
| `rootfs.squashfs` | `c29b380005527218e47d6e84e188df9db150291b98f2de2043a627eb19376737` |
| `ml-bootfs.itb` | `7626d37b52d16f32ad112f6bf0b469a4859e49963ef6b2529161fa0e14fd879b` |

Build id (DT): `20261110T154323Z-c3cc8fccab22-rw-jffs`

Built with `RELEASE=1` (`ml-bootfs.info`: `release mode: yes`), and
`release-check.sh` returned PASS (selftest 21/21; built-in checks and all lab patterns absent). **These images are a TEST build**:
their `SSH_AUTHORIZED_KEYS` is the lab's public key, so the orchestrator
can run the on-box test. They are never handed over. A hand-over build
is the same sources with the recipient's keys, checked again with
`release-check.sh`. The images contain no SSH host keys, no web UI
password and no rootfs URL. The default Wi-Fi country is FR. The images
contain proprietary vendor firmware: they are handed over privately and
never published (`docs/RELEASE-BUILD.md`).

Built from (`gt-be98-rc4` tags, once tagged):

| Component | Commit |
|---|---|
| gt-be98-buildroot | `0a1bbcf` (`br-img39-2026-11-10`) |
| open-wifi (`bca_pcie_ipc.ko`) | `b2a70da3` |
| open-ethernet (Runner, kernel series, `rtl8372.ko`) | `a9960de` |
| web UI (gt-be98-webui-go) | `370d523` |
| hostapd | 2.12 with the local patches `0001` (device-SME Multi-AP) and `0002` (a failed AP MLD ADD keeps the process) |
| Linux / Buildroot | 7.2.9 / 2026.08 |

The web UI in the release image is byte-identical to the one in image
#39 (`webui` sha256 `6eac6608...`): it was rebuilt from `370d523` with
`tools/build-mainline.sh` and compared. It has the first-login setup
token. The three driver modules have the same `.text` as in image #39;
their `.rodata`, symbol table and build id differ (build path and release
build identity). hostapd is byte-identical to image #39's.

## Scope (owner decisions)

- D15: the mainline OS is booted **one-shot** from stock. Every reset,
  including a power cut, returns the box to the stock firmware.
- D16: **access point with a wired uplink** is the default and the
  tested scope. WAN modes and router mode are opt-in (since RC2).
- D17 / D24: **no MLO** in the release. MLO stays a bench feature.
- D18: HE, EHT and TWT on by default on every radio, switchable per
  radio; stock's transmit beamforming (RC3).
- D20: the default country is FR.
- D22: in AP mode the box sits **on a trusted LAN** (no input firewall on
  the uplink); router mode always brings an input firewall on its WAN
  (RC3).
- **New in RC4**, D33: **6 GHz runs at 320 MHz by default.** A stored
  width is never changed. A 320 MHz block always ends inside the
  country's 6 GHz band (FR/DE: channels 1-61 centre 31, 65-93 centre 63);
  where none fits, the radio runs at 160 MHz and the web UI says so.
- **New in RC4**, OD1 (b): 2.4 GHz is 20 MHz only. The driver
  advertises HT20 there, so the web UI no longer offers 40 MHz on
  2.4 GHz and a saved 40 becomes 20.

## Installing, booting, going back

Follow `docs/FLASHING.md` (repository commit `0a1bbcf`). Verify the
sha256s above, then flash slot 1 from stock with `gt-be98-flash.sh`. Boot
it once (`gt-be98-flash.sh boot`), and `reboot` to return to stock. The
next mainline boot needs `gt-be98-flash.sh boot` again.

On first boot the box makes its own SSH host keys (ssh shows a new host
key once). The web UI asks for a password, which can be set only with
the one-time token in `/run/webui/setup-token` (read it over ssh as
root).

## Release image on the box

PENDING: the same checks as RC1 and RC3 (`release-build-arms.sh`: prep,
flash, first boot, second boot, restore). RC3's release images passed
them all (`1109-0925-release-build-first` 15 ok / 0 FAIL,
`1109-0929-release-build-second` 6 ok / 0 FAIL); the first-boot code
(`gt-be98-hostkeys`, the web UI setup token) is unchanged since RC3.

## What works

Image #39 regression (q148), unless a row says otherwise. Rows marked
"lane run" were read on silicon with that change's own module or image
(#38, #39) before it landed.

| Area | Feature | Evidence |
|---|---|---|
| Regression | driver load/unload health (L1) | `1110-1505-l1r` (real bad lines 0 on load, unload and C) |
| Regression | soak dry run | `1110-1509-release-soak-dry` (DRY-OK) |
| Regression | a web-UI-created network goes on air (WIFISTOP) | `1110-1509-wifistop`: **UNREAD** (VOID by its fixture: the lab baseline now holds no invalid network to test). Last PASS: image #37 (`1108-1912-wifistop`) |
| Regression | station deauthentication, perf smoke, box baseline, radio supervision, product reload | PENDING (q148) |
| Wi-Fi 7 | **Wi-Fi 7 clients with multi-link support join WPA3-SAE** (fixed since RC3, see Changes) | lane run `1109-1206-b01-inv-mle-fix` (no Basic Multi-Link element on any EHT BSS, EHT kept; wpa_supplicant 2.11 SAE joins on 5 and 6 GHz complete as Wi-Fi 7, 0 % loss) |
| Wi-Fi | 6 GHz at 320 MHz (AP side) | `1110-1327-b08-6g-320`: hostapd asks 320 MHz and the firmware runs the same chanspec; the MT7925 client (no 320 MHz) joins and runs at down 1498 / up 1042 Mbit/s (in a 160 MHz BSS: 1575 / 1069) |
| Wi-Fi | 5 GHz 160 MHz offered (5 GHz low 36-64, 5 GHz high 100-128) | `1110-1023-osf-a160` (PASS) |
| Wi-Fi | beacon protection on SAE and OWE networks (as stock) | lane runs `1109-1037-bcnprot`, `1109-1418-bcnprot` (beacons carry the protection bit and the MME with key 6 on air; BIGTK installed; WPA2 unchanged; SAE join 0 % loss). Client-side check UNREAD (the MT7925 does not support it) |
| Wi-Fi | clients on the same network reach each other; `ap_isolate` honoured (fixed since RC3) | lane runs `1109-1725-c2c-fix-r2`, `1109-1755-c2c-fix-r2` (same-network loss 100 % -> 0 %; isolation drops; cross-radio OK) |
| Wi-Fi | per-network U-APSD follows hostapd; removing a network frees it in the firmware (fixed since RC3) | lane runs `1109-1811-b03r3-bssdel-uapsd`, `1110-0913-b03r4-bssdel-uapsd` (U-APSD and the firmware free PASS), `1110-1019-b03r5-bssdel-reload` (product reload PASS) |
| Wi-Fi | `txpower auto` restores the full power (fixed since RC3) | lane run `1109-1609-b04-txpwr-auto` (31 dBm restored) |
| Wi-Fi | no false "Read-only file system" key errors in hostapd (INV-SETKEY, fixed since RC3) | lane runs `1110-0946-b05-bcme-errno`, `1110-1106-b05-bcme-errno` |
| Wi-Fi | ETSI: zero-wait DFS not offered | `1110-1022-osf-etsi` (PASS) |
| OS | a radio that fails to start is retried (at most 3 times per config) and reported in the web UI; a dead hostapd is restarted | `1110-1035-osf-supervise-r4` (PASS, labelled rescore) |
| Stability | 3 h soak | PENDING (below) |

## Measured numbers

| Measurement | Value | Run |
|---|---|---|
| **soak on #39**, 180 min | PENDING | PENDING |
| 6 GHz, MT7925 client, 320 MHz BSS vs 160 MHz BSS | down 1498 vs 1575, up 1042 vs 1069 Mbit/s | `1110-1327-b08-6g-320` |
| 6 GHz 160 MHz upload, box CPU | 0.572 -> 0.517 cores per Gbit/s (client lookup without a lock), throughput equal | `1110-1207-rxlookup` and the `rxl` perf runs |
| 5 GHz download, box CPU | 0.785 -> 0.692 cores per Gbit/s (box-local TCP no longer goes through the host queue) | `1109-0846-txcpu-t3` (q90) |
| routed traffic latency | sender RTT median 19.23 -> 18.17 ms (backlog drained inline) | `1109-0938-txcpu-t4` |
| control waiter refused by the firmware (status 9) | 4.07 s -> 0.47 ms (fails fast) | `1109-1044-evt-defects` and the int-1109 runs |

## Known limits

- **One-shot boot** (D15): any reset or power cut returns the box to stock
  until `gt-be98-flash.sh boot` runs again.
- **No input firewall on the uplink in AP mode** (D22): the box is an
  access point on a trusted LAN; ssh and the web UI answer on `rnr0`. Do
  not connect `rnr0` to the internet directly. Router mode loads an input
  firewall on its WAN (`table inet gt_be98_router_in`, management only
  from `ROUTER_WAN_ALLOW`). Its limits are unchanged since RC3: on a VLAN
  or PPPoE WAN the allow-list cannot open management, and Wi-Fi station
  routed networks NAT out of a station with no input filter.
- **MLO: bench-only** (D24). The multi-link work landed since RC3
  (stock-order teardown, radio ownership, AP MLD links) runs only in the
  bench build; the release has no MLO. The 0907 kernel patch (PCIe
  peer-to-peer window between the root complexes) is in the kernel and
  inert unless the bench driver calls it.
- **6 GHz 320 MHz is verified on the AP side only.** The lab's Wi-Fi 7
  client (MT7925) has no 320 MHz capability; it joins a 320 MHz BSS and
  links at up to 160 MHz (`1110-1327-b08-6g-320`). A 320 MHz client link
  is not tested yet.
- **Group-key install timeouts** (KEY-110): an AP group-key install that
  times out is reported to hostapd as success and retried in the
  background, so hostapd can believe in a key the firmware does not
  hold. Counters exist (`peers.gtk_*`); none was seen in the runs. Open,
  accepted limit.
- **Idle clients are not aged out** (D27): hostapd's inactivity check
  stays off in the shipped driver.
- **A firmware trap leaves that radio down** until the driver is
  reloaded or the box reboots (INV-RECOVERY: the driver's one-radio
  rebind exists but is off and was never measured on hardware). The OS
  restarts a radio whose start fails and a dead hostapd, not a radio
  whose firmware stopped.
- **CSA onto a DFS channel** (FCSA-N2): whether the firmware then runs
  its own CAC and silences the networks for about a minute is not read on
  silicon.
- **Repeater (opt-in)**: the firmware moves the AP to the station's
  channel without telling hostapd (APSTA-N1).
- **Zero-wait DFS is not available in ETSI countries** (ZW-N3; the web UI
  does not offer it there).
- **Not available**: 802.11k/v and band steering (INV-T6; the web UI
  option is prepared and hidden), preamble puncturing (bench build only),
  OWE as a station.
- **hostapd and beacon protection:** hostapd 2.12 turns beacon
  protection on by itself on every PMF network of an EHT radio, so
  WPA3-Enterprise networks get it too (beyond stock). WPA2, Enterprise on
  non-EHT radios, and open networks never do.
- **One unexplained miss (INV-WIFISTOP)**: on image #36 a network created
  from the web UI right after a flash did not appear on air once; not
  reproduced in 9 runs on #36 and #37. On #39 the arm was not read (its
  fixture, above).
- From RC1, not re-measured since (driver paths unchanged): monitor
  captures miss frames larger than the RX buffer (about 1.8 kB); airtime
  fairness helps a slow client only when it has a backlog; on 5 GHz high
  the wiphy country label can show the previous ETSI country; about 1.5 %
  of 6 GHz radio-downs get no answer from the firmware (slower unload,
  nothing lost).

## Changes since RC3 (`gt-be98-rc3`)

- **open-wifi** `cb1c8952..b2a70da3` (112 first-parent commits):
  - **fixes of defects present in RC3**: Wi-Fi 7 multi-link clients
    failed WPA3-SAE on every EHT network (the firmware beaconed a one-link
    Basic Multi-Link element, INV-MLE); clients on the same network could
    not reach each other (INV-C2C, and hostapd's `ap_isolate` never
    reached the driver); per-network U-APSD off was ignored (INV-UAPSD);
    removing a network did not free it in the firmware (INV-BSSDEL);
    `txpower auto` meant 0 dBm (INV-TXPWR-AUTO); firmware status codes
    reached hostapd as wrong errnos, for example "set_key failed;
    Read-only file system" at every first association (INV-BCME-ERRNO,
    was INV-SETKEY);
  - beacon protection (BIGTK, as stock);
  - event-path defects: a refused association is no longer announced to
    hostapd (ASSOC7-REFUSED-NEWSTA); a control request the firmware
    cannot answer (status 9) fails fast (RC-GS9); the blocking event work
    moved out of the event path and its switch deleted;
  - 6 GHz secondary address guard (INV-6G-MBSSID-GUARD); CSA refusals
    logged; preamble puncturing (bench build only);
  - CPU: box-local TCP exempt from the in-flight cap (tx-cpu D1), backlog
    drained inline (D3), lock-free client lookup (RX-LOOKUP);
  - MLO (bench build only): stock-order teardown, operation context,
    primary-first AP MLD links.
- **open-ethernet** `1968937..a9960de` (3 commits): the PCIe 0907
  peer-to-peer window API enters the product kernel series (inert unless
  called), and its documentation.
- **gt-be98-buildroot** `8e38ad2..0a1bbcf` (28 commits):
  - 6 GHz 320 MHz default (D33), 5 GHz 160 MHz offered, 2.4 GHz 40 MHz
    rendered at 20 MHz;
  - radio supervision: a radio that fails to start is recorded,
    reported and retried; a re-probed radio is restarted alone; a dead
    hostapd is restarted;
  - hostapd patch 0002: a failed AP MLD ADD no longer kills hostapd and
    every network it runs;
  - beacon protection rendered on SAE/OWE networks; U-APSD advertised on
    every AP network; 802.11k/v prepared behind a switch (off);
  - pins of open-wifi `b2a70da3` and open-ethernet `a9960de`.
- **webui** `3f5c839..370d523` (6 commits): 6 GHz 320 MHz default, 5 GHz
  160 MHz, no 40 MHz on 2.4 GHz, a radio the OS could not start is
  shown with hostapd's reason, the 802.11k/v option (hidden).

## Reporting a problem

Include:
- `gt-be98-status` (on mainline), or `gt-be98-flash.sh status` (on stock);
- the post-code byte read on stock after a failed boot;
- `ml-bootfs.info`;
- what was done since the boot.
