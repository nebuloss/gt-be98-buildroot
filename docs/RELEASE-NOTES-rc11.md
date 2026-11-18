# GT-BE98 mainline OS 1.0-rc11 - release notes (DRAFT)

Date: 2026-11-17 · Status: **draft for release candidate 11**, not tagged.

Evidence is named by the orchestrator's queue (`qNNN`). The run directories
stay on the orchestrator's machine and are not in this repository. Every
number comes with the run that measured it, and "not measured" never means
0. Integration images: `imgint1` … `imgint7` are lab-mode builds of the
integration branches. Each arm ran on the image named next to it. RC11 is
built as `imgint8`.

RC11 is the first candidate since RC10 that adds whole features, not only
fixes:

- **Tagged VLANs on the 2.5G jacks**, and UniFi-style networks
  (name + VLAN + subnet) in the web UI.
- **Gateway networks.** The box is the router of a network: DHCP and DNS,
  NAT, isolation, a management switch per network, and IPv6 with a
  delegated prefix.
- **PPPoE WAN** through the web UI, with its status.
- **New Runner hardware offloads:** routed flows through a jack VLAN (G6b),
  PPPoE downlink, and routed entries that follow their client across the
  bridge (L3-FDB).
- **RTL8372 loop detection (RLDP)** and a real per-jack "off" (the PHY is
  powered down).
- **Wi-Fi:**
  - one owner for the move after a 5 GHz radar (DFS-OWNER);
  - 802.11k option (b);
  - fixed channels keep their primary;
  - radio recovery by rebind is on by default.
- **The Wi-Fi mesh backhaul:** root and leaf, VLAN trunk over the backhaul,
  SAE, one leaf per backhaul.
- **The web UI catches up with the OS**, and gains a mesh page.

## Images

Lab-mode candidate `imgint9` (the `RELEASE=1` release images are built from the same
sources at tagging). `imgint9` = `imgint8` with only the web UI replaced (the perf fix below):

| File | sha256 |
|---|---|
| `rootfs.squashfs` | `ad727bdb6c19cc90ab1ee16d06ccff8e35f87c360b4db466a6520e6846942416` |
| `ml-bootfs.itb` | `820ed180037e78b8bc04f5c0ca854c9088d4f2110eeea2a429a3203dd120a958` |

Build id (DT): `20261118T003027Z-4a6b4ec0da0f-rw-jffs`

**Candidate source state:** imgint7 is the image every q302 arm ran on.
imgint8 = imgint7 + the PPPoE uplink length-bound fix (q303) + the IPv6 state past DAD.

- **imgint7 build id:** `20261117T212409Z-138353a2b783-rw-jffs`
- **imgint7 rootfs:**
  `3d978e0f7914ccc3cc20902433ff3744f6f0b2c99ef0d30915f3068fc7a0eb88`

**Built from** (candidate; tags `gt-be98-rc11` when released):

| Component | Commit |
|---|---|
| gt-be98-buildroot | `br-int8-2026-11-17` `17e7a23` (= `br-int7` `ef45815` + `br-gw6-v6state` `6ed78d1` + the open-ethernet pin) |
| open-wifi (`bca_pcie_ipc.ko`) | `om-mesh-int-2026-11-17` `4040667a` |
| open-ethernet (Runner, kernel series, `rtl8372.ko`) | `oe-int2-2026-11-17` `8a18fa5` (= `oe-int` `199918f` + the PPPoE uplink bound `12183e8`) |
| web UI (gt-be98-webui-go) | `wu-mesh-int-2026-11-17` `7c58a5f` |
| hostapd | 2.12 with the local patches `0001`, `0002`, `0003` (new: the `no_pri_sec_switch` config item) |
| Linux / Buildroot | 7.2.9 / 2026.08 (kernel configuration unchanged since RC7) |

**Shipped Wi-Fi driver parameters:** 36 module parameters.
- `radio_rebind` now defaults to 1.
- The mesh lane's `band5_full` knob is bench-only. It is absent from the
  shipped module (`tools/ko-param-defaults.py`, identical lists apart from
  `radio_rebind`).

