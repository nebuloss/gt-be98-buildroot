# GT-BE98 mainline OS 1.0-rc12 - release notes

Date: 2026-11-19 · Status: **DRAFT**, release candidate 12, not tagged.

> DRAFT. Every `⟨…⟩` is a placeholder. Fill it from the named run, or drop
> the line. Do not tag until the regression set, the soak and the release-image
> phases have their rows.

Evidence is named by the orchestrator's queue (`qNNN`). The run directories
stay on the orchestrator's machine and are not in this repository. Every
number comes with the run that measured it, and "not measured" never means
0. Lab image `imgint11` is the lab-mode build of the RC12 sources (same
commits, lab keys). The integration image `imgint10` is imgint11 without
the RA fix and with the box-tested open-ethernet commit (see below). The release images below are the `RELEASE=1` build of
those sources.

RC12 is a small candidate on top of RC11:

- **Runner offload of VLAN ↔ VLAN routed flows (D42)**, IPv4 with NAT and
  routed IPv6: a jack on a VLAN gateway network to a VLAN-tagged WAN.
- **2.4 GHz defaults to Wi-Fi 7 off** (the owner's decision); 5 and 6 GHz
  stay Wi-Fi 7.
- **Gateway networks:** a stopped network's connections are cut cleanly
  (conntrack deleted last), and a cheap `gt-be98-gw mgmt-addrs` query for
  the web UI.
- **The web UI admin listener** is managed from boot: loopback plus the
  watcher, and a logged wildcard fallback only after 90 s without an
  address.
- **Fix: an unchanged IPv6 Router Advertisement no longer re-applies the
  gateway networks.** Every RA cost about 1.8 CPU-seconds; this was the
  intermittent idle-CPU bursts.

## Images

| File | sha256 |
|---|---|
| `rootfs.squashfs` | `⟨release rootfs sha256⟩` |
| `ml-bootfs.itb` | `⟨release itb sha256⟩` |

Build id (DT): `⟨release build id⟩`

Built with `RELEASE=1` (`ml-bootfs.info`: `release mode: yes`).

- **Release check:** `⟨release-check.sh result, selftest n/n⟩` with RC7's lab-pattern list.
- **Lab control:** `⟨the lab image imgint11 fails the same check with N findings⟩`.
- **Exact-pattern list:** `⟨expected: finds only the lab public key, as in RC7-RC11⟩`.

**These images are a TEST build.** Their `SSH_AUTHORIZED_KEYS` is the
lab's public key, so they are never handed over. A hand-over build is the
same sources with the recipient's keys, checked again with
`release-check.sh`. The images contain no SSH host keys, no web UI
password and no rootfs URL. They contain proprietary vendor firmware, so
they are handed over privately and never published (`docs/RELEASE-BUILD.md`).

Lab image imgint11: `rootfs.squashfs`
`792c7a3e81bf2669b662c00dbf34ff96f30eb30c9041ae0b56f669e603b2c2c6`,
build id `20261119T133846Z-f5a0e85515e6-rw-jffs`. Its rootfs differs from
imgint10's (`9bd89d85…`, build id `20261119T122314Z-f8d100655f55-rw-jffs`,
the image of q325–q327) in exactly two files, by a file-by-file comparison
of both trees: `/usr/sbin/gt-be98-wan` (the RA fix) and
`/etc/gt-be98-release` (open-ethernet `effa5fa` instead of `b367e51`, and the
build time). Against RC11's lab image imgint9, imgint10 differs in
`/usr/sbin/webui`, `/usr/sbin/gt-be98-gw`, `/usr/sbin/gt-be98-wifi-gen` and
the Runner module. The Wi-Fi and switch modules are byte-identical
throughout.

Built from (`gt-be98-rc12` tags, ⟨to be set⟩):

