# GT-BE98 mainline OS 1.0-rc1 - release notes

Date: 2026-11-03 · Status: **release candidate 1**, tagged `gt-be98-rc1`
in all four repositories.

Evidence is named by the orchestrator's run directory (`MMDD-HHMM-<arm>`).
The run directories stay on the orchestrator's machine and are not in
this repository. Every number comes with the run that measured it, and
"not measured" never means 0. Image #24 is the lab-mode build of the RC1
sources: same commits, lab keys. The release images below are the
`RELEASE=1` build of those sources.

## Images

| File | sha256 |
|---|---|
| `rootfs.squashfs` | `12da27aeb111750389579ac35eb0ec51184c42375f48c41edd7427c59f2bc192` |
| `ml-bootfs.itb` | `842162a835c3e3fbe695bec38fca7b036c20852197c2398ff63fffb38e2f2ca8` |

Built with `RELEASE=1` (`ml-bootfs.info`: `release mode: yes`), and
`release-check.sh` returned PASS. The image contains the recipient's SSH
public keys, no SSH host keys, no web UI password and no rootfs URL. The
default Wi-Fi country is FR. The images contain proprietary vendor
firmware: they are handed over privately and never published
(`docs/RELEASE-BUILD.md`).

Built from (`gt-be98-rc1` tags):

| Component | Commit |
|---|---|
| gt-be98-buildroot `mainline-os` | `a3ebb9ea` |
| open-wifi (`bca_pcie_ipc.ko`) | `18e96ed2` |
| open-ethernet (Runner, kernel series, `rtl8372.ko`) | `b3ca337` |
| web UI (gt-be98-webui-go) | `9bb193a0` |
| Linux / Buildroot | 7.2.9 / 2026.08 |

## Scope of release 1 (owner decisions)

- D15: the mainline OS is booted **one-shot** from stock. Every reset,
  including a power cut, returns the box to the stock firmware.
- D16: **access point with a wired uplink**. The 10 Gbit/s port (`rnr0`)
  is the uplink (DHCP client). There is no wired LAN switch, no WAN or
  router mode, and no repeater.
- D17: **no MLO**. D18: Wi-Fi 6 (HE) and Wi-Fi 7 (EHT) can be switched per
  radio. D20: the default country is FR.
- D22: the box is meant to sit **on a trusted LAN** (no input firewall on
  the uplink, see Known limits).

## Installing, booting, going back

Follow `docs/FLASHING.md`. Verify the sha256s above, then flash slot 1
from stock with `gt-be98-flash.sh`. Boot it once (`gt-be98-flash.sh
boot`), and `reboot` to return to stock. The next mainline boot needs
`gt-be98-flash.sh boot` again.

On first boot the box makes its own SSH host keys (ssh shows a new host
key once). The web UI asks for a password, which can be set only with
the one-time token in `/run/webui/setup-token` (read it over ssh as
root).

Flash and rollback on the box:
- **Done with the release images**, by the orchestrator, using the lab
  flash procedure that `gt-be98-flash.sh` productises: flash from stock,
  one-shot boot, first boot, then back through stock and a second boot.
  This was done on the RC1 release images (`1103-1546-release-build-first`,
  `1103-1549-release-build-second`, orchestrator log 11-03 19:30Z), and
  before that on a release build of image #22 (`1103-0613-release-build-first`,
  `1103-0616-release-build-second`).
- **Not done yet:** the end-to-end run of the release helper itself
  (`docs/PREREG-RELEASE-FLASH-E2E-2026-11-02.md`). It has the same steps
  but goes through `gt-be98-flash.sh` instead of the lab procedure.

## Release image on the box

