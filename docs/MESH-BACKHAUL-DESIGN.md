# Wi-Fi mesh / Multi-AP backhaul: design and feasibility (Phase A, for owner review)

Status: DESIGN ONLY. No code, no box run. Base: buildroot `br-routed-gw-2026-11-17` 7e62e5e,
open-wifi main 55013e13 (the repeater code is unchanged since a8860aec), web UI
`wu-gateway-2026-11-17-r` e4315be.

Goal (owner, 11-17): a second GT-BE98, or another AP, extends the network over Wi-Fi, like stock's
AiMesh / EasyMesh. The leaf box serves the same SSIDs and carries every VLAN network.

Tags: **[READ]** read in code, firmware strings or a box log, cited. **[MEAS]** measured on the box,
run cited. **[HYP]** an inference an arm still has to settle. **[PROPOSAL]** design.

---

## 0. Summary

1. **Most of the radio half exists and has passed on silicon.** The repeater lane (11-03..11-05)
   landed both ends of a 4-address link in the driver and a device-SME Multi-AP patch in hostapd.
   The same-box loop (box station on one radio, box backhaul AP on another, a client behind the
   station) passed ping 20/20 on 11-05 [MEAS `1105-0152-repeater-rl2b`]. The OS can already be the
   *leaf* of ONE untagged network (`repeater=4addr|multiap` + `repeated=1`).
2. **What is missing is mostly OS work:**
   - the root side: no way to configure a backhaul BSS (`wds=` is refused, `feature wds 0`);
   - VLAN trunking across the link: the leaf carries one untagged network, never a trunk;
   - re-serving every network on the leaf.
3. **Driver gaps that matter for a product backhaul:**
   - the AP_VLAN drops frames on a busy ring instead of applying back-pressure (a throughput
     problem under TCP load);
   - nobody has measured 802.1Q-tagged frames, a backhaul BSS on a secondary bsscfg, SAE, 6 GHz, or
     throughput;
   - nothing has re-run the loop since 11-05.
4. **Recommendation: a static backhaul (Multi-AP backhaul BSS + 802.1Q over the 4-address link),
   configured from the web UI on both boxes. Not prplMesh/EasyMesh for now** (§4). Stock AiMesh
   has the same shape (hidden dedicated backhaul BSS, Broadcom DWDS link, 802.1Q per network) and
   ASUS does not ship EasyMesh on BE models (§2.4).
5. **The RT-BE92U as Media Bridge** becomes a Broadcom `wet` (MAC-NAT) + `dwds` client. Against
   our AP it should be a single 3-address station for one network. That needs no change and is no
   mesh leaf; in AP mode it can test our station half (§1.4, M7/M8).
6. **The PVE MT7925 cannot test this.** Its Linux driver clears both 4-address wiphy flags (§5).
   The RTL8188 can be a third-party 4-address backhaul station (2.4 GHz only), and the box can loop
   to itself across radios. Together they cover every root-side and OS cell before a second box exists.

---

## 1. The minimal useful feature

### 1.1 Topology [PROPOSAL]

```
   ROOT box (gateway, wired uplink)                       LEAF box (no wired uplink)
   brwifi<N> per network ── rnr0.<vid> (wired trunk)      brwifi<N> per network
        │                                                       │
        └── bh<k>.<vid> ── AP_VLAN bcawlX.staA  ~~~ air ~~~  bcawlY (4addr STA) ── bhs.<vid> ──┘
                           (hostapd wds_sta, created         (wpa_supplicant
                            at the backhaul STA's assoc)       multi_ap_backhaul_sta=1)
   backhaul BSS: hidden, multi_ap=1, SAE/WPA2, 5 GHz (non-DFS) or 6 GHz
   fronthaul BSSes: every network's SSID             fronthaul BSSes: the SAME SSIDs/security
```

- **One backhaul link = one 4-address station** on the leaf, joined to a dedicated **backhaul BSS**
  on the root. The link is a Linux trunk port at each end:
  - on the root, the AP_VLAN `<bss>.sta<aid>` that hostapd creates at the association;
  - on the leaf, the 4-address station netdev.
- **Every network crosses the link as an 802.1Q VLAN**, `<port>.<vid>`. This is the same model as
  the wired trunk `rnr0.<vid>` that `gt-be98-l2` already builds (`sbin/gt-be98-l2:11-17`). The
  management network crosses untagged, so the leaf gets its management address from the root by DHCP.
- **Gateway (routed) networks** have no VLAN on the wire today (`gt-be98-l2` state `trunk -`). On the
  link each one takes a *backhaul VID*: its configured VID if it has one, else one the root allocates.
  The VID map is part of the leaf's configuration. The leaf bridges it and never routes it: the root
  stays the gateway, DHCP server and firewall.
- **The leaf serves the same SSIDs:** every network's `bands=` on the leaf, in its local
  `brwifi<N>`. A network's leaf bridge has exactly one uplink, `bhs.<vid>`, in place of
  `rnr0.<vid>`. Wired jacks on the leaf (`rnr1..rnr3` access ports) join the same bridges, so a
  wired device behind the leaf works too.
- **Loop rule:** a leaf never has both a wired trunk and a backhaul trunk for one VID. netguard
  already refuses a trunk VLAN in a repeater bridge (`sbin/gt-be98-netguard:313-314`). The same guard
  generalises to "one uplink per network bridge".