| Component | Commit |
|---|---|
| gt-be98-buildroot | `br-rc12-r-2026-11-19` (= `br-int10-2026-11-19` `9521749` + these notes + the open-ethernet pin `effa5fa` + `br-ra6-reroute-2026-11-19` `f21929d` + its mutants; `mainline-os` `aed50af` is already its base). imgint11 was built from `f21929d`; later commits change only `docs/` and `test/` |
| open-wifi (`bca_pcie_ipc.ko`) | unchanged since RC11: `4040667a` (module byte-identical, `ef62b85c`) |
| open-ethernet (Runner, kernel series, `rtl8372.ko`) | `oe-tagrw-clean-2026-11-19` `effa5fa` (= RC11's `main` `a9c80d1` + TAGRW `72c62cf` + a checkpatch pass + one tools-only cleanup); Runner module `7305bbc3`. The box-tested commit is `b367e51` (q322–q327, imgint10); `b367e51..effa5fa` touches only `tools/xpe/` and the module built from `effa5fa` is byte-identical |
| web UI (gt-be98-webui-go) | `wu-int10-2026-11-19` `e338c18` (= RC11's `main` `45d466a` + `wu-24g-eht-off` `0fa2463` + `wu-gw-mgmtaddrs` `5d910cc` + `wu-admin-listen` `5bcfb7f`) |
| hostapd | 2.12 with the local patches `0001`, `0002`, `0003` (unchanged) |
| Linux / Buildroot | 7.2.9 / 2026.08 (kernel configuration unchanged since RC7) |

**Shipped Wi-Fi driver parameters:** unchanged from RC11 (the module is
byte-identical).

## Changes since RC11

### Runner offload of VLAN ↔ VLAN routed flows (D42) (open-ethernet `driver/runner`)

**What changed**
- A routed flow whose two sides are both 802.1Q devices of Runner ports
  (a jack bridge-port VLAN of a gateway network ↔ a `rnr0.<VID>` WAN) is
  now offloaded with the tag rewritten: popped on ingress, pushed on egress
  (18 → 18 bytes of L2, tx adjust 0, stock's pull branch). RC11 refused it
  ("VLAN to VLAN (tag rewrite) not built"), so those flows stayed on the CPU.
  The same port on both sides and VID 0 are still refused.
- **Routed IPv6** (no NAT66) takes the same path. An IPv6 entry keeps its
  route and is looked up again, as an input route from its ingress device,
  when the route goes stale. It is kept only for the same egress and next
  hop. A prefix removed from an interface (DHCPv6-PD renumbering) drops the
  entries of that prefix.
- The next-hop re-check against the neighbour table is RUNNER-L3-FDB's
  (RC11), for both families. The rebased branch drops RT-IPV6's own second
  notifier for it.
- `flows` shows a tag-rewrite counter and an "l3 revalidation" line.

**Host tests:** `fc_vlan_test` (rewrite cases), `fc_reval_test` (4015
checks), `xpe_rt_check` retag4/retag6, `flow_cmdlist_check` retag4/retag6
plus the refused-retag cases and mutants; `fc_bind_test` 30 590 checks.

**Box evidence (bench module of `b367e51` on imgint9)**
- q322: the rewrite programs and hits on silicon. The tag-rewrite counter
  moves on the hardware entries, both tag operations are on both entries,
  and the wire check is clean (every frame the WAN netns sent went to the
  box).
- q322 re-scored by r3's matcher: the IPv4 reply direction was offloaded
  too (`dir reply ... vlan-pop 30 ... vlan-push 40`, 2.46 GB in hardware).
  r2's matcher expected the translated port; the driver prints 0 for an
  address-only NAT.
- q324 (r3): routed IPv6 **GW6-up / GW6-dn PASS at 0.093 / 0.094
  cores/Gbit**. The L3-FDB FDB move (M) PASS. IPv4 GW4-up/dn offloaded
  (CPU fraction 0.000 / 0.002) but REFUTED on CPU cost alone; see the
  box background load fixed below.
- q324 GW4X (stop with a live flow) REFUTED: a race in gt-be98-gw's stop.
  It is fixed in this candidate, see below.
- ⟨q326: tagrw r5 on imgint10 — GW4X with the stop fix, GW4 up/dn, N/M, GW6⟩
- ⟨qNNN: tagrw r5 on imgint11 — GW4 up/dn with the RA fix: NO-HOT predicted⟩

### 2.4 GHz defaults to Wi-Fi 7 off (OS `gt-be98-wifi-gen`, web UI)

**The owner's decision (2026-11-19).** The 2.4 GHz radio's default is now
Wi-Fi 6 (HE). The 5 and 6 GHz radios stay Wi-Fi 7 (EHT). An explicit `be=1`
on the 2.4 GHz radio still turns EHT on there.

**Why (open-wifi ledger DN24-1, `om-dn24-2026-11-18` `456fcc86`)**
- The 2.4 GHz firmware never sounds an EHT association, so it never
  beamforms one. Stock firmware behaves the same.
- The only untested lever was the beamformer capability bit 0x80. The
  firmware masks it on 2.4 GHz: set returns 0, and it reads back 0x25 in
  the same window (q323). No host lever is left.
- With EHT off, the same HE-capable client measured **159/163/169 vs
  97/92/95 Mbit/s** downlink (q320), with HE sounding (NDPA 217–237 per
  repetition vs 0) and lower latency.
- MLO is not shipped, so 2.4 GHz EHT brings nothing in exchange.

**What changed**
- Generator: an unset `be` on radio `2g` means 0. With `be=0` no `eht_*`
  line is written on 2g. `be=1` on 2g renders `ieee80211be=1` +
  `eht_su_beamformer=1`, as before; `be=1` with `ax=0` is still refused.
- Web UI: a per-radio Wi-Fi 7 default (off on 2.4 GHz, on at 5/6 GHz).
  `be=` is written only when it differs from the radio's default. The
  toggle's help says why 2.4 GHz is off by default.
- **One-time migration.** Every radio save before this one stored
  `RADIO_2g_EHT=1` whether or not the admin touched Wi-Fi 7, so a stored
  "1" cannot tell a choice from the old default. It is dropped once (marker
  `EHT24_DEFAULT_OFF_MIGRATED`, logged); a stored "0" is kept. An admin who
  really meant Wi-Fi 7 on 2.4 GHz ticks it once more.
- A web UI on an OS generator older than this one still runs an unset 2g
  as EHT.

**Side effect: beacon protection on 2.4 GHz.** hostapd 2.12 turns beacon
protection on by itself only on EHT radios. On the HE-only 2.4 GHz radio
the generator's `-B` rule now decides, as it already did for HE-only
radios: SAE, psk2sae and OWE get `beacon_prot=1`. **WPA2-Personal and
WPA2-Enterprise BSSes on 2.4 GHz no longer get beacon protection
automatically** (stock's rule).

**Box evidence**
- ⟨q325: eht24-default on imgint10 — E-GEN / E-LIVE / E-HE / E-BE1 / E-SND, E-DN against the 150 Mbit/s bar⟩

### Gateway networks: stop cuts the path before deleting conntrack (OS `gt-be98-gw`)

**The defect (q324 GW4X).** `gt-be98-gw stop` deleted a network's
conntrack entries first, and only then the NAT and filter tables and
forwarding. A live stream re-created its entry in that window. The entry
was masqueraded and offloaded again, and the cut left it in hardware.

**The fix (`br-gwstop-ct-2026-11-19` `015f2d9`).** Stopping a network
(IPv4 and IPv6) queues its subnet. The queued entries are deleted at the
end of `apply` (after the rule set, routes and forwarding) and of `stop`
(after both tables are deleted and forwarding is released). The narrowing
changes (isolate, mgmt, NAT refused) already deleted after the rule set.

Tests: `gt-be98-gw-test` checks the order against `ip_forward` at each
delete; the full `gt-be98-gw-mutants` set (64) is killed.

Box: ⟨q326 GW4X on imgint10⟩

### `gt-be98-gw mgmt-addrs` (OS `gt-be98-gw`, web UI)

**The query.** `gt-be98-gw mgmt-addrs` prints the admin UI's listen set:
one line per address of every running gateway network with `mgmt=1`.
- IPv4: the gateway address.
- IPv6: `<prefix>::1`, only while that network's IPv6 is active, applied
  and past DAD (the rule `status` uses since RC11).

It reads gt-be98-gw's own state files only. It forks at most once (`ip -6`,
only when an IPv6 address is applied). `status` forked gt-be98-wan three
times, gt-be98-fwd twice, and `sed`/`grep` per network. `features` now
lists `mgmt-addrs`.

**The web UI** asks `mgmt-addrs` when the OS lists that feature and a
gateway network has management on. It falls back to `status` otherwise,
or when the query fails. This completes RC11's watcher cost reduction for
boxes that do have a managed gateway network.

Box: ⟨q326 gateway r17 GW1 GW2 on imgint10 (mg_pre through mgmt-addrs)⟩

### Fix: an unchanged IPv6 RA re-applied every gateway network (OS `gt-be98-wan`)

**The defect.** dhcpcd 10.2.4 runs its ROUTERADVERT hook for every Router
Advertisement it receives, changed or not (`ipv6nd_handlera` →
`ipv6nd_scriptrun`, no test of new data). gt-be98-wan's hook answered every
one with a full `gt-be98-gw reroute` in the background: the rule set, the
tables, dnsmasq, and with `WAN_PD_LANS` a flush and rebuild of table 182.
That is about 1.8 CPU-seconds per RA, at the router's advertising interval
(the lab's WAN server sends one every 20 s).

**How it was found.** No new box run was needed. The per-process tables of
the tagrw r4 run record (⟨its queue⟩) show the CPU of the hot windows in REAPED
children: init's `cutime` grew by +177..179 jiffies per episode (the
orphaned background reroute), and dhcpcd's by +24..25 (the hook runner).
This holds in every hot window and in no cold one, 94 % of the excess. The
windows were 0.11–0.41 cores, user:sys about 1:2.6 on all four CPUs, never
softirq.

**The fix (`br-ra6-reroute-2026-11-19` `f21929d`).** The hook keeps the
WAN's IPv6 state from the last RA it acted on: `<netdev> <default routers>
| <global addresses>`, without lifetimes or flags. An RA that leaves it
unchanged returns at once. Any other hook reason, and a stop, forget it,
so the next RA is acted on in full. A new router, a router gone (dhcpcd's
ROUTERADVERT on expiry) or a new SLAAC address still reroute.

Tests: `gt-be98-wan-test` 261/261 (dash and bash). The 3 new checks fail on
the old script. Their controls still act: another router, a new global
address, INFORM6/RENEW6, a stop/start, an expired route. `gt-be98-gw-test`
213/213. `gt-be98-gw-mutants` gains six mutants (no early return, state
never recorded, stop or another reason keeping it, addresses or routers left
out of it): all killed.

**Box evidence**
- ⟨qNNN: tagrw r5 on imgint11 — the idle windows NO-HOT (prediction), the per-process tables without the reaped-reroute signature⟩
- ⟨qNNN: gw5-ipv6 r11 on imgint11 (SHA_WAN `b4db4370…`) — SLAAC, DHCPv6, renumbering paths still act⟩

### The web UI admin listener is managed from boot (web UI)

**RC11's known-open item.** The web UI starts before DHCP gives the
management interface its address. After a plain boot it therefore took the
"nothing resolvable" branch: one wildcard listener on port 80 for the life
of the process, and no watcher. A disabled admin portal and the per-address
bindings were not enforced after a boot.

**Now**
- At start: the loopback lifeline plus whatever already resolves. The
  watcher runs either way and binds addresses as they appear.
- If no address is bound 90 s after start, one wildcard listener replaces
  the lifeline. It is logged as `admin: FALLBACK: ...`, so an address that
  never comes never locks the owner out.
- As soon as an address resolves, the fallback closes and loopback plus the
  portals are bound. If loopback cannot be bound, the fallback is put back:
  there is never no listener.
- Stock mode and an explicit `-listen` host are unchanged.

Tests: real sockets on loopback (no address then bound; a disabled portal
stays unbound; fallback then left), six boot mutants.

**Box evidence**
- ⟨q325: listener reading on a normal boot — no FALLBACK line, loopback then the management address on :80, no wildcard⟩
- ⟨q325: WAN admin reach PASS (WAN :80/:22 dropped; management path connects)⟩

## Box evidence (imgint10 / imgint11 as noted)

| Queue | Image | Result |
|---|---|---|
| q320 | lab, bench ko | DN24: EHT off 159/163/169 vs on 97/92/95 Mbit/s, HE sounded |
| q322 | imgint9 + bench Runner ko | D42 tag rewrite on silicon, WIRE clean, R PASS |
| q323 | lab | DN24 last lever: bit 0x80 masked by the firmware on 2.4 GHz |
| q324 | imgint9 + bench Runner ko | D42 r3: GW6-up/dn PASS 0.093/0.094 cores/Gbit, M PASS; GW4X race found |
| q325 | imgint10 | ⟨listener, fixed-primary, eht24, WAN reach, UI degraded-apply, perf smoke⟩ |
| q326 | imgint10 (+ imgint9 for ABA) | ⟨tagrw r5, gateway r17 GW1 GW2, gw5-ipv6 r10, perf ABA imgint10/imgint9/imgint10⟩ |
| q327 | imgint10 | ⟨gw5-ipv6 r11⟩ |
| ⟨qNNN⟩ | imgint11 | ⟨RA fix box verification: tagrw r5 (NO-HOT predicted) + gw5-ipv6 r11⟩ |
| ⟨qNNN⟩ | imgint11 | ⟨**RC12 regression set** (RC12-REGRESSION-QUEUE.sh): UI degraded-apply, L1 two cycles, WIFISTOP r2 + RESTORE-OK, soak DRY, perf smoke, baselines⟩ |
| ⟨qNNN⟩ | imgint11 | ⟨**30-minute release soak** (rc12-soak.sh; identity bca `ef62b85c`, runner `7305bbc3`, webui `ebfb76e2`, gw `8e664b6a`, wifi-gen `d911ec41`, wan `b4db4370`)⟩ |
| ⟨qNNN⟩ | release | ⟨release-image box phases: first n/n, second n/n; lab image imgint11 restored⟩ |

## Known open

**Offload**
- **RUNNER-L3-FDB-Q1** (a design question): when a client's IP moves to
  another host (N), the old host's uplink entry stays on its bridge port
  until `fc_idle_s`. Q1 is whether L3-FDB should drop it at once
  (q322/q324 N REFUTED `post_hw_old`). The FDB move (M) passes.
- **The intermittent box background CPU bursts are FIXED, pending box
  verification.** The cause was the per-RA gateway re-apply above (q324
  IPv4 LON runs 0.085–0.220 cores/Gbit overlapped it). It is fixed in
  `f21929d`. ⟨qNNN tagrw r5 on imgint11: NO-HOT⟩ — until that row is
  filled, this stays open.
- **The RC11 q305 cores/Gbit dip** is still unexplained. It was not
  reproduced on imgint8 (q307) or imgint9 (q309). ⟨q326 perf ABA
  imgint10/imgint9/imgint10⟩.

**Wi-Fi**
- **D36–D40:** MLO on 5 GHz is pending.
- **Band steering** works in the daemon but is limited by the client. The
  lab's MT7925 advertises no 5 GHz operating class (q290/q293
  VOID-NOCAP5). The default stays off.
- **Zero-wait DFS on 5gh in ETSI** is not in RC12 (hostapd cold-start
  patch pending).

**Ports**
- The cabled 1G (rnr2) and 10G (rnr3) ports have not carried traffic on
  this OS. Their arms need a cable move.
- 2.5 Gbit/s line rate and more than one cabled jack remain untested.

**Repository hygiene:** RC12's open-ethernet commit `effa5fa` is the
box-tested `b367e51` plus one tools-only cleanup: a test fixture's source
address moved to the documentation range. The Runner module built from it is
byte-identical to `7305bbc3`. Older commit messages
already on public branches stay in the history: removing them would need a
force push, which is not done.

**Carried over from RC10/RC11**
- WPS overlap detection is unproven.
- IO-coherent PCIe stays bench-only.
- Web UI `go test -race` has an isolation issue in older tests.
- hostapd patches `0002` and `0003` are not reported upstream.
