# Routed networks: how the box acts on a network's subnet (design, for owner review)

Status: DESIGN ONLY, nothing implemented. Base: buildroot `br-vlan-tagged-2026-11-16` 3e951c8,
web UI `wu-networks-2026-11-16` e3554ed, open-ethernet main 17e5dfc.
Owner goal (11-16): UniFi-style networks = name + VLAN ID + subnet.

Every claim about current behaviour below cites the code it was read from
(`file:line` at the base above). Where a claim is a design proposal or a hypothesis,
it says so. UniFi behaviour is quoted from its documented model, not measured here.

---

## 0. What exists today (read, not assumed)

| Piece | What it does | Where |
|---|---|---|
| Web UI network list | Stores `L2NET_<id>_SUBNET` in gateway form (`192.168.30.1/24`), `""` = VLAN only; DHCP keys reserved, never written; renders `/etc/gt-be98-networks.conf` as `network=<id> name=<pct> vlan=<vid> subnet=<cidr\|>`. The header says it plainly: *the OS does not act on it yet*. | webui `internal/api/l2networks.go:39-51`, `:255-266` |
| Web UI subnet check | Host address of its subnet, `/1`..`/30`, any unicast range (public included), no overlap with another network's subnet or the box's own IPv4 nets. | webui `l2netfile.go:132-156`, `l2networks.go:226-249` |
| `gt-be98-lan` | Reads `networks.conf` for `network=` and `vlan=` **only** (subnet ignored); a network without an SSID gets bridge `brwifi<100000+id>`. | `init.d/gt-be98-lan:291-302` |
| `gt-be98-l2` | The single owner of `brwifiN` bridges. `up` **always** creates and enslaves `<trunk>.<vid>`; IPv6 off on the bridge; one bridge per VLAN. | `sbin/gt-be98-l2:183-263`, `:196-210`, `:247` |
| `gt-be98-netguard` | Invariant owner: a `<port>.<vid>` is a bridge port only as a listed Wi-Fi trunk VLAN or the one `gt-be98-l2` runs the bridge on; `rnr1.<vid>` only as an l2-recorded wired member; bare `rnr2/rnr3` only in their native VLAN's bridge. | `sbin/gt-be98-netguard:175-200`, `:230-271` |
| Option A routed LAN (dormant) | `br-lan` + `LAN_ADDR`: masquerade out of the WAN, policy table 183 by `iif`, forward filter (into the bridge: replies, DNAT, multicast UDP; out: WAN only), WAN/station subnet-clash refusal, its own dnsmasq. Box-verified LAN2 q248. | `init.d/gt-be98-lan:105-118`, `:435-544`, `:925-931` |
| `gt-be98-router` (not in the default runlevel) | Router mode: `ROUTER_LANS` = `bcawl*` or `br-lan` only (**never `brwifiN`**), table 180, input filter on the WAN always (D22), its own dnsmasq, igmpproxy option. Refuses to start when `gt-be98-lan` owns an address on a bridge it does not list. | `init.d/gt-be98-router:1-45`, `:95-114`, `:224-231` |
| `gt-be98-wifi-sta` routed networks | `routed=` networks behind a Wi-Fi station: bridge address, ONE dnsmasq with per-interface tagged ranges, NAT + table 181 out of the station. | `sbin/gt-be98-wifi-sta:369-465` |
| `gt-be98-wan` | The WAN netdev is `gt-be98-wan ifname`: `rnr0` (default, DHCP by dhcpcd, nothing else touched), `rnr0.<vid>` (`WAN_VLAN`), `pppoe-wan`; `WAN_PORT` may be `rnr0..rnr3`. Input filter only when the WAN netdev is not the bare port. | `sbin/gt-be98-wan:10`, `:131-151`, `:213-216`, `:408` |
| Forwarding | `net.ipv4.ip_forward = 0` in the image; three owners each turn it on and, at stop, restore it only after checking the other two owners' state files by name. | `etc/sysctl.d/*`; `gt-be98-router:246-249`, `gt-be98-lan:965-967`, `gt-be98-wifi-sta:359-363` |
| Runner offload args | `flow_offload=1 wlan_rings=1 wlan_offload=1 fc_wlan=1 wlan_inject=1 fc_wlan_up=1` | `conf.d/gt-be98-drivers:6` |