## Changes since RC10

### Tagged VLANs on the jacks + UniFi-style networks (driver `rtl8372`, OS, web UI)

**Jack profiles**
- A jack carries tagged VIDs besides its native one:
  `LAN_JACK_<n>="native=<vid> tagged=all|<vid>,..."`.
- In the switch, the jack is then a tagged member of those VLANs, and its
  ingress filter stays on.
- Frames tagged with a VID the jack does not carry are dropped.

**Networks in the web UI**
- A network is a name, a VLAN and a subnet.
- A port takes a network as native and others as tagged.
- An SSID takes a network.
- Changes run under a 120 s confirm-or-revert.
- A restart reverts a change left pending.
- A cleanup tool returns the store to a known baseline.

**Box evidence (q284):**
- Tagged VLAN arm r5: ALL PASS (start state, frames tagged/untagged,
  isolation, BPDU guard on tagged and untagged VIDs).
- Networks UI arm r5: ALL PASS (restart-revert included).
- Regression on later images: q293, q294 (tagged arm r8 FULL PASS right
  after the RLDP arm: no latch left behind).

### Gateway networks (OS `gt-be98-gw`, `gt-be98-l2`, `gt-be98-netguard`, `gt-be98-fwd`, web UI)

**Routing and firewall**
- A network with `mode=gateway` gets the box as its gateway: the address
  on its bridge, one dnsmasq, policy routing, NAT out of the WAN.
- Allow-by-default, with `isolate` (no traffic to other gateway networks)
  and `mgmt` (SSH and web UI reachable).
- Every narrowing change deletes the affected conntrack entries.

**Two-gateway rule:** a gateway network's VLAN is never carried on the WAN
trunk. A mesh leaf's backhaul bridge is exempt (it is not the wired trunk).

**DHCP and DNS (phase 3)**
- Per-network range, lease time, DHCP on/off, DNS servers and domain.
- Static leases, applied by SIGHUP: the lease table survives.
- A read-only lease list in the web UI.

**IPv6 (phase 5)**
- Each network gets a /64 of the WAN's DHCPv6-PD prefix, chosen by prefix
  ID.
- Router advertisements in SLAAC or DHCPv6 mode.
- RDNSS: dnsmasq dropped a bare `[::]` DNS server on a ULA /64. It now
  writes `[::],[fd00::]`.
- A network's IPv6 is reported `active` only once its address is past DAD
  (`starting` before, `refused` on a DAD failure), so the web UI binds only
  usable addresses (`br-gw6-v6state` `6ed78d1`).

**Router MAC:** every gateway bridge takes the jacks' port MAC, so gateway
networks cost no Runner router-MAC filter.

**Management**
- The admin UI listens on every running gateway network with `mgmt=1`: its
  IPv4 gateway address, and `<prefix>::1` while IPv6 is active.
- A bind that failed (IPv6 DAD) is retried every 5 s.

**Box evidence**

| Queue | Image | Result |
|---|---|---|
| q294 | imgint4 | GW1/GW1R/GW1C/GW1S/GW3/GW3b PASS (DHCP lease, router/DNS, NAT, lifeline default kept out, WAN clash → local, stop/start, static lease by SIGHUP, range/lease change keeps the lease) |
| q300 | imgint6 | GW2 PASS (Wi-Fi gateway network, isolate cuts a running flow, management reachable before isolate; the listener fix) |
| q302 | imgint7 | GW1 + GW2 PASS again (regression after the mesh changes) |
| q301 | imgint6 | IPv6: S, GW5M (management over IPv6), GW5D (DHCPv6), GW5S (stop/start), GW5L (WAN revert) and the wire check (nothing sent to other hosts) all PASS |

GW5 (SLAAC peer) passes its address/default/RDNSS checks. Its `in_drop`
reading is open (see Known open).

