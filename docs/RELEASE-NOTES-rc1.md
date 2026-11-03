# GT-BE98 mainline OS 1.0-rc1 - release notes (DRAFT)

Date: 2026-11-03 · Status: **release candidate under test** (regression and
3 h soak running on image #22). Every `<...>` is still open.

Evidence is named by the orchestrator's run directory (`MMDD-HHMM-<arm>`,
kept on the orchestrator's machine, not in this repository). A number
comes with the run that measured it. "Not measured" means not measured.
It never means 0. Results from image #21 hold for #22 only for the parts
that #22 did not change (below).

## Images

| File | sha256 |
|---|---|
| `rootfs.squashfs` | `925634238bd99d03a7cae26b55ba2a1e605f4388ebf19ed7510e2f29fd64ef7a` |
| `ml-bootfs.itb` | `7d326469106cc54de31f9aaff7ea56ca433571645ad17549535efc8222faac3e` |

Build id (DT): `20261102T220744Z-c20bade5b35f-rw-jffs`

**These are the images under test, and they were built in lab mode**
(`ml-bootfs.info` has no `release mode: yes`). They carry the lab SSH
keys and host keys and the lab rootfs URL, so they must not be handed
over. The image that is handed over is a `RELEASE=1` rebuild of the same
pins (`docs/RELEASE-BUILD.md`). It has its own sha256s:
`<release rootfs sha256>`, `<release itb sha256>`, build id `<...>`, and
`release-check: PASS` `<run>`.

Built from:

| Component | Commit |
|---|---|
| gt-be98-buildroot | `img22-2026-11-03` `be271e6` (= `mainline-os` `8ea0f84` + 6 GHz secondary-BSSID fix `43e1ce7` + wired-LAN pin `e51a4d1`) |
| open-wifi (`bca_pcie_ipc.ko`) | `49d3137a` |
| open-ethernet (Runner, kernel series, `rtl8372.ko`) | `3ce4816` |
| web UI (gt-be98-webui-go) | `ef23acab` (release: `<with the first-login token, wu-first-login-2026-11-02 ac3de01 or its landed form>`) |
| Linux / Buildroot | 7.2.9 / 2026.08 |

Release configuration (owner decision D14): `RELEASE=1`. The recipient's
SSH public keys are built in. SSH host keys are made on the box at first
boot, and the web UI password is set at first login with a one-time
token. `ROOTFS_URL` is empty, `NAND=rw-jffs`.

## Scope of release 1 (owner decisions)

- D15: the mainline OS is booted **one-shot** from stock. Every reset,
  including a power cut, returns the box to the stock firmware.
- D16: **access point with a wired uplink**. The 10 Gbit/s port (`rnr0`)
  is the uplink (DHCP client). There is no wired LAN switch and no
  router/WAN mode.
- D17: **no MLO** (Wi-Fi 7 multi-link).
- D18: Wi-Fi 6 (HE) and Wi-Fi 7 (EHT) can be switched per radio.

## Installing, booting, going back

Follow `docs/FLASHING.md`. Verify the sha256s above, then flash slot 1
from stock with `gt-be98-flash.sh`. Boot it once (`gt-be98-flash.sh
boot`), and `reboot` to return to stock. The next boot needs
`gt-be98-flash.sh boot` again.

End-to-end flashing test (stock, flash, mainline, stock, mainline):
`<PASS/REFUTED/VOID, run, date>`. It is pre-registered in
`docs/PREREG-RELEASE-FLASH-E2E-2026-11-02.md` and has not run yet.

## What works

All rows are box results. Image #21 differs from #22 only in the 6 GHz
secondary-BSSID derivation (`43e1ce7`), the wired-LAN switch reset (off
by default, not part of release 1) and the open-wifi ledger fixes
(`49d3137a`: beacon updates without a tail, power-save answer counters).

| Area | Feature | Evidence |
|---|---|---|
| Boot | one-shot boot from slot 1, rootfs read from vol 4 and sha256-checked | the lab procedure every image up to #22 is flashed with (orchestrator log, 11-03 #22); release helper: `<e2e run>` |
| Wi-Fi | 4 radios: 2.4 GHz, 5 GHz low, 5 GHz high, 6 GHz; up to 8 networks per radio (6 GHz: 7, below), each bridged to its own VLAN on the uplink | #21 `1102-1435-webui-e2e-img21` (E0 to E5: 5 networks on 5 GHz low, VLAN 20/30 clients ping their gateways, a 9th network refused, 0 firmware traps); #22 `1102-2242-webui-e2e-img22` `<result>` |
| Wi-Fi | security: WPA2-PSK, WPA3-SAE (H2E on 6 GHz), OWE on 2.4/5 GHz | soak #21 `1102-1902-release-soak` (SAE on 5 GHz and 6 GHz, OWE on 5 GHz low, 5 rotations); OWE rejoin `1102-1448-owe-rejoin` (FSEC-N2 PASS) |
| Wi-Fi | OWE on 6 GHz | **refuted on #21** (join timeout, soak `1102-1902-release-soak`); #22 carries the fix (`43e1ce7`): `<owe6g run on #22>` |
| Wi-Fi | WPA2-Enterprise (PEAP, TTLS, TLS) on 2.4 and 5 GHz | `1029-1019-ent-arms` (all arms PASS, 5 GHz 213 to 224 Mbit/s) - an older image: `<rerun on #22 or mark as carried over>` |
| Wi-Fi | 6 GHz at 20/80/160/320 MHz | `1030-1114-os6g` (C, W80, W160, W320 PASS; the client links at up to 160 MHz) |
| Wi-Fi | Wi-Fi 6/7 switches per radio (D18) | `1102-1443-webui-feat` (HT-2g UI and air PASS; HT-5gl UI PASS, beacon read lags one step, instrument issue) |
| Wi-Fi | 5 GHz high (DFS) comes up once a country is set | `1102-1446-dfs5gh` (D0 cause reproduced, D1 enabled in 60 s with CAC) |
| Wi-Fi | station (client) mode: WPA2 and SAE join, repeater with NAT | `1102-1437-stawds-arms` (S1, S2 PASS); `1102-1235-os-sta` (U1, U4 PASS) |
| Wi-Fi | airtime fairness (off by default) | `1102-1033-atf-slow` (H-DEMAND PASS) |
| Ethernet | 10 Gbit/s uplink on `rnr0`, Runner offload for routed and bridged/VLAN Wi-Fi traffic (D12), 802.1Q VLANs, driver reload | `1102-1450-eth-release-arms` (NW, EL, VL, RLN PASS) |
| Web UI | first-login setup token, no open API before a password | `<run on the release image>` |
| Persistence | settings and host keys saved in stock's `/jffs` | `<run on the release image>` |

## Measured numbers

| Measurement | Value | Run (image) |
|---|---|---|
| station mode, WPA2-PSK, 5 GHz | up 196 / down 526 Mbit/s | `1102-1437-stawds-arms` S1 (#21) |
| station mode, WPA3-SAE, 5 GHz | up 197 / down 562 Mbit/s | `1102-1437-stawds-arms` S2 (#21) |
| AP 5 GHz 160 MHz, MT7925 client, 4 streams | down 1413 / up 1097 Mbit/s (1 stream: 1252 / 1091) | `1102-1439-perf-wide-img21` b (#21) |
| AP 6 GHz 160 MHz, WPA3-SAE, MT7925 client, 4 streams | down 1270 / up 1103 Mbit/s (1 stream: 1262 / 1094) | `1102-1439-perf-wide-img21` c (#21) |
| box CPU during those runs | 16 to 31 % (the box also runs the iperf3 server) | same |
| Ethernet 10 Gbit/s, TCP terminated on the box, shipped Runner settings | up 4.30 / down 5.14 Gbit/s; IPv6 4.16 / 5.24; UDP 1.00 | `1102-1450-eth-release-arms` EL (#21) |
| Ethernet over VLAN 20 / 30 | 4.20 / 5.12 and 4.19 / 5.13 Gbit/s | same, VL |
| Runner reload, link back / address back | 6 to 7 s / 19 s, 3 of 3 | same, RLN |
| soak, 3 h, 4 radios, 8 networks, 2 clients | 0 crashes, 0 firmware traps, 0 TX-DEAD (dmesg and netconsole); 0 unplanned disconnects; throughput flat (84.6 and 17.0 Mbit/s offered-load runs, 0 dips); MemAvailable -0.5 MB/h; Runner offload +26.7 M packets | `1102-1902-release-soak` (#21; verdict REFUTED only by the 6 GHz OWE join) |
| soak on #22 | `<crashes / traps / TX-DEAD / disconnects / memory slope / throughput>` | `<#22 soak run>` |
| regression on #22 | `<e2e, S1/S2, perf b/c, eth-release>` | `<runs>` |
| reboot to ssh / rollback to stock | `<s>` / `<s>` | `<e2e flash run>` |

## Known limits

- **One-shot boot** (D15): any reset or power cut returns to stock until
  `gt-be98-flash.sh boot` runs again (`docs/FLASHING.md`, "Making the
  mainline OS the default boot").
- **6 GHz: at most 7 networks**, versus 8 on the other radios. The 6 GHz
  secondary BSSIDs take the anchor's nontransmitted BSSIDs (`43e1ce7`).
  Pending D21.
- **The country must be set for 5 GHz high.** Without a country, hostapd
  turns off every DFS channel, and 5 GHz high is all DFS, so that radio
  stays down. The UI warns about it. Pending D20 (a default country).
- **Station mode on a radio that also runs an AP**: when the uplink AP goes
  away, the firmware reports no link loss. The station stays "connected"
  and its traffic is lost until the uplink returns (`1102-1235-os-sta`
  U5/U6, `1102-1420-sta-linkloss`; analysis in open-wifi
  `om-sta-linkloss-2026-11-02`). A station alone on its radio detects
  the loss, but its re-join failed in the lane's reading (`<run>`; under
  analysis).
- **No MLO** (D17).
- **No wired LAN**: only `rnr0` (10 Gbit/s uplink) is used. The other
  ports and the switch are off (D16). There is no router/WAN mode.
- **Jumbo frames: MTU at most 1970** on the Runner ports (stock: 10272)
  (`1102-1015-eth-release-arms`, MTU M4).
- **Radio unload on the 6 GHz radio (dom1)**: about 1.5 % of radio-downs
  get no answer from the firmware (18 of 1200, `1102-1513-rmdown2-xr`).
  The driver then takes the dead-firmware path after 1 s, so the unload is
  slower but loses nothing (0 losses in 1200; live radio-downs 0 events in
  300, `1102-2205-rmdown2-live`).
- **Monitor mode: frame size limit**: `<the limit and its run>`.
- **Airtime fairness does not raise a slow client that sends little**:
  the firmware gives a slow client more airtime only when that client has
  a backlog. A TCP flow terminated on the box rarely builds one, so the
  gain there is about 0 (`1102-1033-atf-slow`: UDP +0.26, forwarded TCP
  +0.18, box-terminated TCP +0.01).
- **OWE as a station** is not supported. **4-address (WDS) repeater** is
  not working (parked).
- The rootfs holds proprietary vendor firmware: **never publish the
  images or the kit** (`docs/RELEASE-BUILD.md`).
- `<others found by the #22 regression and soak>`

## Changes since image #16 (the previous landed reference)

- `<commit ranges: gt-be98-buildroot 17b5523..be271e6, open-wifi
  09fbee8b..49d3137a, open-ethernet 95657d5..3ce4816, webui
  d8c4824..ef23acab (+ first-login), one line each>`

## Reporting a problem

Include: `gt-be98-status` (on mainline), or `gt-be98-flash.sh status` (on
stock), the post-code byte read on stock after a failed boot,
`ml-bootfs.info`, and what was done since the boot.