**What "the WAN" is on this box.** It is whatever `gt-be98-wan ifname` prints. With no
`/etc/gt-be98-wan/wan.conf` (the shipped default) that is **untagged `rnr0`**, the 10G jack
(open-ethernet `docs/eth-lan-2026-11-02.md:54`: "uplink + management, on the owner's LAN"),
on DHCP. `WAN_VLAN` makes it `rnr0.<vid>`; PPPoE makes it `pppoe-wan`; `WAN_PORT=rnr3` (the
second 10G jack) or `rnr2` (1G) are accepted too. The same `rnr0` is also the Wi-Fi trunk by
default (`WIFI_TRUNK=rnr0`, `conf.d/gt-be98-wifi:44`): its **tagged** VLANs carry today's
VLAN-only networks upstream, its **untagged** frames are the WAN and the box's management.
The design uses `gt-be98-wan ifname` everywhere and never hard-codes `rnr0` (as Option A
already does, `gt-be98-lan:408-413`).

---

## 1. Gateway modes per network

Two modes, one per network:

| | VLAN only (today) | Gateway (new) |
|---|---|---|
| Who is the gateway | the upstream router, on the trunk VLAN | the box |
| Bridge | `brwifiN` with `<trunk>.<vid>` | `brwifiN` **without** `<trunk>.<vid>` |
| Box address on the bridge | none, IPv6 off | the subnet's gateway address (e.g. `.1/24`) |
| DHCP / DNS | upstream | the box (dnsmasq) |
| Off-subnet traffic | bridged upstream on the trunk | routed by the box, masqueraded out of the WAN |
| Members | BSSes, `rnr1.<vid>` (2.5G jacks), bare `rnr2/rnr3`, tagged jack VLANs | the same |

### The two-gateway rule (proposed, enforced in two places)

A network is either bridged upstream on the trunk **or** routed by the box, never both:
with `<trunk>.<vid>` still in a gateway bridge, the upstream router's DHCP server and the
box's would answer the same segment (two gateways, a rogue DHCP for one of them), and the
box's masquerade would loop traffic it could have bridged.

- **For a gateway network, `<trunk>.<vid>` does not exist.** The VLAN ID stays meaningful on
  the box's LAN side only: the RTL8372 still tags each jack's native VLAN on `rnr1`
  (`gt-be98-lan:12-19`), tagged jack trunks (`tagged=`) still carry it to downstream switches
  and APs, and the bridge name is still resolved by VID. Upstream, that VID simply is not
  carried by the box.
- **Owner of the rule: `gt-be98-l2`** (the one bridge owner). It reads `/etc/gt-be98-networks.conf`;
  for a VID whose network is in gateway mode, `up` creates/adopts the bridge and the wired
  members but **no trunk sub-interface**, and records `trunk -` in its state. Switching an
  existing bridge between the two modes removes or adds only the trunk sub-interface; the
  wired members stay (same VID). Today a trunk change evicts the wired members
  (`gt-be98-l2:218-236`): the mode switch must not take that path.
- **Defence in depth: `gt-be98-netguard`** gets an invariant 6: a `<trunk>.<vid>` whose VID
  belongs to a gateway network is never a bridge port, even if a stale `WIFI_VLANS` lists it
  (today `wifi_vlan_ok` accepts any listed one, `gt-be98-netguard:175-189`). `jack_vlan_ok`
  and `vport_ok` compare the l2 state's trunk with `WIFI_TRUNK` (`:197`, `:238`); they must
  accept `trunk -` for a gateway bridge.
- Removing `rnr0.<vid>` is a netdev event, so the Runner flow cache drops that device's
  hardware flows (the general rule written at `gt-be98-lan:70-72`).

### The gateway service (proposed: `gt-be98-gw`, one owned object per network)

Option A's mechanism, generalised from one bridge to N, as its own service in the default
runlevel that is a clean no-op while no network is in gateway mode (D41's pattern).
Per network, an object with `init / start / stop / destroy`, a state enum
(`inactive` no bridge yet, `local` address + DHCP but NAT refused, `routed`), and its own
counters. The service:

1. resolves the network's bridge **by VID from `gt-be98-l2 list`** (the SSID's `brwifi<wifi id>`
   or the wired-only `brwifi<100000+id>`); it never creates bridges. It is re-run after every
   `gt-be98-l2` change (the same follow hook `gt-be98-wifi` uses for the LAN,
   `init.d/gt-be98-wifi:194-196`), because a wired-only bridge yields its VLAN to an SSID's
   bridge (`gt-be98-l2:196-210`) and the address must move with it;