### 1.2 Why 4-address + 802.1Q, not the alternatives

| option | carries VLANs | works with our driver today | interop | verdict |
|---|---|---|---|---|
| 4-address (Multi-AP backhaul BSS) + 802.1Q sub-interfaces | yes: Linux tags | both halves built and passed (untagged) | any hostapd/mac80211 Multi-AP peer; EasyMesh R2 frames are also 802.1Q on the backhaul | **chosen** |
| One 4-address link per network (one backhaul STA per VLAN) | yes, by multiplying links | each link needs a STA vif; the leaf has one STA per radio | none needed | wasteful: N associations, N times the airtime overhead |
| 3-address station + routed networks (exists: `routed=`) | no (L3 behind NAT) | yes | any AP | already shipped for "Wi-Fi WAN". Not a mesh: separate subnets, no roaming |
| Proxy-STA / MAC-NAT (Broadcom psta / wet) | no | firmware has `wet_enab`; no proxy-STA iovar in our dongle image (its `psta` strings are the MLO per-STA profile) [READ] | stock-only | only relevant to interop with a stock ASUS client (§1.4) |
| 802.11s mesh | yes | firmware has no 802.11s path [READ: no HWMP / mesh-path strings; `MESH` appears only in ucode symbol names] | mac80211 mesh | not possible on a FullMAC dongle |

### 1.3 Scope of the minimal feature

- One root and one leaf, one backhaul hop. A chain (leaf of a leaf) needs nothing new in the
  driver; it is deferred to make the OS rules simpler.
- Static configuration on both boxes. The backhaul SSID and key are generated on the root and
  copied to the leaf by hand (web UI export/import) or by WPS. No controller.
- Roaming between root and leaf stays plain 802.11 roaming: same SSID and key, same VLAN. 802.11k
  neighbour lists and 802.11v steering already exist per box (`sbin/gt-be98-wifi-steer`). Across
  boxes they need the other box's neighbour entries, which is phase C.
- Out of scope: backhaul band switching, multiple uplinks, airtime-based topology optimisation.

### 1.4 The RT-BE92U (owner's planned Media Bridge client)

Stock ASUS firmware (§2.4) puts a Media Bridge's radio in Broadcom `wet` (MAC-NAT) mode with `dwds=1`.
It never uses proxy STA on HND builds, and it never sends a Multi-AP element.

- **Against our AP as it is today** (no DWDS on the AP bsscfg) the BE92U should fall back to one
  3-address station with MAC-NAT. Its wired devices then sit in the network of the SSID it joined.
  That needs no change from us [HYP: the fallback is inferred from the closed `wl` driver; arm M7
  reads it].
- **It will not trigger our root half.** hostapd arms a link only for a Multi-AP backhaul station.
- **It carries one network, untagged, never a trunk.** It is a useful Broadcom peer for tests (M7, M8),
  not a leaf of this mesh.
- A true DWDS link with a stock ASUS box (AiMesh-style) is possible in principle: both firmwares have
  DWDS. It needs a second driver mode in which the firmware creates the per-peer link itself
  (`dwds=1` on the AP bsscfg) and the driver makes the per-link netdev from `WLC_E_IF` (stock's
  `wds<u>.<b>.<n>`). That is option 2 of open-wifi STA-WDS §3, deferred to phase C (D-MESH8).

---

## 2. Driver and firmware: what exists, with evidence

### 2.1 Root half (AP side of the link): built, passed untagged

