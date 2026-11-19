# GT-BE98 mainline OS 1.0-rc12 - release notes

Date: 2026-11-19 · Status: **DRAFT**, release candidate 12, not tagged.

> DRAFT until the release-image box phases have run: the phases row and
> the tags are the last placeholders (`⟨…⟩`). The candidate's box evidence
> (q325–q331), the release images and their checks are final.

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
| `rootfs.squashfs` | `b839b94994ba09de2489cac300bb953aced7194509c70dc469f65dcfd69bfc1a` |
| `ml-bootfs.itb` | `76d2c7daa96327d52233aaade3470f3ae120104598cc0d0e0536ee79b9734f72` |

Build id (DT): `20261119T163327Z-5c1dcbea3182-rw-jffs`

Built with `RELEASE=1` (`ml-bootfs.info`: `release mode: yes`) from
`br-rc12-r-2026-11-19` `fae42b0`. Later commits of that branch change only
`docs/`.

- **Release check:** `release-check.sh` returned PASS (selftest 21/21) with RC7's lab-pattern list.
- **Lab control:** the lab image imgint11 fails the same check with 15 findings, as it should.
- **Exact-pattern list:** finds only the lab public key, as in RC7–RC11.
- **Modules against the tested lab image (imgint11):**
  - **`rtl8372.ko` is byte-identical** (`39323095`).
  - **`bca_pcie_ipc.ko` and `bcm4916-runner.ko`** are the same build at a
    different path. The kernel-module builds embed their build directory
    (in `__FILE__` strings), and the release build has its own output
    directory, so the files differ (release `a749242f` / `8f5ff8e0` vs
    lab `ef62b85c` / `7305bbc3`). RC11's release modules differed from
    its lab image's the same way.
  - **Compared section by section, every code and relocation section is
    identical:** 34 of 37 sections in `bca_pcie_ipc.ko`, 38 of 41 in
    `bcm4916-runner.ko`.
  - **`.rodata`** is identical once the build-path prefix is swapped (21
    and 8 occurrences).
  - **`.symtab`** differs only in symbol values: 26 and 14 `.rodata`
    symbols, shifted by the two paths' length difference.
  - **`.note.gnu.build-id`** is a hash over the contents, so it follows.

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
- q326 (r5, imgint10, the RC12 module): GW6-up/dn PASS at 0.027 / 0.024
  cores/Gbit. **GW4X PASS: the stop fix confirmed.** M PASS. WIRE and R PASS.
  GW4-up/dn medians 0.070 / 0.087, but the maxima 0.115 / 0.149 broke the
  bar: those spikes were the per-RA bursts, fixed below.
- **q330 (r5, imgint11 = RC12): every cell PASS but N.** GW4-up/dn at
  **0.042 / 0.037** cores/Gbit; GW6-up/dn at 0.025 / 0.026; GW4X, M, V6,
  WIRE and R PASS. Idle windows read 0.02–0.07 cores: the bursts are gone.
  N REFUTED `post_hw_old` as predicted (RUNNER-L3-FDB-Q1, known open).

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
- q325 (eht24-default arm, imgint10, the RC12 generator and web UI):
  - E-GEN and E-LIVE PASS: 2.4 GHz renders and runs without EHT, 5/6 GHz
    with it.
  - The client associates HE in 3/3 repetitions, and the AP sounds it:
    NDPA 237/232/236 per repetition.
  - The explicit `be=1` brings EHT back.
  - Default vs `be=1` downlink: **1.47×**.
  - The arm's VERDICT is **FAIL, on its absolute downlink bar alone**:
    E-DN read 148.7 Mbit/s against the pre-registered 150 (q320 read
    159–169 on the same bench). The relative gain, the HE association and
    the sounding (the reasons for the decision) all hold.

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

Box: q326 (imgint10) and q330 (imgint11) GW4X PASS. With a live offloaded flow, nothing is left in hardware after the stop.

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

Box: q326 (imgint10) gateway r17 GW1 and GW2 PASS. GW2's management check runs through `mgmt-addrs`.

### Fix: an unchanged IPv6 RA re-applied every gateway network (OS `gt-be98-wan`)