2. sets the gateway address on the bridge; refuses (logged, network stays `local`) when the
   bridge already carries an address of another owner;
3. policy routing (proposed, a change from Option A's pattern):
   `ip rule iif <br> lookup main suppress_prefixlength 0` then `ip rule iif <br> lookup 184`,
   table 184 holding only the WAN's default route (`unreachable default` without one).
   Option A instead throws all of RFC 1918 back to the main table (`gt-be98-lan:514-517`),
   whose default route may be the USB lifeline's; a client reaching a private address
   upstream then leaves by the lifeline and is dropped by the forward filter. With
   `suppress_prefixlength 0` the box's connected routes (other gateway networks, the WAN
   subnet) come from main, and everything else follows the WAN. *Hypothesis to verify in arm
   GW1-R.*
4. one `table inet gt_be98_gw` (forward + input, section 2) and one
   `table ip gt_be98_gw_nat` (`oifname <wan> ip saddr { <subnets> } masquerade`);
5. one dnsmasq for all gateway networks (section 3);
6. `reroute` from a dhcpcd hook (as `08-gt-be98-lan`) and the pppd ip-up/down path
   (`gt-be98-wan:785-790`): the WAN's lease changed, so table 184 and the clash check are
   rebuilt. A WAN address inside a gateway subnet sets that network to `local` (NAT refused,
   as `nat_clash`, `gt-be98-lan:435-444`).

**Forwarding ownership (proposed refactor, needed before a 4th owner).** Today each routed
owner restores `ip_forward` after checking the other owners' files by name. A fourth owner
means editing all three. Instead: one helper (`gt-be98-fwd hold <owner>` / `release <owner>`,
a directory of holder files under `/run`), `ip_forward=1` while any holder exists, restored
to the image's 0 when the last one leaves. The three existing owners move to it in the same
lane.

**Router mode.** `gt-be98-router` cannot serve `brwifiN` (`ROUTER_LANS` refuses it,
`gt-be98-router:102-111`) and has no producer on the RC images (D41 note). Proposed: gateway
networks and router mode exclude each other (each refuses to start while the other's applied
file exists, the "router guard" pattern of `gt-be98-router:95-101`), and router mode is
retired once gateway networks pass phase 2. **Owner decision D-GW5.**

**Option A (`br-lan`, `LAN_ADDR`).** It stays as is: it is the untagged VLAN 1 jacks'
routed LAN, and VLAN 1 is Default, the trunk's untagged management network, which the web
UI never lets carry a subnet (`l2networks.go:673-676`). A gateway subnet overlapping
`LAN_ADDR` is refused.

---

## 2. Inter-network policy and management access

**UniFi's documented defaults:** all Corporate networks reach each other and the internet;
a per-network "Isolate network" stops traffic to and from the other local networks but
keeps internet access; Guest-type networks additionally lose access to the gateway itself
except DHCP/DNS. Here the same, with two per-network flags:

- `isolate=0|1` (default 0): no forwarding to or from any other local network;
- `mgmt=0|1` (default 1, forced to 0 when `isolate=1` unless set explicitly): the box's
  management listeners (SSH 22, web UI 80/443) reachable on that network's gateway address.

DHCP (67), DNS (53 UDP/TCP) and ICMP are always accepted from a gateway network, isolated or
not (as for UniFi Guest networks). The SSID's own client isolation (`isolate=` in the Wi-Fi
list: `ap_isolate=1`, isolated bridge ports, `gt-be98-wifi-gen:1586`, `gt-be98-wifi:320-328`)
is a separate L2 knob and is unchanged: isolated BSS ports still reach the bridge's own
address, so they still reach the gateway.

**VLAN-only networks are not the box's to police.** The box has no address on them (IPv6
off, no IPv4), so a gateway client reaching a VLAN-only network's hosts goes out of the WAN,
masqueraded, and the upstream router routes it, exactly as UniFi does not route a VLAN-only
network either. Saying so in the UI is enough.

**nft mapping (proposed).** One table, sets rebuilt atomically with the rest of the file
(`table … {}` / `delete table` / redefine, as every table on the box does):