### PPPoE WAN (OS `gt-be98-wan`, `gt-be98-gw`, web UI)

**Configuration and status**
- Configured from the web UI: user, write-only password, VLAN, MTU 1492.
- Status shown: session state, the failure in words, reconnects.

**Fixes**
- **MSS clamp:** the TCP MSS is now clamped both ways, with a fixed cap.
  The inbound clamp used to take the management default's MTU.
- **NAT on gateway networks:** the PPPoE point-to-point address was read
  without a prefix. On a PPPoE WAN every gateway network became `local`,
  with no NAT. Fixed in gt-be98-gw, and in gt-be98-lan's NAT clash check.

**Box evidence:**
- q293 (imgint3): session, wrong password, reconnect.
- q298 (imgint5b): FULL PASS, including G1 (NAT and MSS over PPPoE, both
  directions).

### Runner hardware offloads (open-ethernet `driver/runner`)

**G6b (routed flows through a jack VLAN):** a routed flow whose bridge port
is an 802.1Q device of a Runner port is offloaded, with the tag popped on
ingress and pushed on egress (jack ↔ untagged WAN).
- Box: q301 T/WIRE PASS.
- Not offloaded: jack VLAN ↔ WAN VLAN, which needs a two-tag rewrite (D42).
  GW4 ON was REFUTED as predicted.

**PPPoE (RUNNER-PPPOE)**
- Routed IPv4 over the PPPoE WAN, with stock's per-packet length op.
- **Downlink offloaded** (q301): 0.30 → 0.09 cores/Gbit, CPU fraction
  0.002.
- **Uplink offloaded too** (q303): the length bound was 3 bytes short on
  imgint6 (uplink not offloaded). With `oe-pppoe-push-bound-2026-11-17`
  `12183e8` the uplink runs at 0.09 cores/Gbit against 1.13 on the CPU path,
  and the largest offloaded IP packet is exactly 1492 B.

**L3-FDB:** a routed entry behind a bridge is re-checked against the bridge
FDB and the neighbour table, so it follows its client when the client
moves port.
- Box arm `l3fdb-move` (q300): VOID, nothing offloaded, because the lab's
  path needs the D42 rewrite.
- Host tests only: `fc_bind_test`, 30 590 checks plus mutants.

**Other driver work (host-tested; box evidence where named)**
- **RUNNER-E2E-ONETAG:** bare port ↔ trunk VLAN, pop/push. The arm needs a
  cable move and has not run.
- **G2:** EXT_CFG1 MAX_PKT_SIZE 10272, as stock. The box read 1536 before
  the fix (q286).
- **E3 / G3:** rnr2 MIB counters and the core-7 TX tasks match stock.

### RTL8372 loop detection (RLDP) and jack power-down (driver `rtl8372`, OS)

**Loop detection**
- The switch's RLDP probes run on the four jacks.
- A probe that comes back latches the jack exactly like a BPDU (netguard,
  `jack_block`).
- `rc-service gt-be98-lan restart` clears it.

**Jack off:** `enabled=0` powers the jack's PHY down. A reload that leaves
no jack enabled unloads the driver (the switch goes back to reset, as at
boot).

**Fixes on the way**
- The live loop state comes from `LOOPED_STATE` 0x1090. `LOOP_STATE`
  0x108c is a latch on silicon (q290).
- The pair nibble is the port itself.
- One lock (`tripped.lock`) over the latch, so a restart always clears it.
  Before that fix, netguard rewrote the latch during the restart (q293 O);
  the jack stayed latched, and the next arms' DHCP was lost.

**Box evidence:**
- q290: B REFUTED-STICKY, the defect found.
- q293 (imgint3): all cells PASS except O.
- q294 (imgint4): O PASS. The tagged arm right after it passed, so no
  latch is left.

### Wi-Fi (open-wifi `bca_pcie_ipc.ko`, OS, hostapd)