| piece | where | evidence |
|---|---|---|
| hostapd device-SME Multi-AP: `check_multi_ap()` in `hostapd_notif_assoc`, Multi-AP element in the association response, `hostapd_set_wds_sta()` for a backhaul STA on a `multi_ap=1` + `wds_sta=1` BSS, spurious class-3 registration | `board/gt-be98-mainline/patches/hostapd/0001-device-sme-multi-ap-wds-sta.patch` | [MEAS] A1 PASS 11-05 (`1104-2244`/`1105-0019` arms, image #27) |
| `WIPHY_FLAG_4ADDR_AP` and AP_VLAN as a software iftype | open-wifi `driver/bca_cfg80211.c:1521-1522` | nl80211 lets hostapd create `<bss>.sta<aid>` |
| AP_VLAN netdev (no firmware bsscfg; the link's L2 port) | `driver/bca_cfg80211_iface.c:367-395` | [MEAS] A1B: bridge learned the peer on `bcawl3.sta0` |
| `struct bca_wds` per radio, OO lifecycle, ≤ 8 links per radio (`BCA_WDS_MAX`) | `driver/bca_wds.{h,c}`, `bca_wds.h:92` | debugfs `bca/domN/wds` |
| arm = `dwds_config {enable 1, mode 0, ea}` at `.change_station(params->vlan)` | `bca_wds.c`, `bca_iovars.def:155` | [MEAS] A0b: WLC_E_IF add role WDS, new rte ifidx, ping 10/10; without it every 4-address data frame is dropped (A0-DROP) |
| RX on the link's rte ifidx goes up its AP_VLAN; unicast TX goes on a **link ring set** created on the link's own if_id | `bca_wds_rx_ndev`, `bca_wds_vlan_peer`, `bca_pt_link_get` | [MEAS] A1F PASS-AP-TX-OK: a station *behind* a mac80211 4-address peer 20/20 (it was 0/20 on the peer's if_id-0 ring) |
| End-to-end loop: box STA → box backhaul AP, RTL behind the box's front AP | — | [MEAS] RL2B ping 20/20, `wds.rx_link 36 tx_link 27`, FDB: RTL on `bcawl0.sta0` (`1105-0152-repeater-rl2b/summary.txt`) |

### 2.2 Leaf half (4-address station): built, passed

- `WIPHY_FLAG_4ADDR_STATION` (`bca_cfg80211.c:1512`). The station's nl80211 4addr flag and
  `multi_ap_backhaul_sta` become the firmware's `dwds` / `map=4` / `map_profile`, written in the
  join's core-down window (`bca_iovars.def:151,201-202`; STA-WDS §29-30 on open-wifi main).
- [MEAS] W1 PASS: a Multi-AP backhaul association with the box's own traffic. RL2B: a client's
  foreign SA carried across the link.
- The OS sets 4addr **before** the join and runs `wpa_supplicant -b <bridge>`
  (`sbin/gt-be98-wifi-sta:140-160`), which is what the firmware needs.
- [READ] Plain 4-address without Multi-AP (`repeater=4addr` into a `wds_sta=1` AP) has no trigger on
  our root: the firmware drops the data before the host sees an "unexpected 4-address frame"
  (A0-DROP). **Our root therefore requires a Multi-AP backhaul STA.** Stock instead sets `dwds=1`
  on the AP bsscfg and lets the firmware create each peer's link (§2.4). That mode is unbuilt
  here (§1.4).

### 2.3 Firmware capabilities read from the 6726b0 image [READ, `strings` of `rtecdc.bin`]

- 4-address machinery: `dwds`, `dwds_config`, `wlc_dwds_addsa`, `wds%d.%d.%d` (stock's
  per-link interface name), `wds_type`, `wds_enable`, `wdstimeout`, `wds_wpa_role`, `dwds_lb_filter`.
- Multi-AP R2 (EasyMesh profile 2):
  - `map`, `map_profile`, `map_8021q_settings`;
  - "Trying to set Multi-AP Default 802.1Q Settings on a non Backhaul AP interface";
  - "denied multiap backhaul sta association due to profile 1/2 disallowed";
  - "not allowed for normal sta to join backhaul BSS";
  - "Block Non-MAP STAs feature is only for backhaul BSS".

  ⇒ **the firmware enforces backhaul-BSS admission itself and knows the 802.1Q default setting.**
- VLAN handling in the data path: `vlan_mode` and "short VLAN frame (%d)". **[HYP] the firmware
  parses 802.1Q tags on TX/RX** (Broadcom's `vlan_mode` strips a tag and uses its PCP as the
  802.1d priority in some modes). Whether a tagged frame crosses the link intact is **the first
  arm to run** (§5, arm M1).
- No proxy-STA iovar (the `psta` strings are MLO per-STA-profile parsing); `wet_enab` present. No 802.11s.

### 2.4 Stock (AiMesh / EasyMesh / Media Bridge) [READ from the Asuswrt-Merlin source of the BE models; daemons and `wl` are closed, so lines marked HYP come from their strings]

**AiMesh uses Broadcom DWDS, not Multi-AP or EasyMesh.**
- Build flags for GT-BE98 and RT-BE92U: `AMAS=y PROXYSTA=y DWB=y FRONTHAUL_DWB=y`, and `WBD` unset
  (`src-rt-5.04behnd.4916/target.mak:405-438`). The GT-BE98 router config has
  `# RTCONFIG_WBD is not set` and `RTCONFIG_MLO_BH=y`.
- `generate_wl_para()` sets `dwds=1` on the primary interface (`rc/sysdeps/init-broadcom.c:9793-9805`)
  and on every `wlX.Y` (`:10577-10589`), on the CAP and the RE alike.
- The driver makes one `wds<unit>.<bss>.<n>` interface per DWDS peer. The `rc` hotplug bridges it
  (`rc/lan.c:3295`, `:3366` `brctl addif`, `:3374` `wds_enable 1`).
- No ASUS code writes `wlX_map`. The `map` / `map_profile` / `map_8021q_settings` knobs exist in
  `wl`/`wlconf` but are unused on these models.
- Daemons: `cfg_server`/`cfg_client`, `amas_wlcconnect` (uplink choice by AiMesh cost/RSSI, with a
  vendor check), `amas_bhctrl` (Ethernet vs Wi-Fi backhaul), `amas_apg`, `obd`.

**Dedicated backhaul BSS (DWB).**
- It is a separate virtual BSS, `wlX.1` (or `.4`/`.5` with MLO) (`shared/sysdeps/amas/amas_dwb.h`,
  `cfg_mnt/cfg_dwb.h`).
- [HYP, strings] it is hidden, with its own random SSID and key (`amas_gen_random_backhaul_security`),
  SAE on 6 GHz and PSK2/SAE on 2.4/5 GHz, GCMP-256 between Wi-Fi 7 peers.
- ASUS vendor IEs are pushed into beacons (`/tmp/dwb_vsie`, `cfg_mnt/cfg_onboarding.h:10`).

**VLANs and guest networks across AiMesh** are ASUS's own 802.1Q sub-interfaces on the DWDS links.
- [HYP, strings of `amas_apg.o`]: `apg_create_wl_vlan`, `apg_wds_vlan_ifnames`, `vlan_trunk_rl`.
- `rc/lan.c:3350-3363` keeps those VLAN interfaces out of `br0`.
- EasyMesh traffic separation (`map_8021q`) is not used.

⇒ **This is the same shape as this design:** a hidden dedicated backhaul BSS, a 4-address link,
802.1Q per network on top.

**EasyMesh is in the SDK and not shipped.**
- Broadcom's `ieee1905/` and `wbd2/` (Wi-Fi Blanket) are present as sources.
- ASUS builds them only under `RTCONFIG_WBD` (`router/Makefile:1333`), which is off for these
  models. `rc/rc.c:197-262` even unsets the `wbd_*` keys.
- The GT-BE98 rootfs has no `wbd*` or `ieee1905` binary.

**Media Bridge and Repeater.**
- The wizard writes Media Bridge as `sw_mode=3 wlc_psta=1` and Repeater as `wlc_psta=2`
  (`www/.../QIS_V3/mobile/js/handler.js:3300-3303`, `:3237-3240`).
- Both become `wl<band>_mode=wet` plus `dwds=1` on HND (`init-broadcom.c:9742-9747`, `:9799`).
- Media Bridge disables the primary BSS and drops `wlX.1` from the LAN. Repeater bridges `wlX.1`
  as an AP with `psr_mrpt=1`.
- ASUS rc never writes `multi_ap=`, `multi_ap_backhaul_*` or `wds_sta=`.
- [HYP] Against a non-Broadcom (or non-DWDS) AP, a Media Bridge is one 3-address station with
  MAC-NAT. AiMesh will not form against a non-ASUS AP.

### 2.5 Gaps for a product backhaul (driver)

| # | gap | evidence | size |
|---|---|---|---|
| G1 | **AP_VLAN has no back-pressure.** A frame the ring refuses is dropped (`bca_busy_or_drop`, `driver/bca_netdev.c:2132-2146`: "an AP_VLAN … cannot take a BUSY back: drop"). Fine for ping; under a TCP flow that saturates the link it turns ring-full into loss. A backhaul carries **all** of the leaf's traffic. | [READ] | M: give the AP_VLAN a real queue that the link ring set stops and wakes (the station netdev's model) |
| G2 | **802.1Q-tagged frames over the link have never been sent.** `vlan_mode` / "short VLAN frame" suggest the firmware touches tags. | [READ], unmeasured | arm M1; S if the firmware leaves tags alone (set `vlan_mode` off on the link's bsscfg if needed) |
| G3 | **Backhaul BSS on a secondary bsscfg.** Every measured link was on bsscfg 0 (RL2B `WDS-LINK[bsscfg 0]`). A dedicated hidden backhaul BSS is normally a secondary BSS. The AP_VLAN takes the primary as its reference (`bca_cfg80211_iface.c:377-378`); the link records its own bsscfg. | [READ], unmeasured | arm M2 |
| G4 | **SAE / 6 GHz backhaul.** Measured links were WPA2. 6 GHz requires SAE, so a 6 GHz backhaul needs the SAE station on the 4-address path. | unmeasured | arm M3 |
| G5 | **Throughput.** Every link measurement was ping. Runner offload stays off the AP_VLAN RX (REPEATER-APHALF §RL2), so the CPU path carries the backhaul. | unmeasured | arm M4: iperf3 over the loop, both directions |
| G6 | **Disarm refused:** `dwds_config enable=0` returns -2 BADARG on leave (`RL2B-dmesg`: `IOVAR-FAIL … dwds_config … ret=-2`). Harmless per the repeater note (no SCB is left), but a link table that never frees is a defect at 8 links over time. | [MEAS] | S: read the disarm layout from the handler (ROM), or rely on WLC_E_IF del |
| G7 | **No regression since 11-05.** About 12 days of driver changes since then (S3.x refactor, MLO, DFS, Runner). The loop has not been re-run. | [READ] ORCH-STATUS | the first arm, M0 |
| G8 | Interface names: hostapd names the link `<bss>.sta<aid>` (`driver_nl80211.c:9329`). A VLAN on it (`bcawl1.sta1.4094`) can pass IFNAMSIZ 15. | [READ] | OS: create VLANs with short names `bh<k>.<vid>` (§3) |

None of G1-G8 needs a new module parameter: everything follows hostapd / wpa_supplicant config.

---

## 3. OS and web UI changes [PROPOSAL]

### 3.1 Generator (`gt-be98-wifi-gen`) and plan

- **Root:** a `backhaul=` block (or network flag `backhaul=1` on a dedicated network). It renders a
  hidden BSS (`ignore_broadcast_ssid=1`) on the chosen radio with:
  - `multi_ap=1`, `wds_sta=1`, `multi_ap_profile=2`, `multi_ap_vlanid=0` (no firmware default VLAN:
    Linux does the tagging);
  - SAE (WPA2/SAE mixed on 5 GHz, SAE only on 6 GHz).

  This replaces the reserved `wds=` key (`gt-be98-wifi-gen:355-358`) and sets `feature wds 1` /
  `feature backhaul 1` (now `feature wds 0`, `:548`). Optional: `multi_ap_backhaul_ssid` /
  `multi_ap_backhaul_wpa_psk` on a fronthaul BSS so WPS can onboard a leaf (phase C).
- **Leaf:** `station=` with `repeater=multiap` and a new `trunk=1`. The station becomes a *trunk*
  for every network instead of a port of one `repeated=` network. `repeated=1` stays for the
  single-network case (and the BE92U-style uplink to a third-party AP).
- New plan lines: `backhaul <bss> <radio>` (root) and `bhtrunk <stadev>` (leaf). The VID map is
  `network=<id> vlan=<vid>`, already present for VLAN networks, plus `bhvid=<vid>` for gateway
  networks.

### 3.2 L2 (`gt-be98-l2`), netguard and the hostapd event hook

- `gt-be98-l2` accepts a Wi-Fi trunk. Today `valid_trunk()` is `rnr[0-3]` only
  (`sbin/gt-be98-l2:88`). The change: a trunk name class `bh*` and a sub-interface created as
  `ip link add link <port> name bh<k>.<vid> type vlan id <vid>`, with short names (G8).
- **Root, dynamic:** the AP_VLAN exists only while the leaf is associated. hostapd announces it
  (`WDS-STA-INTERFACE-ADDED ifname=… sta_addr=…`, `wpa_ctrl.h:474`, emitted from
  `drv_callbacks.c:2423`). A small `hostapd_cli -a` action script (or the existing supervision in
  `init.d/gt-be98-wifi`) calls `gt-be98-l2 trunk-add <ap_vlan>` / `trunk-del`, which:
  - adds `bh<k>.<vid>` to every network bridge that has a backhaul VID;
  - puts the untagged AP_VLAN in the management bridge.

  hostapd's own `bridge=`/`wds_bridge=` must then be **unset** for the backhaul BSS, so that hostapd
  does not also enslave the untagged port.
- **netguard:** admit `bh<k>.<vid>` exactly as a listed trunk VLAN, and the untagged AP_VLAN only in
  the management bridge. Keep the loop guard: a network bridge has one uplink (wired trunk VLAN or
  backhaul VLAN), never both. Refuse an AP_VLAN whose peer is not the configured leaf MAC
  (`multi_ap_client_disallow` and the firmware's "normal sta to join backhaul BSS" refusal already
  keep non-Multi-AP stations out).
- **Leaf, static:** the 4-address station is the trunk. It must be in 4addr mode before the join
  (existing `gt-be98-wifi-sta:140-160`). The untagged station is a port of the management
  bridge only, and its `bhs.<vid>` sub-interfaces are ports of the network bridges. Linux delivers
  a tagged frame to the VLAN device before the bridge's rx handler sees it, the same as
  `rnr0` / `rnr0.<vid>` today. ⚠ wpa_supplicant `-b` must name the management bridge (EAPOL
  arrives untagged), as the repeater does today.
- **Leaf services:** no DHCP server, no NAT, no WAN. The management address comes from DHCP on the
  untagged link, and gateway networks are bridged. This is the existing "access point mode" plus
  the trunk. The leaf's fronthaul channel on the backhaul radio follows the root (AP+STA on one
  radio, STA-WDS §2). ⚠ If the root's backhaul is on a DFS channel, the leaf AP on that radio
  inherits the CAC/radar rules of the DFS-owner work.

### 3.3 Web UI (webui-go)

- A "Mesh" page with a role select: **Off / Root / Leaf**.
- **Root:**
  - backhaul radio (5 GHz or 6 GHz);
  - backhaul SSID and key, generated;
  - an "export leaf config" blob: backhaul SSID/key/band, the network list with SSIDs, security,
    VIDs and bands;
  - the list of associated leaves from `iw dev <ap_vlan> station dump` (signal, rate, rx/tx).
- **Leaf:** "import" of that blob. It writes the station block (`repeater=multiap trunk=1`) and
  the networks (same SSIDs and security, `vlan=` / `bhvid=`, no subnets). It disables the WAN and
  gateway services and shows the uplink's link state.
- The existing station page's repeater select (`internal/api/wifista_actions.go:42-89`) stays for
  the single-network repeater and the third-party case.
- Effort is mostly the import/export model and its validation. The UI already gates features on
  the generator's `-F` (`repeater_supported`).

---

## 4. EasyMesh controller/agent (prplMesh) or a static backhaul

| | static backhaul (this design) | EasyMesh (prplMesh controller + agent) |
|---|---|---|
| what it gives | an L2 extension with all VLANs, same SSIDs, 802.11r/k/v per box | the same, plus auto-onboarding (1905 AP-autoconfig, WSC M1-M8 over the backhaul), central SSID config, topology, steering, channel planning, and in theory interop with other vendors' EasyMesh agents |
| what our stack must add | the OS work in §3, driver G1-G7 | §3's L2 trunk anyway (EasyMesh R2 traffic separation is 802.1Q on the backhaul), **plus** an IEEE 1905.1 stack (ethertype 0x893a on the bridge) and a large C++ daemon set to package for Buildroot, **plus** driver features EasyMesh agents rely on that we lack or have bench-gated: unassociated-STA metrics / probe reporting (PARITY R4; ⛔ event 200 `PROBREQ_MSG_RX_EXT` traps both radios, q227), BTM steering (bench-gated), client association control, channel scan reports, beacon metrics (STA-WDS §4 table) |
| interop gained | none that matters here. Stock ASUS BE firmware does not ship EasyMesh (§2.4: `RTCONFIG_WBD` off, no `ieee1905` binary), so the RT-BE92U could not join an EasyMesh controller. A second GT-BE98 runs our OS on both ends | |
| test cost | arms M0-M6 | the same, plus a 1905 conformance surface with no second agent in the lab |
| effort | ~7-9 days to a usable root+leaf (§6) | ~4-6 weeks on top, with open driver risk |

**Recommendation: static backhaul.** It is the subset of EasyMesh that carries data, built on the
same pieces EasyMesh R2 would use (Multi-AP backhaul BSS, 802.1Q traffic separation). Nothing in it
has to be thrown away if a controller comes later. The decision is reversible: prplMesh can sit on
top of phase B unchanged.

---

## 5. Box test plan with one box + PVE clients

### 5.1 What the lab can and cannot be

- **MT7925 (PVE, mt7925u): neither end of a 4-address link.** The mt76 driver clears
  `WIPHY_FLAG_4ADDR_AP | WIPHY_FLAG_4ADDR_STATION` (Linux `mt792x_core.c:695-696`), so
  `iw … set 4addr on` returns -95 (open-wifi `docs/REPEATER-2026-11-03.md` §1a on
  `om-repeater-2026-11-03`; W2's ten failures). [MEAS] arm P0 on the hypervisor's own kernel:
  MT -95, RTL rc 0 with `4addr: on`. The suggestion of "the PVE MT7925 as a 4-address
  station" is not possible without patching mt76 on the hypervisor, which the owner declined (D23).
  It remains the fronthaul client on every band, the leaf's "laptop".
- **RTL8188 (PVE, rtl8xxxu): a 4-address *station*, 2.4 GHz only.** mac80211 sets the flags and
  rtl8xxxu keeps them. With wpa_supplicant `multi_ap_backhaul_sta=1` it is **an independent,
  non-Broadcom leaf** for the root half, and it already passed A1/A1B/A1F. A PVE-side bridge with
  `rtl.<vid>` sub-interfaces and one netns per VID ("leaf clients") turns it into a VLAN-trunk leaf.
- **The box itself:** one radio as the root's backhaul AP, another radio as the leaf station. RL2B
  passed this way. ⚠ One IP stack spans both ends. Every "leaf client" must sit in its own netns
  behind a veth in the leaf bridge, and the root's targets must be reachable only via the link
  (RL2B's `arp_ignore=8`/`rp_filter=1` lesson). Channel: 5gl AP + 5gh station on a common 5 GHz
  channel (L0; the firmware keeps both radios on 36-140). The 2.4 GHz and 6 GHz bands have one radio each,
  so the box loop cannot test a 6 GHz backhaul; the loop's backhaul band is 5 GHz.

### 5.2 Arms (to pre-register when phase B code exists; endpoints fixed now)

| arm | setup | PASS | REFUTED | VOID |
|---|---|---|---|---|
| **M0** regression | RL2B as on 11-05, current integration image | ping ≥ 18/20, `wds.rx_link`/`tx_link` > 0, FDB RTL on the AP_VLAN | ping 0 with the link armed | RTL or loop setup fails its control (3-address join) |
| **M1** tagged frames | RTL leaf (`multi_ap_backhaul_sta=1`, 2.4 GHz root backhaul BSS), `rtl.10`/`rtl.20` → two netns; root `bh0.10`/`bh0.20` in two bridges with a gateway address each | both netns ping their own gateway 20/20 **and** a capture on the root's AP_VLAN shows `vlan 10`/`vlan 20` tags with the netns MACs | tags missing or stripped (frames arrive untagged or with PCP-only tag) ⇒ `vlan_mode` handling, G2 | RTL fails its untagged control ping |
| **M2** secondary backhaul BSS | M1 with the backhaul BSS as bsscfg ≥ 1 (hidden), the fronthaul as bsscfg 0 | as M1, `WDS-LINK[bsscfg ≥1]` | link armed, no RX on the AP_VLAN | M1 not PASS |
| **M3** SAE backhaul | box loop on 5 GHz, SAE-only backhaul BSS | COMPLETED, ping as M0 | SAE association fails with WPA2 control passing | WPA2 control fails |
| **M4** throughput | box loop, iperf3 netns↔root bridge address, 30 s each way, TCP and UDP | recorded (no bar: first reading), `tx_mq_mismatch`/AP_VLAN TX drops read | — | link drops mid-run |
| **M5** G1 fix | M4 on the back-pressure build | AP_VLAN TX drops ≈ 0 at saturation, TCP ≥ M4 | drops unchanged | M4 not read |
| **M6** full leaf | box loop with the phase B OS: root networks 10/20 + management, leaf networks re-served on the front radio, MT7925 joins the leaf SSID of VLAN 20 | MT gets a VLAN-20 DHCP lease from the root, pings its gateway, cannot reach VLAN 10 | lease from the wrong VLAN, or cross-VLAN reach | backhaul not COMPLETED |
| **M7** RT-BE92U as Media Bridge (when bought) | BE92U Media Bridge into a box fronthaul BSS (WPA2/SAE), a wired PC behind it | one association from the BE92U, the PC gets the network's lease and pings its gateway (WET MAC-NAT, §1.4) | the BE92U does not associate, or associates and passes no data from the PC | BE92U's own management address unreachable (its join failed for a non-mesh reason) |
| **M8** our leaf vs a Broadcom DWDS AP (when bought) | BE92U in AP/router mode (stock sets `dwds=1` on its BSSes); box station `repeater=4addr`; RTL behind the box's front AP | RTL pings the BE92U's LAN 20/20, and the BE92U shows a `wds*` peer for the box. This is the first third-party AP for our station half (REPEATER-2026-11-03 §2 had none) | box associates 3-address only (no `wds*` peer) with the RTL's ping 0 | box station fails its 3-address control join |

Each arm needs a bounded wait for COMPLETED / carrier, gates only the cells that depend on it,
restores the RTL to `type managed` (MTRESTORE-OK) and removes its PVE bridges and netns. M1 and M2
need a PVE bridge + netns on the host: the same class of state the A1F arm used. They still need
the orchestrator's approval as a PVE change.

### 5.3 Host tests (build host, no box)

- mac80211_hwsim (precedent `package/gt-be98-os/test/hostapd-mld-hwsim-test.sh`): two hwsim radios,
  hostapd `multi_ap=1 wds_sta=1`, wpa_supplicant `multi_ap_backhaul_sta=1` with 4addr, the phase-B
  `gt-be98-l2`/netguard/hook in two netns. This checks the OS plumbing (trunk add/remove on
  `WDS-STA-INTERFACE-ADDED/REMOVED`, VLAN isolation, loop guard) end to end. It cannot check our
  driver: hwsim is own-MLME.
- Generator/netguard/l2 offline tests in the existing style (gen checks, netguard `check` cases), and
  Go tests for the export/import model.

---

## 6. Phases and effort

| phase | content | effort |
|---|---|---|
| **A** (this doc) | design, feasibility, decisions | done |
| **B0** | M0 regression on the integration image (no code) | 1 box slot |
| **B1** driver | G1 AP_VLAN back-pressure (OO: the link ring set owns its queue state), G6 disarm layout, witnesses at notice level; host/QEMU gates; arms M1-M5 | 2-3 days + 2 box slots |
| **B2** OS | generator `backhaul=` / `trunk=1`, `gt-be98-l2` Wi-Fi trunk + short VLAN names, hostapd WDS event hook, netguard rules, leaf "AP mode" services; offline tests + hwsim test | 3-4 days |
| **B3** web UI | Mesh page, root/leaf roles, export/import, leaf list | 2 days |
| **B4** | M6 full-leaf arm on one image (driver + OS + UI), 30-min soak per the owner's rule | 1 box slot |
| **C** (optional) | ASUS DWDS interop on the root (firmware-native DWDS links + driver-made per-link netdevs, if D-MESH8 says yes; ~3-4 days + arms), WPS onboarding of a leaf (`multi_ap_backhaul_*` on a fronthaul), cross-box 802.11k neighbour sync, a second hop, a leaf with a wired uplink as an alternative trunk | 2-3 days |
| **D** (optional, not recommended now) | prplMesh / EasyMesh | 4-6 weeks |

**Total to a usable root + leaf: about 7-9 working days plus 4 box slots**, before a second
GT-BE98 exists. With a second box, M6 becomes the real two-box test and the loop arms stay as regression.

---

## 7. Decisions for the owner

| # | Question | Recommendation |
|---|---|---|
| D-MESH1 | Static backhaul now, EasyMesh (prplMesh) later or never? | Static (§4). |
| D-MESH2 | Backhaul band | 5 GHz on a non-DFS channel (36-48: no CAC in the EU domains the box runs) as the default, because the box loop can test it today. 6 GHz (no DFS, 320 MHz, SAE) as the target once M3 passes and a second box exists: the loop cannot test 6 GHz (one 6 GHz radio). |
| D-MESH3 | Dedicated hidden backhaul BSS, or backhaul on a fronthaul BSS (`multi_ap=3`)? | Dedicated, hidden, `multi_ap=1` (firmware blocks non-Multi-AP STAs on it; one BSS slot). |
| D-MESH4 | Gateway (routed) networks over the backhaul: allocate a backhaul VID per gateway network? | Yes, explicit `bhvid=` (default its VLAN ID if set, else allocated from a reserved range shown in the UI). |
| D-MESH5 | Leaf onboarding | Export/import blob in phase B. WPS in phase C. |
| D-MESH6 | Accept that plain 4-address (non-Multi-AP) peers cannot use our root? | Yes. The firmware drops them before the host. A Multi-AP backhaul STA is the supported peer (any recent wpa_supplicant). |
| D-MESH7 | PVE bridge + netns for arms M1/M2 (RTL as a VLAN-trunk leaf) | Allow: same class as A1F's veth, restored by the arm. |
| D-MESH8 | RT-BE92U role, and ASUS (DWDS/AiMesh) interop | A Media Bridge for one network (M7). In AP mode, the first third-party 4-address AP for our station half (M8). Interop with ASUS DWDS on our root (firmware-native links, driver-made `wds*` netdevs) goes in phase C only if the owner wants a stock ASUS node in the mesh. AiMesh itself (ASUS vendor IEs, `cfg_server` protocol) is out of scope. |

---

## 8. Driver part, built (lane mesh-bh, 2026-11-17) — for the mesh OS lane

Driver branch: open-wifi `om-mesh-bh-2026-11-17` (base `om-int-2026-11-17`). Details, citations and the root causes are in
open-wifi `docs/MESH-BACKHAUL-DRIVER.md`. Nothing below has run on silicon yet: arms M0 and M1 are pre-registered.
Decisions D-MESH1..7 were adopted as recommended. **No module parameter was added**: everything follows hostapd and
wpa_supplicant config.

### 8.1 What changed against §2.5

| gap | result |
|---|---|
| G1 back-pressure | On shipped defaults (`tx_sbf=1`) the AP_VLAN already behaves like the main netdev: its frames wait in the link ring set's host queue (SBF + CoDel, stock's per-flow model). The drop at `bca_netdev.c:2132` is reachable only at `tx_sbf=0`. There, it is now a real stop/wake of the AP_VLAN's own queue. ⇒ M4/M5 at shipped defaults read AQM drops, not a driver defect |
| G2 tags | The firmware passes host 802.1Q tags untouched both ways by default (ROM read: `vlan_mode` 0 and never strips; `map_8021q_settings` 0). **The OS must keep `multi_ap_vlanid=0`**: with a non-zero value the firmware tags the backhaul's EAPOL. New: a tag's PCP now picks the Wi-Fi TID, so an `egress-qos-map` on `bh<k>.<vid>` is honoured. Before, every tagged frame rode best effort |
| G3 secondary BSS | Two defects, both fixed. (1) A link's WLC_E_IF re-pointed a secondary BSS's own firmware interface. (2) The AP_VLAN took bsscfg 0 as its parent, which put the link's group frames on the fronthaul's ring. The AP_VLAN's parent is now the BSS whose address it carries |
| G6 -2 on leave | The firmware frees the link itself when the leaf's SCB goes (WLC_E_IF del comes first). The -2 meant "no SCB", and nothing leaked. The driver now sends no disarm for a link the firmware already freed |
| G4 SAE | Nothing on the 4-address path depends on the AKM (read end to end). The firmware side is M3 |

### 8.2 Interface names and behaviour the OS can rely on

- **Root backhaul BSS:** any AP netdev of the radio, primary or `bss=` secondary. hostapd needs `multi_ap=1`, `wds_sta=1`
  and `multi_ap_vlanid=0`. Leave `bridge=`/`wds_bridge=` unset if the hook enslaves the link itself (§3.2).
- **Root link netdev:** hostapd's AP_VLAN `<bss-ifname>.sta<aid>`, e.g. `bcawl0.sta1`.
  - Lifetime: from the leaf's association to its leave. hostapd announces it with `WDS-STA-INTERFACE-ADDED` and
    `WDS-STA-INTERFACE-REMOVED`.
  - TX: one queue. Unicast TX goes to the leaf whatever the destination address.
  - RX: the leaf's frames and everything behind it. EAPOL stays on the BSS netdev, where hostapd reads it.
  - Carrier is on while the interface exists.
  - Its name plus `.<vid>` can pass IFNAMSIZ, so use short names: `ip link add link <ap_vlan> name bh<k>.<vid> type vlan id <vid>` (G8).
- **Group frames:** they go out on the backhaul BSS's broadcast ring, so they reach every station of that BSS.
  ⚠ **With two leaves on one backhaul BSS, leaf A gets its own broadcasts back** (open-wifi ledger MESH-N1, open).
  **Decided 11-17: one leaf per backhaul BSS; the OS lane must ENFORCE it** (the minimal feature, §1.3, has one):
  - the generator accepts exactly one `leaf=<MAC>` per backhaul block;
  - the backhaul BSS gets `max_num_sta=1` and a MAC accept list holding only that leaf (`macaddr_acl=1` +
    `accept_mac_file`), so a second Multi-AP station is refused at association, not just by convention;
  - netguard refuses an AP_VLAN whose peer is not the configured leaf (§3.2 already proposes it).
  The rule lifts only when the driver sends a link's group frames 4-address unicast on its own ring (MESH-N1).
- **Leaf station:** `iw dev <sta> set 4addr on` before the join, then `wpa_supplicant -b <mgmt bridge>` with
  `multi_ap_backhaul_sta=1`. `bhs.<vid>` sub-interfaces on the station netdev are the network bridges' uplinks.
  ⚠ **If the leaf also serves APs on the backhaul radio (AP+STA), bring the station up before the APs.** `map_profile`
  and `dwds` need the radio's core-down window, which an already-beaconing AP closes. The driver logs `NOT applied` in
  that case.
- **Limits:** 8 links per radio; the ninth leaf is refused and logged. Runner offload stays off the link's RX (CPU path).
- **State for the UI:**
  - `iw dev <ap_vlan> station dump` now lists the backhaul BSS's stations.
  - `/sys/kernel/debug/bca/domN/wds` has the counters and one line per link (`wds.link bsscfg B <mac> ifidx I vlan
    <ap_vlan> rx R tx T fw_freed F txq_stop M`).

### 8.3 Arms (orch, pre-registered: `logs/prereg/PREREG-mesh-bh-2026-11-17.txt`)

- **M0:** the 11-05 loop on the current image's driver and on the new ko, plus a station-ended leave. Predicted: PASS
  on both; LEAVE=OLD (the -2) on the image, FIXED on the new ko.
- **M1:** tagged VLANs 10/20 over a 4-address link with the RTL as the leaf, two netns with their own MACs.
  Predicted: PASS, and VLAN 20's PCP-5 replies ride a TID-5 link ring.
- M2, M3 and M5 remain as §5.2 specifies (not written by this lane).