```
table inet gt_be98_gw {
  set gw  { type ifname; elements = { brwifi7, brwifi100003 } }   # every gateway bridge
  set iso { type ifname; elements = { brwifi100003 } }            # isolate=1
  set mgmt { type ifname; elements = { brwifi7 } }                # mgmt=1
  chain forward {
    type filter hook forward priority filter; policy accept;
    oifname @gw ct state established,related accept
    oifname @gw ct status dnat accept                  # web UI port forwards (table ip webui)
    iifname @gw oifname "<wan>" accept                 # internet, every gateway network
    iifname @iso drop                                  # isolated: nothing else out
    oifname @iso drop                                  # ... and nothing else in
    iifname @gw oifname @gw accept                     # UniFi default: networks reach each other
    iifname @gw counter drop                           # never to the lifeline / anything else
    oifname @gw counter drop                           # nothing unsolicited into a network
  }
  chain input {
    type filter hook input priority filter; policy accept;
    iifname @gw ct state established,related accept
    iifname @gw udp dport 67 accept
    iifname @gw meta l4proto { tcp, udp } th dport 53 accept
    iifname @gw meta l4proto icmp accept
    iifname @mgmt tcp dport { 22, 80, 443 } accept
    iifname @gw counter drop
  }
}
```

A drop in any table is final (`nft.go` header of the web UI says the same), so this table
composes with `gt_be98_wan` (MSS clamp, IPv6), `webui` (DNAT) and `gt_be98_lan`. The
IPv4 multicast UDP accept of Option A (`gt-be98-lan:467`) is added only when an IGMP proxy
exists (not in phase 1).

**Offloaded flows bypass a policy change.** The flow cache learns only accepted traffic (its
FORWARD hook runs at `NF_IP_PRI_LAST`, after the filter table, `flowcache.c:16-18`,
`:1157-1166`), but a flow offloaded before `isolate` was turned on keeps running in the
Runner. Rule (the general one of `gt-be98-lan:70-72`): every policy apply that **narrows**
access deletes the affected conntrack entries (`conntrack -D -s <subnet>` per newly isolated
network; `conntrack-tools` is in the image, `configs/gt-be98_mainline_defconfig`), and the
flow cache drops an entry whose conntrack is dying (`flowcache.c:101-104`). Arm GW2 proves it
on an offloaded flow, not only on a CPU-path one.

**Management from the WAN side.** Unchanged in phase 1: in AP mode `rnr0` is open to
management and the box filters nothing there (`gt-be98-router:33-34`); a VLAN or PPPoE WAN
already gets `gt-be98-wan`'s input filter (`gt-be98-wan:408`). Filtering untagged `rnr0`
would cut the management path the lab and the owner's LAN use. Whether a gateway box
should treat untagged `rnr0` as "internet" (filtered, `ROUTER_WAN_ALLOW`-style allow-list)
is **owner decision D-GW4**.

---

## 3. DHCP / DNS per network

**One dnsmasq for all gateway networks** (recommended), per-interface tagged ranges, exactly
the shape `gt-be98-wifi-sta` already runs (`gt-be98-wifi-sta:439-454`):

```
bind-dynamic
interface=brwifi7
dhcp-range=set:n7,192.168.40.100,192.168.40.199,255.255.255.0,12h
dhcp-option=tag:n7,option:router,192.168.40.1
dhcp-option=tag:n7,option:dns-server,192.168.40.1
dhcp-hostsfile=/run/gt-be98-gw/dhcp-hosts       # static leases, SIGHUP on change
dhcp-leasefile=/run/gt-be98-gw/leases
resolv-file=/etc/resolv.conf                    # the WAN's resolvers (world-readable)
```

Why one: (a) a single DHCP socket, so no question of several dnsmasq processes sharing UDP
67 (whether the image's existing instances coexist safely is *unverified*; one instance
removes the question); (b) one lease file and one hosts file for the UI; (c) the precedent
works on silicon. Cost: a range change restarts DNS/DHCP for every gateway network for about
a second. Per-network instances would isolate a bad config, but every value is validated
before it is rendered. **Owner decision D-GW6.**

Two traps already paid for: dnsmasq drops to `nobody` before it watches the resolv-file's
directory, so that file must sit in a readable directory (`gt-be98-wifi-sta:72-80`);
`/etc/dnsmasq.conf` has `except-interface=rnr0` (`etc/dnsmasq.conf:3`), which the generated
config must keep for the WAN netdev, whatever it is.