**DFS-OWNER (ZW-N5):** after an in-service radar on a 5 GHz radio without
DFS offload, the firmware's own move is held and hostapd's CSA takes the
move over.
- q289 r4: CTL-A CONTROL-CONFIRMS (old code: two actors, 1.9 s off air).
- FIX-A PASS: the AP never stopped.
- FIX-N PASS: one actor, 64 s including the 60 s CAC.

**802.11k option (b)**
- `rrm` is set in Phase D. The Neighbor Report bit is not sent, because the
  firmware answers it first, from its own list.
- Beacon reports work, and BSS transition still lists neighbours.
- q287: C PASS, BR PASS. A5 VOID (option (a) closed).

**Fixed primary channel**
- A fixed-channel 5/6 GHz radio keeps its configured primary
  (`no_pri_sec_switch=1`, with hostapd patch `0003`).
- The 5gh channel list drops every weather block in every country.
- q296, q298, q300, q302: every fixed 5/6 GHz radio ENABLED on its
  configured primary.

**Radio recovery by rebind on (`radio_rebind=1`)**
- q296 rebind-ch40 r2: PASS on both cells, 6/6. The BSS comes back on air
  and the client re-associates in 7.8–9.9 s, with the primary unchanged.
- In-image default confirmed in q298.

### The mesh backhaul (OS `gt-be98-mesh`, `gt-be98-l2`, `gt-be98-netguard`, `gt-be98-wifi`, driver, web UI)

**Design**
- A Wi-Fi backhaul between a root and one leaf: 4-address Multi-AP, WPA2
  or SAE, a hidden backhaul BSS.
- The leaf's VLANs ride a trunk over the backhaul.
- The root accepts only the configured leaf (`leaf=<MAC>`).

**Driver fixes**
- The AP_VLAN parent is chosen again when hostapd sets the MAC (R2).
- A bound AP_VLAN's group frames go out on the link's own ring, as
  4-address frames (R6): ARP to a mac80211 leaf was dropped.
- AP_VLAN back-pressure.
- A leave that owes the firmware.

**OS fixes**
- A leaf's backhaul bridge gets its `<trunk>.<vid>`, because the
  two-gateway rule applies to the wired trunk only.
- gt-be98-gw never picks a backhaul bridge.

**Box evidence**

| Queue | Image | Result |
|---|---|---|
| q297 | imgvj2b, pushed kos | M1-IMG (old code) GRP=lost vs M1-NEW GRP=ok LEAVE=FIXED: R6/R4/R5 confirmed. M2-NEW PARENT=1: R2 confirmed. |
| q299 | imgint5b | SAE backhaul PASS; OS M3/M4 PASS (M4 TCP 432/625 Mbit/s up/down) |
| q300 | imgint6 | M1 M2 MR MR-ACL PASS (the root refuses a stranger) |
| q302 | imgint7 | **OS M6 PASS: the box as a full leaf (VLANs over the backhaul, a client behind the leaf). Driver M6L UNTAG / LOOP (tagged) / NS PASS, DROP-AT=none, 20/20.** |

### Web UI (gt-be98-webui-go)

The web UI follows the OS:
- **Status:** RLDP loop state, jacks off by reset.
- **Ports:** tagged VLAN lists.
- **Networks:** UniFi-style.
- **Gateway:** DHCP/DNS/static leases/lease list, IPv6.
- **WAN:** PPPoE status.
- **Mesh page:** role none/root/leaf behind a confirm-or-revert. A leaf
  import writes `mgmt_vid=`; the root writes `leaf=<MAC>`; a VLAN equal to
  a gateway backhaul VID is refused.

Box: q296 webui-catchup ALL PASS.

**Perf fix (RC11 re-check):** the admin-address watcher ran `rc-service gt-be98-gw features` and
`gt-be98-gw status` every 15 s even with no gateway network. That cost +23–27 % cores/Gbit on
5gl/6g in the RC11 perf smoke, with throughput unchanged. It now asks the OS only when the networks
file has a gateway network with management on (`wu-gw-watch-cpu-2026-11-18` `59df720`). The box
re-check on `imgint9` (perf smoke, UI degraded-apply) is to be filled in.