| Check | Result | Run |
|---|---|---|
| release mode | `release-mode yes` | `1103-1546-release-build-first` |
| SSH host keys, first boot | made on the box, exactly the 3 `HostKey` types of `sshd_config` (no extra mldsa44 key, fixed in `9d2fd20`), private keys 0600, saved to `/jffs` (H1, H6, H2, H3 ok) | same |
| web UI first login | token file 0600 root, 24 hex characters (W1); every gated action and endpoint answers `need_auth` on loopback and LAN (W2b); `set_password` refused without the token or with a wrong one (W3, W4); accepted with it (W5); token file removed and replay refused (W6, W7); login works (W5b) | same |
| second boot (via stock and a new one-shot boot) | same ed25519 fingerprint, keys restored not regenerated, no mldsa44 key (H5, H5b, H6); web UI still configured, no token, login works (W8, W8b, W8c) | `1103-1549-release-build-second` |

## What works

Regression of image #24 (the RC1 sources in lab mode), unless a row says
otherwise.

| Area | Feature | Evidence |
|---|---|---|
| Wi-Fi | 4 radios (2.4 GHz, 5 GHz low, 5 GHz high, 6 GHz). Up to 8 networks per radio (6 GHz: 7). Each network is bridged to its own VLAN on the uplink. | `1103-1022-webui-e2e-img24` (E0 to E5: 5 networks on 5 GHz low; clients on VLAN 20/30 reach their gateways; a 9th network refused; 0 firmware traps) |
| Wi-Fi | WPA2-PSK, WPA3-SAE (H2E on 6 GHz), OWE | soak `1103-1050-release-soak` (SAE on 5 GHz and 6 GHz, OWE, 5 rotations); OWE rejoin `1103-1035-owe-rejoin` (FSEC-N2 PASS); 6 GHz OWE `1103-1038-owe6g` (O2 PASS, O1 VOID scan); 6 GHz secondary joins: see Known limits |
| Wi-Fi | WPA2-Enterprise (PEAP, TTLS, TLS) on 2.4 and 5 GHz | `1029-1019-ent-arms` (all arms PASS; an earlier image, not rerun on #24) |
| Wi-Fi | 6 GHz at 20, 80, 160 and 320 MHz | `1030-1114-os6g` (C, W80, W160, W320 PASS; the client links at up to 160 MHz; an earlier image) |
| Wi-Fi | Wi-Fi 6/7 switches per radio (D18) | `1103-1030-webui-feat` (HT-5gl and HT-2g: UI and air PASS; F0, LD PASS) |
| Wi-Fi | country FR by default; 5 GHz high (DFS) comes up with CAC | `1103-1037-country-fr` (C0, C1, C4 PASS; C2: see Known limits); `1103-1033-dfs5gh` (D1 PASS, enabled in 60 s with CAC) |
| Wi-Fi | station (client) mode: WPA2 and SAE | `1103-1025-stawds-arms` (C0, S1, S2 PASS) |
| Wi-Fi | monitor interface | `1029-2223-ifaces-arms` (arm M PASS; an earlier image); size limit in Known limits |
| Wi-Fi | airtime fairness (off by default) | `1102-1033-atf-slow` (H-DEMAND PASS) |
| Ethernet | 10 Gbit/s uplink on `rnr0`; Runner hardware offload of Wi-Fi traffic, routed and bridged/VLAN (D12); 802.1Q VLANs; Runner reload | `1103-1040-eth-release-arms` (NW, EL, VL, RLN PASS) |
| Ethernet | LAN switch chip held correctly (unused in release 1) | `1103-1049-eth-lan-arms` (V2, V3 PASS: switch chip identified, reset owned, no crash) |
| Stability | 3 h soaks, every radio | below |

## Measured numbers

| Measurement | Value | Run |
|---|---|---|
| station mode, WPA2-PSK, 5 GHz | up 197 / down 574 Mbit/s | `1103-1025-stawds-arms` S1 |
| station mode, WPA3-SAE, 5 GHz | up 196 / down 535 Mbit/s | `1103-1025-stawds-arms` S2 |
| AP 5 GHz 160 MHz, MT7925 client, 4 streams | down 1431 / up 1103 Mbit/s (1 stream: 1279 / 1091) | `1103-1026-perf-wide-img24` b |
| AP 6 GHz 160 MHz, WPA3-SAE, MT7925 client, 4 streams | down 1450 / up 1103 Mbit/s (1 stream: 1287 / 1095) | `1103-1026-perf-wide-img24` c |
| box CPU during those runs | 16 to 32 % (the box also runs the iperf3 server) | same |
| Ethernet 10 Gbit/s, TCP terminated on the box, shipped Runner settings | up 4.29 / down 5.14 Gbit/s; IPv6 4.12 / 5.24; UDP 1.00 | `1103-1040-eth-release-arms` EL |
| Ethernet over VLAN 20 / 30 | 4.16 / 5.13 and 4.16 / 5.12 Gbit/s | same, VL |
| Runner reload: link back / address back | 7 s / 18 to 19 s, 3 of 3 | same, RLN |
| **soak on #24**, 3 h after the full regression chain, no reboot; 4 radios, 8 networks, 2 clients | 0 crashes, 0 firmware traps and 0 TX-DEAD (dmesg and netconsole, every minute); 0 unplanned disconnects; throughput flat at the offered load (MT7925 84.6 Mbit/s on 5 GHz low, 5 GHz high and 6 GHz; RTL8188 17.0 Mbit/s on 2.4 GHz for 177 minutes, never below half the median); MemAvailable -7.6 MB/h (bar: 8); Runner leak watch 0 events; Runner offload +27.1 M hardware packets. Verdict REFUTED only by the 6 GHz secondary OWE join (probe 1 timeout; see Known limits) | `1103-1050-release-soak` |
| soak, fresh boot (image #22: differs from RC1 by the open-wifi TX doorbell change, the Ethernet leak watch, release mode, first login and the default country) | PASS: 0 crashes, traps and TX-DEAD; 0 unplanned disconnects; MT7925 84.6 Mbit/s, RTL8188 17.0 Mbit/s for 180 minutes; MemAvailable -5.5 MB/h; offload +27.1 M hardware packets; 6 GHz OWE 4 of 5 (1 not seen) | `1103-0254-release-soak` |
| dom1 radio-down without an answer (unload) | 18 of 1200; 0 losses; live radio-downs: 0 in 300 | `1102-1513-rmdown2-xr`, `1102-2205-rmdown2-live` |

## Known limits

- **One-shot boot** (D15): any reset or power cut returns the box to stock
  until `gt-be98-flash.sh boot` runs again (`docs/FLASHING.md`, "Making
  the mainline OS the default boot").
- **6 GHz secondary networks are slow or intermittent to join on non-PSC
  channels.** The 6 GHz radio sends no unsolicited broadcast probe
  responses and no FILS discovery frames. A client on a non-PSC channel
  (the lab uses 5955 MHz) therefore sometimes misses a secondary network
  (soak `1103-1050-release-soak`: 1 timeout and 1 not seen in 3 probes;
  #22: 4 of 5). Fix planned for RC2: broadcast probe responses on PSC
  channels, FILS discovery elsewhere (`br-6g-upr-2026-11-03`). Its first
  arm gave 20 of 20 joins, but no broadcast probe responses were seen on
  air yet, so the fix is still in work (`1103-1507-6gsecupr`).
- **6 GHz: at most 7 networks**, versus 8 on the other radios. RC2 raises
  it to 8: the driver sets the first network's address (open-wifi
  `om-bss0-mac-2026-11-03`), and the generator uses the anchor's address
  block.
- **No input firewall on the uplink** (D22). The box answers ssh and the
  web UI on `rnr0`. Release 1 is an access point on a trusted LAN; do not
  connect `rnr0` to the internet directly. Router mode, with a firewall,
  comes in release 2.
- **Not in release 1** (planned for release 2): wired LAN ports, WAN and
  router mode, PPPoE (it will run on the CPU path, without Runner
  offload), MLO, 4-address repeater. OWE as a station is not supported.
- **Station mode on a radio that also runs an AP**: when the uplink AP
  disappears, the firmware reports no link loss. The station stays
  associated on paper and its traffic is lost until the uplink returns
  (`1102-1235-os-sta` U5/U6; open-wifi `om-sta-linkloss-2026-11-02`).
- **5 GHz high: the wiphy country label can still show the previous ETSI
  country** (for example DE after switching to FR). The firmware applies
  the new country (`1103-1037-country-fr`: REG-CC FR applied); the driver
  does not relabel the wiphy while that radio keeps DFS state. This is
  cosmetic within ETSI. Across regions (for example DE to US), hostapd
  waits about 5 s for the country on every restart of that radio.
- **6 GHz radio (dom1) unload**: about 1.5 % of radio-downs get no answer
  from the firmware (18 of 1200). The driver then takes its dead-firmware
  path after 1 s, so these unloads are slower. Nothing is lost and the
  box stays up (0 losses; `1102-1513-rmdown2-xr`, `1102-2205-rmdown2-live`).
- **Monitor captures miss frames larger than the RX buffer** (about 1.8 kB;
  large A-MSDUs). The firmware drops them before the host sees them.
  Monitor mode is a diagnostic feature (open-wifi ledger IF-T14-B1).
- **Airtime fairness helps a slow client only when it has a backlog.**
  A TCP flow that ends on the box rarely builds one. Gains:
  UDP +0.26, forwarded TCP +0.18, TCP terminated on the box +0.01
  (`1102-1033-atf-slow`).
- **Jumbo frames: MTU at most 1970** on the Runner ports (stock: 10272)
  (`1102-1015-eth-release-arms`, MTU M4).
- **Open issue, not seen on RC1:** in one soak, run after the full
  regression chain without a reboot on image #22, 2.4 GHz bridged traffic
  stopped completely while the client stayed associated. It did not
  reproduce on a fresh boot of #22 (`1103-0254-release-soak`) or on #24
  (`1103-1050-release-soak`, with the Runner leak watch at 0). Its rate is
  unknown (the bisect `1103-0743-bh24-2g-bisect` did not reproduce it).
  The leak watch in the Ethernet driver (`b3ca337`) counts this class of
  drop.

## Changes since image #16 (the previous landed reference)

- **gt-be98-buildroot** `17b5523..a3ebb9ea` (33 commits):
  - release build mode (`RELEASE=1`, `release-check.sh`, host keys made on
    the box);
  - release flashing (`docs/FLASHING.md`, `flash/gt-be98-flash.sh`, kit
    builder);
  - Wi-Fi station (uplink) mode;
  - Wi-Fi 6/7 per radio;
  - DFS-without-country warning, and default country FR;
  - OWE without PMKSA caching;
  - 6 GHz secondary BSSIDs from the anchor's nontransmitted BSSIDs;
  - LED lookup by driver name;
  - wired-LAN groundwork (pinctrl, switch reset; off in release 1);
  - pins of open-wifi `18e96ed2` and open-ethernet `b3ca337`.
- **open-wifi** `09fbee8b..18e96ed2` (20 first-parent commits):
  - remove-time timeout without device access (RMDOWN fix A);
  - HE and EHT follow hostapd;
  - beacon updates without a tail keep the security block (CB-NOTAIL);
  - per-peer power-save answer counters;
  - TX doorbells from a dirty-ring list (RUNNER-B2, lower CPU);
  - triage of the defect ledger (224 rows).
- **open-ethernet** `95657d5..b3ca337` (8 commits):
  - pinmux for the external MDIO and the 10G PHY port;
  - RTL8372 switch reset and read-only monitor;
  - Runner Wi-Fi leak watch.
- **webui** `d8c4824..9bb193a0` (16 commits):
  - every shipped Wi-Fi feature configurable;
  - Wi-Fi uplink (station) and routed networks;
  - Wi-Fi 6/7 per radio;
  - DFS-without-country warning;
  - first login with a one-time setup token;
  - default country FR.

## Reporting a problem

Include:
- `gt-be98-status` (on mainline), or `gt-be98-flash.sh status` (on stock);
- the post-code byte read on stock after a failed boot;
- `ml-bootfs.info`;
- what was done since the boot.