**Single owner of DHCP.** The web UI has its own dnsmasq backend
(`internal/platform/linux/dnsmasq.go`) fed by the older network model's DHCP scopes
(`linux_actions.go:260-282`). It must never serve a gateway bridge; the gateway networks'
DHCP belongs to the OS service, and the UI renders its fields into `networks.conf` and the
static leases into a file the service reads.

**Leases.** In `/run` (volatile): `/jffs` is flash, and dnsmasq rewrites its lease file on
every lease event. A reboot loses the table; clients keep their addresses on renewal
(`dhcp-authoritative`), and static leases cover what must be fixed. **D-GW7.**

**Static leases later (phase 3):** `mac,ip[,hostname]` per line in the hosts file (the web
UI's `RenderDhcpHosts` format already), each IP inside its network's subnet, outside no
rule, unique per MAC and per IP. A change is a SIGHUP, not a restart.

**networks.conf grows** (proposed; unknown keys are already ignored by `gt-be98-lan`'s
parser, `gt-be98-lan:293-301`):
`mode=gateway|vlan dhcp=0|1 dhcp_start=<ip> dhcp_end=<ip> lease=<dur> isolate=0|1 mgmt=0|1`.

---

## 4. Offload of routed paths (open-ethernet main 17e5dfc)

How a routed flow is resolved: the L3 devices are the bridge and the WAN netdev; a bridge is
resolved to the physical port through the FDB (`fc_phys`, `flowcache.c:1623-1633`), and that
port must be a Runner netdev (`runner_fc_port_info`, `netdev.c:194-207`) or a Wi-Fi netdev
with injection (`fc_in_port_info`). An 802.1Q device is accepted only as the **L3 device
itself** (G6, `flowcache.c:286-297`, `:686-708`).

| Path (gateway network member → WAN) | Today | Why |
|---|---|---|
| bare `rnr2` / `rnr3` → `rnr0` | offloaded | FDB → Runner port; the Option A shape (q248 verified the routing; offload on `br-lan` is note 188's shape) |
| bare `rnr2` / `rnr3` → `rnr0.<vid>` (VLAN WAN) | offloaded | G6 push on the egress, q216 |
| Wi-Fi BSS → `rnr0` and back | candidate (`fc_wlan=1 fc_wlan_up=1` in the OS) | W1 egress / W2 ingress through the FDB (`flowcache.c:51-80`, `:1971-1976`); not measured on a gateway bridge |
| **2.5G jacks (`rnr1.<vid>`) → `rnr0`** | **CPU** | FDB returns the VLAN device `rnr1.<vid>`: "ingress is not a Runner port" (`:1943-1946`); reply: "egress is not a Runner port" (`:1969-1978`) |
| 2.5G jacks → `rnr0.<vid>` | CPU | as above; and pop + push is a tag rewrite the builder refuses (`natc_hw.c:1366`: `vlan_push == vlan_pop` → `-EOPNOTSUPP`) |
| network A → network B, both on 2.5G jacks | CPU | as above; once resolved to `rnr1` both ways it would also hit the same-port refusal (`flowcache.c:1981-1985`) |
| any → `pppoe-wan` | CPU | no PPPoE push (`board/gt-be98-mainline/README.md:631`) |

The 2.5G jacks are the lab's and the likely common case, so **phase 1 gateway networks run
on the CPU** for jack clients. The design does not depend on offload for correctness.

**What full speed needs (driver lane, phase 4):**
- **G6b, a VLAN device behind the bridge.** In `fc_l3_resolve_devs`, when `fc_phys` returns
  an 802.1Q device of a Runner port, treat it exactly as G6 treats an L3 VLAN device
  (`in_real`/`out_real`: key `vtag_num 1` + pop on ingress, push on egress). One side tagged
  only, so the existing builder (`xrdp_build_route_vlan_cmdlist`) already emits it. Covers
  jacks → untagged WAN, both directions. Small: the resolution code exists.
- **Tag rewrite (pop + push)** for jacks → VLAN WAN and inter-network on two VLANs: a new
  command-list program, built and proven like q216 (one hand-programmed entry first).
- **Same-port routed (`rnr1.30` → `rnr1.40`)**: router-on-a-stick through the RTL8372 uplink;
  today refused as a hairpin (`flowcache.c:1979-1985`). Silicon behaviour of a Runner entry
  egressing on its own ingress port is unread. Research arm only.

**Risks.**
- *Router-MAC filters:* every L3 ingress MAC needs a parser DA filter; there are 7
  (`RUNNER_DA_FILT_N 9`, first 2, `bcm4916_runner.h:3186`, `parser.c:28`); past that a flow
  fails "no free parser DA filter" (`flowcache.c:2029`) and stays on the CPU (safe, slow).
  Proposed: every gateway bridge gets the same, fixed MAC (one filter for all of them; the
  bridges are separate segments, so a shared router MAC is legal and is what UniFi does).
- *Policy bypass* by offloaded flows: section 2's conntrack delete on every narrowing apply.
- *NAT-C capacity:* routed NAT is two entries per connection; the cap and its fallback are
  already handled (`flowcache.c:213-220`).
- *tc:* a shaper on a gateway bridge keeps its flows on the CPU (G7, `flowcache.c:1640-1665`),
  correct by design.

---

## 5. Migration and safety

**Existing VLAN-only networks are unchanged.** The risk is the opposite: since e3554ed the UI
already stores subnets that "the OS does not act on yet". If the OS read `subnet=` alone as
"gateway", every network a user had already given a subnet would, on upgrade, lose its trunk
VLAN and start a DHCP server. Proposal: gateway mode is the **explicit** `mode=gateway` key,
written by the UI only once the OS advertises it (`rc-service gt-be98-gw features` →
`features gateway`, the same handshake as `gt-be98-lan features`, `gt-be98-lan:139-143`).
A line without `mode=` is VLAN only, whatever its `subnet=`. **D-GW1.**

**Every mode change goes through the 120 s confirm-or-revert** the LAN ports already use
(`l2networks.go:16-21`): turning a network into a gateway moves its clients to a new subnet
at their next DHCP exchange, and the admin may be on it.

**Conflicts the UI must refuse (and the OS re-checks, logging and degrading the one network,
never refusing the whole file):**

1. A gateway subnet overlapping another gateway subnet, the WAN's current address/subnet,
   a static `WAN_ADDR`, the management interfaces (USB lifeline), `LAN_ADDR` (Option A), or a
   Wi-Fi station `routed=` subnet. The WAN check repeats at every lease change (the network
   drops to `local`, as `nat_clash`).
2. Default (VLAN 1) in gateway mode (already refused for a subnet, `l2networks.go:673-676`).
3. A gateway VID equal to `WAN_VLAN` (one VID, one meaning; `gt-be98-wan` already refuses a
   WAN VLAN equal to a trunk VLAN, `gt-be98-wan:143-150`).
4. `WAN_PORT` being a port that is a jack of any network (`rnr2`/`rnr3` profiles).
5. Gateway mode while router mode is applied, and the reverse (D-GW5).
6. Subnet shape for a gateway: RFC 1918, `/16`..`/30` (the Wi-Fi generator's `routed=` rule,
   `gt-be98-wifi-gen:1100`). Today's UI accepts `/1`..`/30` and public ranges, fine for a
   VLAN-only label but not for a NATed LAN. **D-GW9.**
7. DHCP range: inside the subnet, excluding the gateway, the network and broadcast
   addresses; start <= end. Static leases: inside the subnet, outside nothing else, unique.
8. More gateway networks than the forward/route machinery is tested for: cap at 16 in phase 1
   (an owner number, not a hardware one).

**What stays out of phase 1:** IPv6 on gateway bridges (`gt-be98-l2` turns it off, and
`WAN_PD_LANS` accepts only `brwifi` + 1..3 digits, `gt-be98-wan:191`, which excludes
`brwifi100001`); IGMP proxy; port forwarding to gateway clients beyond the UI's existing
`table ip webui` DNAT (which already composes, it is accepted by `ct status dnat`).

---

## 6. Implementation plan, box arms, effort

Lab facts used: one hypervisor peer cabled to jack 6; a hypervisor trunk peer (a VLAN
sub-interface of its admin bridge) for carried VIDs such as 30; the lab's MT7925 Wi-Fi client.
Every arm restores the box byte-identically and runs the regression baseline after.
Endpoints are pre-registered; a missing line is UNREAD, never 0.

### Phase 0: contract (web UI + OS docs), ~0.5 day
`mode=`/`isolate=`/`mgmt=`/`dhcp*` keys in `networks.conf`; `features gateway` handshake;
UI hides the mode switch until the OS says it. No box arm (offline tests only).

### Phase 1: gateway networks, wired, IPv4, CPU path, ~3 days
`gt-be98-l2` gateway mode (no trunk sub-interface, `trunk -` state, mode switch keeps wired
members); netguard invariant 6 + `trunk -` acceptance; `gt-be98-fwd` holder helper with the
three existing owners moved to it; `gt-be98-gw` service (address, table 184 rules, nft,
NAT, one dnsmasq, reroute hook); offline tests in `package/gt-be98-os/test/` with two-way
controls like the existing `gt-be98-lan-test.sh`.

**Arm GW1** (network VID 40, `mode=gateway subnet=192.168.40.1/24 dhcp=1`, jack 6 native 40;
VID 30 stays VLAN only):
- PASS: the jack-6 peer leases in `192.168.40.100..199`, router and DNS `.1`; it pings the
  upstream gateway and resolves a name; a capture on the hypervisor's admin bridge shows the
  peer's requests sourced from the box's WAN address and **0** from `192.168.40.0/24`;
  `rnr0.40` absent; the trunk peer on VID 40 gets **no** DHCP offer from the box; the trunk
  peer on VID 30 still leases from upstream (VLAN-only unchanged); `ip_forward` back to 0 and
  `gt_be98_gw*` tables gone after stop.
- REFUTED: no lease, or any `192.168.40.0/24` source seen upstream, or `rnr0.40` present, or
  VID 30 broken.
- VOID: jack 6 link down, the peer not on VID 40, the WAN without a lease.

**Arm GW1-R** (routing hypothesis of section 1.3): from the jack-6 peer, reach a private
address that is upstream but outside the WAN subnet. PASS: it leaves by the WAN, NATed, while
the USB lifeline holds the main default route. REFUTED: it leaves by the lifeline or is
dropped. **Arm GW1-C** (clash): give the WAN a lease inside `192.168.40.0/24` (lab DHCP
reservation). PASS: network goes `local`, NAT table empty for it, logged; restored on the
next lease.

### Phase 2: policy and Wi-Fi, ~1.5 days
`isolate`/`mgmt` sets, conntrack delete on narrowing, SSID bound to a gateway network.
**Arm GW2** (network 40 on jack 6, network 41 on an SSID, the MT7925 client):
- PASS: 41 ↔ 40 ping both ways with `isolate=0`; set `isolate=1` on 41: blocked both ways
  within 5 s, **including an iperf3 flow started before the switch** (read the flow cache's
  programmed count before, to know whether it was offloaded), internet from 41 still works;
  from isolated 41, TCP 22/443 to its gateway refused while DHCP/DNS work.
- REFUTED: any cross traffic after the switch, or the pre-existing flow survives.
- VOID: the client does not associate, or the pre-switch flow never started.

### Phase 3: DHCP options and static leases (mostly web UI), ~1.5 days
Range/lease fields, static leases into `dhcp-hosts`, a leases view.
**Arm GW3:** a reservation for the jack-6 peer's MAC; PASS: it gets exactly that address after
a `dhclient` release/renew, and the change was a SIGHUP (dnsmasq pid unchanged).

### Phase 4: offload G6b (open-ethernet lane), ~2-3 days + arm
**Arm GW4** (driver with G6b; read `flowcache` debugfs stats before and after):
- PASS: iperf3 jack-6 peer → an upstream host for 30 s: entries programmed for both
  directions, hardware hit counters move, the CPU path carries <= 10 % of the packets
  (q216's criterion), frames on the wire tagged correctly, none malformed, no new `noport`
  failures with "is not a Runner port".
- REFUTED: entries programmed but traffic broken or malformed (roll back), or still on CPU.
- VOID: the flow never reaches established, or offload is off.
Baseline (before G6b, same arm): pre-registered expectation "noport grows, programmed stays
0 for this flow". Tag rewrite and same-port routing: research only, no shipped code, until
an arm like q216 proves one hand-programmed entry.

### Phase 5: IPv6 on gateway networks (implemented: buildroot `br-gw-ipv6-2026-11-17`, web UI `wu-gw-ipv6-2026-11-17`)
UniFi's model, no NAT66. The design sentence that stood here (widen `WAN_PD_LANS`, RA from
`gt-be98-wan`'s own dnsmasq) was not followed: it would have given gateway bridges two IPv6
owners and a second RA daemon, and every network added would have rebound the WAN's dhcpcd
(a new `ia_pd` interface list). As built:
- **The WAN asks, gt-be98-gw assigns.** `WAN_IPV6=1` always requests a prefix (`ia_pd 2[/::/LEN]`);
  without `WAN_PD_LANS` it is assigned to no interface (`ia_pd ... -`; an `ia_pd` with no interface
  would make dhcpcd assign a /64 to *every* other interface, a latent defect of the old rendering).
  The dhcpcd hook records the lease's `new_dhcp6_ia_pd1_prefix1*` (`gt-be98-wan pd6`: prefix and
  remaining lifetimes, never read back after `WAN_IPV6=0` or a WAN netdev change) and runs
  `gt-be98-gw reroute` on every change, an RA, and the lease's loss.
- **Per network** (`ipv6=off|slaac|dhcpv6 ipv6_prefix_id=<hex>` in `networks.conf`): its /64 is number
  `ipv6_prefix_id` of the delegated prefix (after `WAN_PD_LANS`' 0..n-1), the gateway `<64>::1` with
  the delegation's lifetimes, IPv6 on on that bridge only while active (`gt-be98-l2` leaves a held
  bridge's `disable_ipv6` alone), `ip -6 rule iif <br>` main-without-default then table 184 (the WAN's
  IPv6 default), the whole delegated prefix unreachable in main (metric 4184). States off / waiting /
  active / refused, `net6` lines in `gt-be98-gw status`, `pd6 <prefix>`.
- **RA from the one dnsmasq**: `slaac` = `ra-stateless` (A+O flags), `dhcpv6` = a stateful range
  `::1000-::1fff` (M flag); DNS = the gateway (`option6:dns-server,[::]`). The lines name the bridge
  (`constructor:`), never the prefix: a renumbering restarts nothing.
- **Policy** in the same `table inet gt_be98_gw`: set `v6`; IPv6 out of the WAN for `@v6`, IPv4 for
  `@nat`; from the WAN only replies (the existing `oifname @gw ct state established,related` /
  `oifname @gw counter drop`); isolate and management as IPv4; input ICMPv6 and DHCPv6 (547)
  always. Narrowing deletes the /64's conntrack entries (`-f ipv6`).
- **Forwarding**: `gt-be98-fwd -6` (holders `wan`, `gw`) replaces `gt-be98-wan`'s own save/restore
  of `net.ipv6.conf.all.forwarding`.
Arm GW5 (orchestrator's `bin/gw5-ipv6-arm.sh`) runs it against a DHCPv6-PD server in a PVE netns.

**Total:** phases 0-3 about 6.5 working days (OS ~4.5, web UI ~2), phase 4 2-3 days plus box
time, phase 5 1.5 days. The arms GW1, GW1-R, GW1-C, GW2, GW3 are the orchestrator's; GW4 is
on the driver lane's image.

---

## Decisions for the owner

| # | Question | Recommendation |
|---|---|---|
| D-GW1 | Is gateway mode an explicit `mode=gateway`, or does any stored subnet mean gateway? | Explicit; subnets already stored stay inert until the user switches the mode. |
| D-GW2 | Default inter-network policy | UniFi's: networks reach each other; `isolate=1` per network. |
| D-GW3 | Management (SSH, web UI) from gateway networks | On for non-isolated networks, off for isolated ones; DHCP/DNS/ICMP always. |
| D-GW4 | Filter the box's input on untagged `rnr0` once it routes? | Not in phase 1 (it is the management path); later, a "WAN is the internet" switch with an allow-list. |
| D-GW5 | Router mode (`gt-be98-router`) | Mutually exclusive now; retire after phase 2. |
| D-GW6 | One dnsmasq or one per network | One. |
| D-GW7 | Lease file location | `/run` (volatile), static leases for what must not move. |
| D-GW8 | Offload | Phase 4 G6b (jacks → untagged WAN) yes; tag rewrite and same-port routing as research only. |
| D-GW9 | Allowed gateway subnets | RFC 1918, `/16`..`/30`. |
| D-GW10 | IPv6 on gateway networks | Out of phase 1; phase 5 (implemented, see §6 Phase 5). |