## Box evidence (integration images unless noted)

| Queue | Image | Result |
|---|---|---|
| q284 | imgvt2 | tagged VLANs + networks UI PASS |
| q286 | lab | W0 read: EXT_CFG1 MAX_PKT_SIZE 1536 (justifies G2) |
| q287 | lab | 802.11k option (b) |
| q289 | lab | DFS-OWNER r4 |
| q290 | imgint2 | session: RLDP sticky found; arm gate fixes (features line, jack link) |
| q291 | lab | zero-wait DFS 5gh (bg CAC): C0 CONFIRMS-BLOCKER, BR PASS, BG FAIL. **Not in RC11.** |
| q293 | imgint3 | tagged r7 FULL PASS; RLDP all but O; PPPoE U1/U2/U3 |
| q294 | imgint4 | gateway DHCP/NAT/static leases; RLDP O PASS; tagged after RLDP PASS |
| q295–q297 | imgvj2b | mesh driver root causes and fixes confirmed |
| q296 | imgmesh2 | rebind r2 PASS 6/6, fixed-primary PASS, webui-catchup PASS |
| q298 | imgint5b | PPPoE FULL PASS (NAT fix); IPv6 cells; mesh M1 M2 |
| q299 | imgint5b | mesh SAE + M3 M4 |
| q300 | imgint6 | GW1 + GW2 PASS; mesh M1 M2 MR MR-ACL M3 M4 |
| q301 | imgint6 | G6b T/WIRE PASS, GW4 REFUTED (D42); IPv6 S/GW5M/GW5D/GW5S/GW5L/WIRE PASS; PPPoE downlink offload |
| q302 | imgint7 | mesh M6 + driver M6L PASS; GW1 + GW2 regression PASS; fixed-primary PASS |
| q303 | imgint7 + bench ko | **PPPoE uplink offloaded:** O-up LON 0.09 cores/Gbit (CPU fraction 0.000) vs LOFF 1.13; the BD sweep gives the largest offloaded IP packet 1492 B exactly (max_pkt_len 1514), the fixed rule's prediction, refuting the old one. The remaining REFUTED cells (capture count, H1 719/1000, bd_fit) are capture artefacts of the arm |

**Regression set and 30-minute release soak** (on imgint8):
`logs/prereg/RC11-REGRESSION-QUEUE.sh` + `logs/prereg/rc11-soak.sh` in the
lab tools, run once. Results to be filled in.

## Known open

**Offload**
- **D42:** VLAN ↔ VLAN offload (a jack bridge-port VLAN ↔ a `rnr0.<VID>`
  WAN) needs the two-tag rewrite. That lives only in the parked
  rt-ipv6-offload lane, so such flows stay on the CPU. The L3-FDB box arm
  is VOID for the same reason (host-tested only).

**Wi-Fi**
- **D36–D40:** MLO on 5 GHz is pending.
- **Band steering** works in the daemon, but is limited by the client. The
  lab's MT7925 advertised no 5 GHz operating class, so it is never offered
  the 5 GHz BSS (q290/q293 S1 VOID-NOCAP5). The default stays off.
- **Zero-wait DFS on 5gh in ETSI** is not in RC11 (q291 BG FAIL; hostapd
  cold-start patch pending).

**Ports**
- The cabled 1G (rnr2, "1G LAN-5") and 10G (rnr3, "10G LAN-6") ports have
  not carried traffic on this OS. Their arms (W1/W2, onetag) need a cable
  move.
- 2.5 Gbit/s line rate and more than one cabled jack remain untested.

**IPv6 on gateway networks:** GW5's `in_drop` reading is open. The IPv6
lane decides whether it is a product fix for RC11.

**Carried over from RC10**
- WPS overlap detection is unproven.
- IO-coherent PCIe stays bench-only.
- Web UI `go test -race` has an isolation issue in older tests.
- hostapd patches `0002` and `0003` are not reported upstream.