**The defect.** dhcpcd 10.2.4 runs its ROUTERADVERT hook for every Router
Advertisement it receives, changed or not (`ipv6nd_handlera` →
`ipv6nd_scriptrun`, no test of new data). gt-be98-wan's hook answered every
one with a full `gt-be98-gw reroute` in the background: the rule set, the
tables, dnsmasq, and with `WAN_PD_LANS` a flush and rebuild of table 182.
That is about 1.8 CPU-seconds per RA, at the router's advertising interval
(the lab's WAN server sends one every 20 s).

**How it was found.** No new box run was needed. The per-process tables of
the tagrw r4 run record (q325) show the CPU of the hot windows in REAPED
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
- **q330 (imgint11): NO-HOT, as predicted.** Every idle window read
  0.02–0.07 cores (imgint10 in q326: spikes up to 0.149 cores/Gbit in IPv4
  runs). The IPv4 D42 runs now cost 0.042 / 0.037 cores/Gbit.
- q330: gw5-ipv6 r11 FULL PASS on imgint11, pinned to the new gt-be98-wan
  `b4db4370…`: WS, S, GW5, GW5M, GW5D, GW5S, GW5L, WIRE, R. The paths that
  must still act (a new router, SLAAC, DHCPv6, stop/start, WAN revert) do.
- q330: the PPPoE IPv6 arm (bench module, see "Not in RC12") watched the
  RAs separately. The box was quiet both ways; the only forks left are
  dhcpcd's hook itself (230 vs 102).

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
- q325 (imgint10), a normal boot: no FALLBACK line. Port 80 listens on
  loopback, then on the management address once DHCP gives it, never on
  the wildcard.
- q325: WAN admin reach PASS. Web UI :80 and SSH :22 from the WAN side are
  dropped; the management path connects on both.

## Box evidence (imgint10 / imgint11 as noted)

| Queue | Image | Result |
|---|---|---|
| q320 | lab, bench ko | DN24: EHT off 159/163/169 vs on 97/92/95 Mbit/s, HE sounded |
| q322 | imgint9 + bench Runner ko | D42 tag rewrite on silicon, WIRE clean, R PASS |
| q323 | lab | DN24 last lever: bit 0x80 masked by the firmware on 2.4 GHz |
| q324 | imgint9 + bench Runner ko | D42 r3: GW6-up/dn PASS 0.093/0.094 cores/Gbit, M PASS; GW4X race found |
| q325 | imgint10 | listener PASS (no fallback); fixed-primary PASS; eht24 FAIL on E-DN only (148.7 vs 150 Mbit/s; HE 3/3, sounded, `be=1` EHT back, 1.47×); WAN admin reach PASS; UI degraded-apply PASS; perf smoke 5gl/6g throughput −4..−13 % (re-measured in q326: drift). tagrw r4 / gateway r16 VOID at G (an arm bug, the new `mgmt-addrs` word); gw5 r10 WS REFUTED (an arm race, fixed in r11) |
| q326 | imgint10 (+ imgint9 for ABA) | tagrw r5: GW6 PASS 0.027/0.024, GW4X PASS (stop fix), M WIRE R PASS, GW4 spikes = RA bursts; gateway r17 GW1 GW2 PASS; **perf ABA: imgint10 = imgint9 on every gated row** (5gl 883/826 vs 884/824, 6g 1363/1067 vs 1332/1063 Mbit/s): q325's smoke dip was drift |
| q327 | imgint10 | gw5-ipv6 r11 FULL PASS (WS S GW5 GW5M GW5D GW5S GW5L WIRE R) |
| q328 | imgint10 + bench Runner module | PPPoE IPv6 offload arm r1: G VOID (the jack-6 peer was not in its PVE netns: the queue did not place it and the arm assumed it). R `pve_clean` flagged by the arm's own process match. Nothing was changed on the box or PVE |
| q329 | imgint10 + bench Runner module | The same arm with the peer placed: IPv6 over PPPoE works and is offloaded on silicon. PV6-up PASS 0.090 cores/Gbit; PV6-dn REFUTED on CPU cost alone (0.163; idle windows of that run were busy too. On imgint11, without the RA bursts, q330 PV6-dn PASS 0.045); RL PKG S PU V6 WIRE PURGE PASS. Not in RC12 |
| q330 | imgint11 | **RA fix confirmed:** tagrw r5 GW4 0.042/0.037, GW6 0.025/0.026, GW4X M V6 WIRE R PASS, N `post_hw_old` (Q1), idle 0.02–0.07 (NO-HOT); gw5-ipv6 r11 FULL PASS; pppoe6 r3 (bench module, not in RC12) PV6 PASS |
| q331 | imgint11 | **RC12 regression set PASS:** baselines PASS; UI degraded-apply PASS; L1 two cycles real 0/0, dsmb 0; WIFISTOP r2 PASS + RESTORE-OK; soak DRY-OK; perf smoke: every gated 5gl/6g row OK, only the 2.4 GHz RTL row flagged (noisy, never gated: 25–31 Mbit/s within q326 alone) |
| q331 | imgint11 | **30-minute release soak PASS** (rc12-soak.sh; identity checked: bca `ef62b85c`, runner `7305bbc3`) |
| ⟨qNNN⟩ | release | ⟨release-image box phases: first n/n, second n/n; lab image imgint11 restored⟩ |

## Known open

**Offload**
- **RUNNER-L3-FDB-Q1** (a design question): when a client's IP moves to
  another host (N), the old host's uplink entry stays on its bridge port
  until `fc_idle_s`. Q1 is whether L3-FDB should drop it at once
  (q322/q324 N REFUTED `post_hw_old`). The FDB move (M) passes.
- **The RC11 q305 cores/Gbit dip** is still unexplained. It was not
  reproduced on imgint8 (q307), imgint9 (q309) or in q326's ABA
  (imgint10 = imgint9 on every gated row). q325's own smoke dip was drift
  by the same ABA.

**Not in RC12**
- **PPPoE routed-IPv6 offload** (open-ethernet `oe-pppoe-v6-2026-11-19`
  `c56b79b`) is proven on silicon, but only with a bench module:
  - q329 (imgint10): the IPv6-over-PPPoE OS path and the uplink offload.
  - q330 (imgint11): PV6-up/dn PASS at 0.039 / 0.045 cores/Gbit.

  It is not in RC12's Runner module (`7305bbc3`). RC12 routes IPv6 over
  PPPoE on the CPU. → RC13.

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
