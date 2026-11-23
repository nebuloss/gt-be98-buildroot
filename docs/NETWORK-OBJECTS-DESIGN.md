# Networks, Wi-Fi, ports, addresses and services as independent objects (owner 11-23)

Base: buildroot `mainline-os` ec2f79c7 (= gt-be98-rc13), web UI `main` 8dacddf, open-wifi `main` 0a7588d3.
Branches: buildroot `br-netobj-2026-11-23`, web UI `wu-netobj-2026-11-23`. No driver change.
Every "today" claim cites the base. Proposals and hypotheses say so.

## 1. What breaks the model today, and why

| # | Restriction | Where | Real limit or simplification? |
|---|---|---|---|
| R1 | One SSID per VLAN in the OS generator | `gt-be98-wifi-gen` (base) awk: `else if (vlan[i] in vseen) nerrf(... "also used by network" ...)` | Simplification. An SSID's bridge was named after the SSID (`brwifi<ssid id>`, plan line `net <id> brwifi<id> ...`), and gt-be98-l2 allows one bridge per VLAN (`cmd_up`: "is bridged in X already"), so two SSIDs on one VLAN would have needed two bridges for one VLAN. |
| R2 | One SSID per network in the web UI | API `saveWifiNetwork`, `internal/api/wifiap_actions.go:1105-1110` ("the OS bridges one SSID per network"); page `www/js/wifiap.js` `wnNetOptions` (`taken` -> `disabled`), `wnSubmit` clash toast, `wnPickVLAN`; platform `CheckWifiNetworks`, `internal/platform/linux/wifinet.go:496-499`; mesh export `CheckMeshExport`, `mesh.go:571` | The UI mirrors R1. |
| R3 | A network gets a bridge only through an SSID or a port | the bridges are made by their users only: `gt-be98-wifi` `net_up` (an SSID), `gt-be98-lan` `vports_apply` (a jack); the network list itself has no owner. `gt-be98-gw` says it: "A network with no bridge yet (no SSID, no jack on it) is inactive" | Simplification. A network with neither SSID nor port had no bridge, so a gateway network could not hold its address there. |
| R4 | The bridge identity moves when an SSID arrives | `gt-be98-l2` `yield_bridge`: a lan-only `brwifi<100000+id>` hands its VLAN to the SSID's `brwifi<id>` (jacks evicted and re-attached, the gateway address moves) | Consequence of R1/R3. |
| R5 | Port isolation is per bridge | `WIFI_ISOLATE` lists bridges (`gt-be98-wifi` `isolate_ports`, netguard rule 3) | With one SSID per bridge it was per SSID; with several it must be per BSS port. |
| R6 | The UI writes the whole networks-file line | `RenderNetworksFile` (`l2netfile.go:96-154`) always renders mode/isolate/mgmt from its store | A key set by file/CLI (an OS-only gateway, a newer OS's key) is lost at the next save. |

Not limits: the driver. open-wifi 0a7588d3 says it itself (`bca_bss.h` INV-C2C, `bca_cfg80211_iface.c` ap_isolate scope): "two networks are two netdevs; whether a frame crosses between them is the OS bridge's". Two BSS netdevs in one Linux bridge is the shape every multi-band SSID already has (bcawl3 + bcawl0 + bcawl1 in one `brwifiN`). The per-radio limits are unchanged and still count every SSID: 8 BSSes per radio (mbss8, `WIFI_MAX_BSS`), the radio's peer table shared by its BSSes.

## 2. The target model

- **Network**: id, name, VLAN, address range (subnet label), OS-only gateway keys (mode, DHCP, NAT, IPv6; owner 11-23: configured by file / CLI, not in the AP UI). It owns ONE bridge, `brwifi<100000 + id>`, which exists while the network is listed, with zero or more SSIDs and zero or more ports.
- **Wi-Fi (SSID)**: id, name, security, bands, isolate, schedule; bound to ONE network. Several SSIDs may share a network.
- **Port**: one native (untagged) network, zero or more tagged networks (unchanged: `LAN_JACK_<n>`, `LAN_PORT_<port>`).
- **Address**: id, network, `static` (cidr, optional gateway) or `dhcp`. Several per network, at most one DHCP per network (one dhcpcd per interface). The admin UI and SSH are reachable on them only. None configured = the image's management (DHCP on the untagged trunk, the USB lifeline, no filter).
- **Service** (model only, section 7): type + one address id + on/off.

Files (all parsed, never sourced; keys in any order; unknown keys kept by the UI):

```
/etc/gt-be98-networks.conf    network=<id> name=<pct> vlan=<vid> subnet=<cidr|> [mode=... OS-only keys]
/etc/hostapd/networks.conf     network=<ssid id> ... vlan=<the network's VLAN>   (several SSIDs may name one VLAN)
/etc/conf.d/gt-be98-lan        LAN_JACK_<n>="native=<vid> tagged=..."            (unchanged)
/etc/gt-be98-addresses.conf    address=<id> network=<id> mode=static cidr=<A.B.C.D/P> [gateway=<ip>] | mode=dhcp
```

## 3. Implemented (OS)

| Owner | Change |
|---|---|
| `sbin/gt-be98-net` + `init.d/gt-be98-net` (new, default runlevel, after the Wi-Fi, before the LAN and the gateway) | The network object: per network of the list `gt-be98-l2 up net brwifi<100000+id> <trunk> <vid>` (user `net`), let go when the network leaves the list. Per-object state `/run/gt-be98-net/net/<id>` (up/refused, starts, refusals, why). Refused: VLAN 1, a VLAN or id listed twice, every network on a mesh leaf, a gt-be98-l2 refusal. A VLAN move runs the LAN reload (`-n`: the caller does). `bridge <vid>`, `status`, `features netbridges`. |
| `gt-be98-wifi-gen` | `-L <networks file>`: an SSID with `vlan=V` joins the bridge of the network on V; several SSIDs per VLAN allowed (`feature shared_vlan 1`); without a network object, the first SSID's `brwifi<id>` (hand-written lists). The bhtrunk VID list de-duplicated. |
| `init.d/gt-be98-wifi` | passes `-L`; a shared bridge listed once in `WIFI_BRIDGES`/`WIFI_VLANS` (one `gt-be98-l2 up` per bridge); isolation per SSID: a bridge whose SSIDs are all isolated stays in `WIFI_ISOLATE` (the 1:1 case byte-identical), a mixed one lists the isolated SSIDs' BSS netdevs in `WIFI_ISOLATE_BSS` (l2.conf). A Linux bridge isolates port from port: an isolated SSID reaches the network's non-isolated members (trunk, jacks, gateway, a non-isolated SSID), never another isolated port. |
| `gt-be98-netguard` | rule 3 also keeps `WIFI_ISOLATE_BSS`. |
| `init.d/gt-be98-lan` | `lan_net_list`: the network objects first (their own bridge), then the Wi-Fi's for a VLAN no object carries; `features tagged networks netbridges`. |
| `gt-be98-gw` | `apply` runs `gt-be98-net apply -n` first (every list change reaches it: the web UI reloads gt-be98-gw after each); `reroute` does not. |
| `gt-be98-l2` | header: the user `net`; the yield path only for hand-written lists. |
| `sbin/gt-be98-addr` + `init.d/gt-be98-addr` (new) | The box's addresses: static (`ip addr replace` on the bridge, its gateway at metric 2600) or DHCP (its own dhcpcd on the bridge, private mount namespace, the gt-be98-wifi-sta pattern); Default (VLAN 1) = the image's DHCP client on rnr0. Filter `table inet gt_be98_addr`: TCP 22/80/443 accepted from lo, `usb*`, `enx*`, `bhm0`, the listed networks' devices and gt-be98-gw's mgmt bridges; dropped elsewhere; only while the list holds an address. `addrs` feeds the web UI listener. |

Tests (offline, run on dev-code; hostapd/wpa confchecks on dev-build): `gt-be98-net-test.sh` (31), `gt-be98-addr-test.sh` (37), `gt-be98-wifi-gen-test.sh` (+20 per awk: 2 SSIDs on one VLAN, -L, controls, -S, isolation), `gt-be98-wifi-service-test.sh` (+5), `gt-be98-netguard-test.sh` (+2), `gt-be98-lan-test.sh`, `gt-be98-gw-test.sh` (+2), `gt-be98-net-mutants.sh` (each rule broken on a copy must turn its suite red).

## 4. Implemented (web UI)

- several SSIDs per network when the generator says `shared_vlan` (API, platform check, page picker and submit: no visual change, the "carries" label kept);
- the SSID's `bridge` is the plan's (bss field 8), else its network's own on a `netbridges` OS; `isNetBridge` takes `brwifi<6 digits>` (else every Wi-Fi save after the first apply would refuse "bcawl3 is a port of bridge brwifi100003");
- `LANBridgeOf`: the network object first on a `netbridges` OS (as the OS);
- the networks file keeps what the UI does not own: unknown keys always; a `mode=gateway` line's keys (and subnet) when `gatewayInUI=false` (the AP-only UI; default true until the redesign lands, then one line);
- mesh export: a second SSID of a network is listed as skipped (the leaf format carries one per network);
- `addr_list`, `addr_set{id?, network, mode, cidr?, gateway?}`, `addr_delete{id}` under the 120 s trial (the snapshot holds the `ADDR_*` keys; a revert reloads gt-be98-addr); a network carrying an address is in use; the listener binds the OS's addresses in force.

## 5. Migration: none needed, decided at runtime

Kept: every file format. The 1:1 layout maps to itself: one SSID on network N joins `brwifi<100000+N>` instead of `brwifi<ssid id>` at the first start of the new image (a bridge rename once, everything that matters resolves by VID: gt-be98-gw, gt-be98-lan, netguard, the web UI). Why not rewrite files at boot: the formats did not change, only refusals were lifted; the bridge name is derived, so there is nothing to convert, and an older web UI on the new OS keeps working (it still refuses a second SSID itself). A newer web UI on an older OS keeps the old rules (the handshakes `feature shared_vlan`, `features netbridges`, `features addresses`). Known cost: a `WAN_PD_LANS=brwifi<id>` naming an SSID's bridge (a VLAN-only bridge, IPv6 off: it never worked there) names a bridge that no longer exists.

## 6. The AP model: all ports equal (analysis)

Today rnr0 is special three times: the Wi-Fi trunk (`WIFI_TRUNK=rnr0`), the management (dhcpcd allows rnr0 only, `etc/dhcpcd.conf`; netguard invariant 1 never bridges a bare protected port), and the WAN (gt-be98-wan's default netdev).

- **Management**: becomes the Addresses object (implemented). The untagged trunk stays the fresh-box default; once an address is listed the management is exactly the list. Making Default a real bridge (all native-1 ports in one segment) means relaxing netguard invariant 1 (rnr0 never a bridge port: the owner's broadcast-storm incident); proposed only with a loop guard on every port (below) and the 120 s trial.
- **Loop guard**: RLDP runs in the RTL8372 on the 2.5G jacks only; the Runner ports have the BPDU guard (a BPDU cuts the port). With an uplink on any port, a BPDU is EXPECTED on the uplink (an upstream switch): the guard needs a per-port role (edge: cut on BPDU; uplink: never). A loop on a tagged VLAN is invisible to the bridges' STP (the BPDUs arrive untagged): the proposal is a software RLDP per network bridge (the mesh leaf's loop guard already does it on `bhs.<vid>`: a frame with the box's own source coming back in another port latches that port), generalised to every network bridge.
- **Offload** (open-ethernet main c56b79b `flowcache.c`): bridged shapes offloaded today: Wi-Fi <-> Runner port or its 802.1Q device (W1/W2), Ethernet 802.1Q <-> 802.1Q of two Runner ports with one VID (E2E), bare port <-> 802.1Q (B2). An uplink on a 2.5G jack (rnr1.V) is W1/W2: covered. Not covered: two bare Runner ports in one bridge (both untagged: `is_vlan_dev(in) || is_vlan_dev(out)` false -> CPU), same-port hairpins. Jacks of one VLAN switch inside the RTL8372 (wire speed, never the SoC).
- **Gateway / NAT / PPPoE / IPv6 PD**: stay in the OS, file / CLI only; the AP model needs none of them (no file = VLAN-only networks, no WAN config = DHCP on rnr0).

## 7. Services (model only, not implemented)

A service = type + one address id + enabled + options. Mapping onto today's daemons:

| Type | Daemon | Rule |
|---|---|---|
| DHCP server | dnsmasq (gt-be98-gw's one instance, `interface=<bridge>` ranges: the shape exists) | needs a STATIC address on its network and a range inside that address's subnet (excluding it); one DHCP server per network. No NAT is implied: the clients' router option is the address's `gateway=` (the upstream router) unless set. |
| Admin page | the web UI listener | binds the addresses of its enabled rows; at least one enabled admin row must remain (refuse the last, and every change under the trial) |
| SSH | sshd `ListenAddress` per row (sshd today listens on every address) | same guard as the admin page |
| RADIUS server | the built-in RADIUS (`internal/radsrv`) | binds its row's address |
| Captive portal | the web UI's portal engine | on its address's network |

OS file proposal: `service=<id> type=dhcp|admin|ssh|radius|portal address=<id> enabled=0|1 [opts...]` in `/etc/gt-be98-services.conf`; gt-be98-addr's filter opens 22/80/443 per enabled admin/ssh row instead of per address. API: `svc_list`, `svc_set{type, address, enabled, opts}`, `svc_delete`, under the trial. Until then every address carries admin + SSH (what is implemented).

## 8. VLAN detection per port (analysis + API proposal, not implemented)

Exists: web UI `wifi_detect_vlans` (`internal/platform/linux/vlanprobe.go`: AF_PACKET capture on the trunk netdev, 802.1Q/802.1ad VIDs counted, subnet from DHCP offers/acks exact, else ARP/IPv4 sources as a /24 guess; read-only) and `wifi_test_vlan` (a DHCPDISCOVER from a temporary `<trunk>.<vid>`); the stock platform's `detect_port_vlans` (`portmap.go:67`) is "not ported" on Linux (`linux_actions.go:39`).

Per port:
- **Runner ports (rnr0, rnr2, rnr3)**: the same capture on the bare netdev (tags in place on this driver). Works for any VID.
- **2.5G jacks (rnr1 via the RTL8372)**: a VID the jack is not a member of is dropped by the ingress filter, and a VID with no table entry is dropped at port 3 (`docs/rtl8372-vlan.md` §5). So only the VIDs already configured on the jack reach the SoC, as `rnr1.V` frames; attribution to the jack by `l2_lookup` (source MAC learned per VID, the BPDU guard's mechanism). Seeing unconfigured VIDs needs a driver "probe" mode: for one jack at a time, accept all + ingress filter off, port 3 a member of every VID (or egress transparent: register 0x4eb8, NAMED, its effect on a missing entry UNREAD) for the capture window. HYPOTHESIS, needs an arm before code.
- **Limits**: a silent VLAN is invisible; a subnet needs a DHCP exchange or ARP in the window; flows the Runner offloads never reach the host (broadcasts and ARP still do); the capture costs CPU for its seconds only.

Proposed API: `port_detect_vlans{port, seconds}` -> `{port, seconds, frames, untagged, vlans: [{vid, seen_frames, subnet?, source: dhcp|arp|ipv4, guess, router?, network?: <existing id>, configured: bool}]}`; one detection at a time (the existing `detectMu`); on a jack without the probe mode: only configured VIDs, `configured: true`, and the answer says so.

## 9. Owner decisions

| # | Question | Recommendation |
|---|---|---|
| N1 | Bridge name of a network | `brwifi<100000+id>` always (implemented): stable whatever its SSIDs and ports. |
| N2 | Isolation semantics on a shared network | per BSS port (implemented): an isolated SSID reaches the network's non-isolated members, never another isolated port. |
| N3 | `gatewayInUI` | flip to false with the AP-only redesign (the keys are then the OS file's). |
| N4 | Default as a real bridge (all ports equal) | after the per-port loop guard; until then the untagged trunk stays the fresh-box management. |
| N5 | Services file and per-row admin/SSH | section 7. |
| N6 | Jack VLAN probe mode | a bench arm on the RTL8372 first (section 8). |
