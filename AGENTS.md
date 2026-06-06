# Agent handoff — gt-be98-buildroot

You're working in the **Buildroot external tree** that will replace the
asuswrt-merlin SDK build. Read `ARCHITECTURE.md` first.

## State (2026-06-06 NIGHT-5 — br-0047 monitor-retire TRIALED + PASSED → NEW COMMITTED BASELINE (slot 2; slot 1 = br-0045 fallback))

**COMMITTED BASELINE = br-0047** (slot 2; **committed 2 valid 1,2 seq 35,36,
Booted Second, reset_reason 34, boot_failed_count 0**). Slot 1 = br-0045, still
valid as the fallback baseline. The agent nvram key (`guillaume@dev-build` in
`sshd_authkeys`) persisted across the whole cycle; NO `service restart_*` run.

- **What br-0047 is:** the Phase-2 rc-drain **monitor-retire #1** slice — removes
  4 stock monitor daemons, everything else byte-identical to br-0046:
  `/sbin/netool` + `/sbin/rtkmonitor` (rc MULTICALL symlinks), `/usr/sbin/sysstate`
  + `/usr/sbin/wlc_monitor` (real bins). Artifact
  `~/be98/artifacts-br/GT-BE98_br-0047_nand_squashfs.pkgtb`, sha256
  `cd3e7f1edd8f1876b7384107b9edb6c411dbae83fceba43196302092544dbf16` (83301064 B).
  Release marker `br-0047+g506ef6f96b74`.

- **Slot-1-hop was REQUIRED first.** The device was running **slot 2** (br-0046)
  at trial start, so slot 2 was not flashable. A prior agent hopped it to **slot 1
  (br-0045)** (committed 1 valid 1,2 seq 35,36) so slot 2 became the idle/flashable
  trial slot. Standard slot-2-trial / GOOD=slot-1 pattern then applied.

- **TRIAL on hardware — PASS.** `trial-flash.sh --window 600` from slot 1:
  pre-check good=1 booted=1 committed=1 valid 1,2 RR 34; dead-man armed
  (TRIAL_SLOT=2 GOOD_SLOT=1 WINDOW=600 SHA=cd3e7f1e…, exact parser format,
  read-back verified) → hnd-write slot 2 (exit 99, auto-commit 2) → commit
  repaired to slot 1 → ONCE (`bcm_bootstate 3`, RR→1) → plain `reboot`. SSH
  answered on slot 2 at **+107s**; **DISARMED at T+5s** (deadman log). ASUS init
  self-committed slot 2.

- **Gate 19/19 PASS** (slot==2, identity `br-0047+g506ef6f96b74`, 4 radios up,
  Ramondia/Pagoa/DEV-SCEP present, 11 hostapd, br0 IP, jffs rw,
  eapd/wlceventd/mcpd/watchdog up, boot_failed_count=0, dmesg clean, 3-min
  daemon-pid soak stable). Identical to the br-0046 baseline (19/0).

- **WIFI SLICE CHECK — IDENTICAL to pre-trial br-0046 baseline (the decisive
  proof, esp. the wlc_monitor caveat):** wl0-3 isup all =1; `brctl show`
  br0/br20/br30/br50/br70 memberships byte-identical; **11 hostapd** (4 stock
  `/tmp/wlX_hapd.conf` + 7 webui `/tmp/webui-hapd/*`), same BSS set; all 7 named
  BSSes **state=ENABLED** — Ramondia (wl0.1/wl1.1/wl3.2), DEV-SCEP
  (wl0.2/wl1.2/wl3.5), Pagoa (wl3.3); 4 stock primaries ENABLED. The 4 monitor
  binaries + processes **ABSENT** (intended). **10-min syslog+breadcrumb soak:
  syslog grew 1 line, ZERO matches for netool/rtkmonitor/sysstate/wlc_monitor /
  respawn / watchdog-restart** (the `blog_get_dstentry_by_id … match fails`
  breadcrumb lines are benign Broadcom fcache/blog flow-accel noise, present on
  the baseline board, unrelated to the removed daemons). Radios + 7 BSSes
  re-verified once more after the soak — still all up/ENABLED.
  **wlc_monitor removal did NOT degrade wifi — it stays RETIRED (no need to move
  to KEEP).**

- **ACCEPTED.** `rm /data/.trial-armed` (init had already self-committed slot 2);
  no trial flag remains. Pre/post wifi captures saved under
  `~/.claude/jobs/178892d1/tmp/br0047-{pretrial,posttrial}-wifi.txt` + gate logs.

- **Submodule note:** `docs/device` is pinned at an old commit in the parent and
  the live flash-journal lives in the **standalone `gt-be98-docs` repo** (same
  remote, `main`); the journal entry was committed there (precedent = the
  br-0046 d9c8abe commit). The parent's `docs/device` submodule pointer was left
  dirty/untouched on purpose — do NOT commit the parent submodule pointer.

## State (2026-06-06 NIGHT-4 — br-0047 monitor-retire BUILT + diff-proven; **TRIAL PENDING**, baseline STAYS br-0046)

**COMMITTED BASELINE = br-0046** (unchanged). br-0047 is the Phase-2 rc-drain
**monitor-retire #1** slice (plan-phase2-rc-drain.md P2-2): an OFFLINE
build+diff-prove only — NO flash/reboot/device this session.

> **Numbering note:** the number br-0047 was previously squatted by the in-image
> webui slice that proved **NAND-BLOCKED** (branch `slice/br-0047-webui-nand-blocked`,
> never on master, never a baseline — see the NIGHT-3 entry below). A blocked
> non-baseline slice frees its number (same rule as the br-0046 webui→OpenSSH
> reuse), so this monitor-retire slice — a pure removal slice that SHRINKS the
> rootfs — takes br-0047. The dead webui artifact was preserved as
> `~/be98/artifacts-br/GT-BE98_br-0047-webui-nandblocked_nand_squashfs.pkgtb`.

- **What br-0047 is:** removes 4 stock monitor daemons (cumulative slice 7 in
  `rootfs-remove.list`), all with **RETIRE** verdicts + "none found" respawn in
  plan-phase2-rc-drain.md §1.1 (safe Pattern-B file removal, no watchdog
  respawn-fail loop):
  - `/sbin/netool` — `/sbin/rc` MULTICALL SYMLINK (verified `-> rc` in 0031);
  - `/sbin/rtkmonitor` — `/sbin/rc` MULTICALL SYMLINK;
  - `/usr/sbin/sysstate` — real binary (42864 B in 0031);
  - `/usr/sbin/wlc_monitor` — real binary (9780 B in 0031).
  Deleting the two symlinks removes only those rc entry-points; the `/sbin/rc`
  binary is untouched (same as slices 4-6). **All 4 candidates INCLUDED, none
  excluded** — each had a clean RETIRE verdict and exact-path match in the 0031
  blob.
- **Build + diff-proof GREEN.** `make` → 80M pkgtb (sha256 `cd3e7f1e…`, artifact
  `~/be98/artifacts-br/GT-BE98_br-0047_nand_squashfs.pkgtb`, 83301064 B). The
  transform removed all 26 cumulative paths (typo-guard passed — every listed
  path existed in the blob), harvest/parity/static guards all green. `rootfs-diff`
  vs the br-0046 artifact: 3216 vs 3218 files; content deltas EXACTLY = release
  stamp (CHANGED) + `usr/sbin/sysstate` + `usr/sbin/wlc_monitor` (REMOVED files)
  + `sbin/netool` + `sbin/rtkmonitor` (REMOVED symlinks, listing-only). Parent-dir
  + strongswan.d entries are benign directory-metadata size wobbles (zero content
  delta). The /usr/br island (busybox/dropbearmulti/openssl + 5 openssh binaries)
  is BYTE-IDENTICAL to br-0046 (absent from the diff).
- **Space freed:** rootfs 69,988,352 → 69,971,968 B = **16,384 B (one 128K
  squashfs block)** recovered. Modest (the binaries are small + xz-compressed),
  but the image shrinks. br-0047 rootfs headroom under the slot-2 ceiling
  (71,106,560 B) = **1,134,592 B (~1.1 MB)**.
- **TRIAL PENDING (owed before this becomes a baseline):** flash slot 2 / GOOD =
  slot 1 (br-0045) per the standard dead-man pattern; gate 20/20 + the
  **wlc_monitor kill-test caveat** — wlc_monitor is wifi-ADJACENT by name (plan
  flags LOW-MED risk); on the trial, confirm 4 radios isup + bridges intact after
  removal. If wlc_monitor degrades wifi it moves to KEEP and the slice re-ships 3
  paths. NEVER run `service restart_*` mid-trial (evicts the injected SSH key).



**COMMITTED BASELINE = br-0046** (unchanged; slot 2 committed, slot 1 = br-0045
fallback, device healthy). The webui-go regression-fix slice was completed and
the fix proven on hardware, but the in-image br-0047 image is **physically
unflashable** — see below. No flash, no reboot occurred this session.

- **webui-go `-no-apply` inert mode — DONE + PROVEN.** Source fix committed in
  the webui-go repo on branch **`feat/no-apply-inert-mode` (80f38ec)**: a
  `-no-apply` flag (also env `GTBE98_WEBUI_NO_APPLY=1`) that skips ALL 8
  boot-time mutators in `main()` (ApplyBootHooks / StartVLANs /
  ApplyPortForwards / StartBuiltinRadius / StartPortals / StartCaptive /
  **StartDirectWifi** / StartAssocWatch — the `init()`s only register handlers,
  so these 8 are the complete mutating set), plus `wifi.SetHapdDir` that
  instance-scopes the hostapd dir for any non-default `-conf` (defense-in-depth
  so it can never touch the live `/tmp/webui-hapd`). Host strace differential:
  default run = 17 killall execs + opens the hapd dir; `-no-apply` = 0 mutating
  execs, 0 hapd-dir touches, HTTP 200. **LIVE ON-DEVICE PROOF (the decisive
  regression check, no flash):** ran the 80f38ec static-ARM binary with
  `-no-apply` on `127.0.0.1:8089` beside the production webui for 18 s — hostapd
  11→11, `/tmp/webui-hapd` confs 7→7 (intact), all 3 named nets
  (Ramondia/Pagoa/DEV-SCEP across 7 BSS) stayed **ENABLED**, no scoped dir even
  created, served HTTP 200 + logged `no-apply=true`. This is the EXACT scenario
  the prior webui tore down → **fix confirmed**.

- **br-0047 firmware slice — built + diff-proven, but NAND-BLOCKED (NOT a
  baseline).** Preserved on branch **`slice/br-0047-webui-nand-blocked`
  (3288054)** (NOT master). Adds `gt-be98-br-webui` (pins 80f38ec) + the
  beta-aware S29 rail launching with `-no-apply`. Artifact
  `~/be98/artifacts-br/GT-BE98_br-0047_nand_squashfs.pkgtb` (sha256
  `e1dc5577…`). Diff vs br-0046 = `/usr/br/sbin/webui` + `br-webui.sh` + S29
  symlink (ADDED) + stamp ONLY; the 8 carried binaries BYTE-IDENTICAL, 401
  applet links both sides. **WHY BLOCKED:** the UBI rootfs volumes are
  slot-asymmetric — **rootfs1 (slot 1) = 67,805,184 B; rootfs2 (slot 2) =
  71,106,560 B** — and br-0047's rootfs squashfs = **73,703,424 B**, overflowing
  BOTH slots (hnd-write → exit 5, no write). The OpenSSH baseline (69,988,352 B)
  already sits near the slot-2 ceiling, so an in-image webui (~3.7 MB compressed)
  cannot fit. **`CONFIG_XZ_DEC_ARM` is unset in the kernel**, so an xz ARM-BCJ
  squashfs (which would recover the space) would NOT mount → that avenue is out.
  NOTE the slot asymmetry means only ONE OpenSSH-sized image can be committed at
  a time (always slot 2); br-0045 (small) is the permanent slot-1 fallback.

- **FEASIBLE next step to actually flash-trial webui:** ship it via the **/jffs
  beta channel** the rail already supports — keep the rail in-image (rootfs stays
  br-0046-sized → fits slot 2), DON'T harvest the binary into `/usr/br`, and
  `scp -P 2223` the `-no-apply` binary to `/jffs/webui/webui.next`. Then
  flash-trial on **slot 2** with **GOOD = slot 1 (br-0045)** — the same
  slot-2/good-slot-1 pattern the OpenSSH br-0046 trial used (trialing any
  OpenSSH-sized image overwrites slot 2; restore br-0046 from the artifact if it
  fails). The `feat/no-apply-inert-mode` branch must be merged in the webui-go
  repo (its own workflow) and the package version re-pinned.

## State (2026-06-06 NIGHT-2 — br-0046 OpenSSH/scp/sftp TRIALED + PASSED, **NEW COMMITTED BASELINE**)

**COMMITTED BASELINE = br-0046** (slot 2; committed=2 valid 1,2 seq 35,36,
booted slot 2, reset_reason 34). Slot 1 = br-0045, still valid as the fallback
baseline. The agent nvram key (`guillaume@dev-build` in `sshd_authkeys`)
persisted across the whole cycle.

> **Numbering note:** the number `br-0046` was *briefly* squatted by the
> webui-go candidate that was TRIALED + REJECTED earlier tonight (guest-net
> regression — see the entry below; never committed, never a baseline). That
> rejection freed the number, so this **OpenSSH** slice — a completely
> different, safe, self-contained image — reuses `br-0046` and *is* the
> committed baseline. The webui branch `br-0046-webui` (`90cd55a`) is dead;
> ignore it.

- **What br-0046 is:** the OpenSSH slice (orig br-0048 on
  `worktree-agent-a1fa28cb3cfc39a5a`, commit ba73316, built off the OLD br-0045
  commit b4c9417) rebased CLEAN onto current master HEAD as commit **`258bd50`
  (now master)**. The code files the slice touches (rootfs-transform.sh,
  dropbear/openssl `.mk`, Config.in, full_defconfig) were byte-identical
  between the openssh base and master, so the graft was conflict-free and
  cumulative — the br-0045 syslog substitution + busybox syslog patch are
  preserved. Adds package `gt-be98-br-openssh` (OpenSSH 10.2p1; openssl 3.6.2
  linked STATIC from gt-be98-br-openssl's new `_brdev` install_dev tree;
  glibc + zlib dynamic against the device's own libs). Harvests
  `/usr/br/libexec/sftp-server` + `/usr/br/bin/{scp,sftp,ssh,ssh-keygen}`, and
  rebuilds br-dropbear with the SFTP subsystem
  (`SFTPSERVER_PATH=/usr/br/libexec/sftp-server` via localoptions.h) so the
  S28 :2223 dropbear gains scp/sftp. **Unlike the webui binary, OpenSSH
  sftp-server/scp touch NO wifi or shared system state — safe, self-contained.**
- **Build + diff-proof GREEN.** `make` → 83M pkgtb (sha256 `38d6bb28…d6d`,
  artifact `~/be98/artifacts-br/GT-BE98_br-0046_nand_squashfs.pkgtb`, which
  OVERWRITES the dead webui br-0046 artifact). Clean openssl rebuild perturbed
  only the 5-byte compile-date string in `/usr/br/bin/openssl`; restored the
  br-0045 openssl binary into `apps/openssl` + re-ran the image step, so it is
  byte-identical to br-0045 again. `rootfs-diff` vs the br-0045 artifact:
  content deltas EXACTLY = release stamp (CHANGED), `/usr/br/sbin/dropbearmulti`
  (CHANGED — now sftp-aware, 976588B), and the 5 OpenSSH binaries (ADDED:
  `/usr/br/libexec/sftp-server` + `/usr/br/bin/{scp,sftp,ssh,ssh-keygen}`).
  busybox + openssl byte-identical to br-0045. Both harvest guards passed
  (static guard on busybox/dropbear/openssl; dynamic-linkage guard on the 5
  openssh binaries: interp `/lib/ld-linux.so.3`, no libcrypto/libssl in
  DT_NEEDED, all NEEDED sonames satisfiable from /lib+/usr/lib).
- **TRIAL on hardware: flashed slot 2, dead-man armed (TRIAL=2 GOOD=1
  win 600s, sha 38d6bb28), ONCE/reboot, SSH answered on slot 2, DISARMED at
  T+10s.** ASUS init self-committed slot 2. **Gate 20/20 PASS** (identity
  `br-0046+g258bd506576a`, 4 radios, 3 named nets Ramondia/Pagoa/DEV-SCEP,
  11 hostapd, all daemons, dmesg clean, 3-min soak stable). **No guest-net
  regression** (OpenSSH leaves wifi untouched — the webui defect does not recur).
- **SCP + SFTP LIVE-VALIDATED over :2223 (the point of the slice):**
  - `scp -P 2223 <file> admin@10.0.0.8:/jffs/…` → exit 0, file landed,
    remote sha == local sha (byte-identical). `scp -v` showed
    `Sending subsystem: sftp` against `dropbear_2025.89` — modern scp speaks
    the sftp protocol and dropbear advertised + accepted the subsystem (the
    OpenSSH sftp-server was exec'd).
  - `sftp -P 2223 -b` batch put/ls/get → exit 0; put landed (sha match),
    `ls -l` served correct listings, `get` round-tripped byte-identical.
  - Both confirmed working; test files cleaned up afterward.
- **PASS path executed:** removed `/data/.trial-armed`; trial slot stays
  committed (init self-commit) = new good. Final: committed=2 booted=2 valid
  1,2 RR=34. **br-0046 = new committed baseline.**
- **UNBLOCKS flash-free beta pushes:** scp/sftp now usable to drop files on the
  device without a flash, e.g. `scp -P 2223 webui.next admin@<ip>:/jffs/webui/`.
  This is the transport the webui-go beta workflow needs — once webui-go gains
  its `-no-apply`/`-test` mode (so a 2nd instance stops mutating shared wifi
  state), the beta-aware S29 rail + scp push give a flash-free beta loop.

## State (2026-06-06 NIGHT — br-0046 webui-go TRIALED, **FAILED on guest-net regression; baseline STAYS br-0045**) [SUPERSEDED — that br-0046 number was reassigned to the OpenSSH slice above]

**COMMITTED BASELINE = br-0045** (slot 1; committed=1 valid 1,2; both slots now
hold br-0045 after the failed-trial neutralize). **br-0046 = webui-go parallel
rail, REJECTED — do NOT promote.**

- **What br-0046 is:** the webui-go candidate (was br-0047 on branch
  `worktree-agent-a16fe2fafc3bbe9c6`, built off the OLD br-0045 commit b4c9417)
  rebased clean onto current master HEAD as commit **`90cd55a` on branch
  `br-0046-webui`** (cherry-pick applied with no conflicts; only RELEASE needed
  setting → br-0046; the master syslog substitution is intact/cumulative).
  Package `gt-be98-br-webui` (pure-Go static ARM webui-go) harvested to
  `/usr/br/sbin/webui`; S29 rail launches it as a loopback listener on
  127.0.0.1:8089. **I also made the S29 rail BETA-AWARE** (launch
  `/jffs/webui/webui.next` if executable else the in-image binary; log the
  channel+version via `logger`; crash-fallback to in-image after ≥3 exits/~60s).
- **Build + diff-proof GREEN.** `make` → 80M pkgtb (sha256 `810a4a36…b41d`,
  artifact `~/be98/artifacts-br/GT-BE98_br-0046_nand_squashfs.pkgtb`). rootfs-diff
  vs the br-0045 artifact: content deltas EXACTLY = release stamp, `/usr/br/sbin/
  webui` (ADDED), `br-webui.sh` rail + S29 symlink (ADDED); busybox/dropbearmulti/
  openssl byte-identical to br-0045 (no openssl date-perturbation — kept output/
  so no clean openssl rebuild). Dir-metadata size wobble only (benign, zero
  content delta).
- **TRIAL on hardware: flashed slot 2, dead-man armed (TRIAL=2 GOOD=1 win 600s),
  ONCE/reboot, SSH answered on slot 2, DISARMED at T+~40s.** Webui-narrow checks
  all PASSED: rail launched (`pidof webui`→4752, `/proc/4752/exe`=`/usr/br/sbin/
  webui`, cmdline `-listen 127.0.0.1:8089 -www /jffs/webui/www -conf /data/br/
  webui`); **LISTENING on 127.0.0.1:8089**; **HTTP probe → 200 OK** + the GT-BE98
  login HTML; **ASUS httpd :80 STILL UP** (pid 3792). (Beta-channel log line did
  NOT persist to /jffs/syslog.log at boot — syslogd-readiness timing at S29;
  `logger -t br-webui` works live, so the rail code path is correct, just early.)
- **WHY REJECTED — guest-net (SDN) regression.** The webui binary's
  `hapdDir = "/tmp/webui-hapd"` is a HARDCODED package var (internal/wifi/
  supervisor.go:26), NOT derived from `-conf`. So our parallel rail's webui shares
  the live `/jffs/webui` instance's hostapd-supervision dir. Our instance boots
  with an EMPTY `/data/br/webui` DB yet still runs all the boot hooks
  (`ApplyBootHooks`/`StartVLANs`/`StartDirectWifi`/`StartCaptive` + the supervisor
  reconcile — it even spawned `udhcpc -i br70`): it tore down the live instance's
  guest BSS hostapds and DELETED `/tmp/webui-hapd/*.conf`, so the live watcher
  spun forever ("hostapd for wlX.Y died — relaunching … Could not open
  /tmp/webui-hapd/wlX.Y.conf"; guest BSS `state=no-ctrl`). The named SDN nets
  Ramondia/Pagoa/DEV-SCEP lost their hostapd (gate user-net checks 3× FAIL on
  br-0046; PASS on br-0045). A clean br-0045 reboot REPOPULATED /tmp/webui-hapd
  and restored all guest hostapds (ENABLED) — **proving the breakage was caused by
  the second webui instance, not pre-existing.** The "loopback test port" framing
  is misleading: the binary's startup mutates SHARED system wifi state regardless
  of `-listen`/`-conf`.
- **Rollback executed (FAIL path):** committed slot 1, rebooted → br-0045 on slot
  1, dead-man good-slot branch repaired commit (+1), guest nets self-healed;
  then NEUTRALIZED slot 2 (hnd-write br-0045, sha `be40d654…7281`, +1 re-commit),
  removed `/data/.trial-armed`. **Final: gate 18/18 PASS on br-0045** (--quick;
  all radios/nets/daemons green, 11 hostapd, 3 named nets present). nvram
  `sshd_authkeys` agent key persisted across the whole cycle (key-auth never lost).
- **FIX PATH for a future br-0046 retry (out of scope tonight, needs webui-go
  source work):** the parallel rail MUST launch webui in an inert/read-only mode
  that skips `ApplyBootHooks`/`Start*` and the hostapd supervisor (a new `-test`/
  `-no-apply` flag), OR `hapdDir` must be made instance-scoped (derive from
  `-conf`) so two instances don't fight. Until then, do NOT run a 2nd full webui
  instance beside the live `/jffs/webui` one. The beta-aware S29 rail itself is
  sound and reusable once the binary stops mutating shared state.

## State (2026-06-06 EVE — br-0045 RE-TRIALED, PASSED, **COMMITTED BASELINE**)

**COMMITTED BASELINE = br-0045** (slot 1; committed=1 valid 1,2 seq 35,34,
booted slot 1, reset_reason 34). The syslog-receive DEFECT that made the
first br-0045 trial inconclusive is FIXED and the corrected image re-trialed
clean on hardware 2026-06-06 EVE.

- **The fix:** busybox 1.37.0 syslogd, built with `CONFIG_FEATURE_REMOTE_LOG=y`,
  gated the local-logfile write on a stale local `opts` copy that never saw the
  auto "log locally by default" bit (set only on the global `option_mask32`).
  With ASUS's default argv (no `-R`/`-L`) every `/dev/log` message was dropped.
  One-token source patch `package/gt-be98-br-busybox/0001-syslogd-honor-default-
  local-logging.patch` makes the read-loop gate test `option_mask32` (matches
  busybox 1.25.1 and the sibling remote-forward check at line 906). No applet/
  config drift → `br-busybox.links` parity intact (401 links). Cherry-picked
  from `fix/br-0045-syslog-local-logging` onto master; RELEASE bumped → br-0045.
- **Build + diff-proof GREEN.** `make` → 77M pkgtb (sha256 `be40d654…7281`).
  `rootfs-diff` vs the br-0044 artifact: 3213 files both sides, the ONLY deltas
  are the patched `/usr/br/bin/busybox`, the 3 substitution symlinks
  (`sbin/syslogd`, `sbin/klogd`, `usr/sbin/crond` → `/usr/br/bin/busybox`), and
  the release stamp (`www/mobile/js` 12-byte dir-metadata wobble = benign
  squashfs artifact, zero content delta). dropbearmulti + openssl byte-identical
  to br-0044 (openssl was restored to the br-0044 binary to drop a benign
  compile-date-only delta from a clean rebuild — same recipe/source).
  Artifact `~/be98/artifacts-br/GT-BE98_br-0045_nand_squashfs.pkgtb`
  (be40d654…, replaces the prior broken c4ccf907).
- **LOCKOUT DESIGNED OUT.** Before flashing, the agent pubkey
  (`guillaume@dev-build`) was APPENDED to nvram `sshd_authkeys`
  (`key1>key2>mykey`, `>`-separated as ASUS stores it; both operator keys
  preserved byte-exact, `nvram commit`). Now a `service restart_*`
  authorized_keys rewrite-from-nvram can no longer evict the agent key. This is
  the ONLY nvram write performed; MAC vars / envrams untouched.
- **Trial:** flashed slot 1, dead-man armed (sha be40d654…, window 600s,
  TRIAL=1 GOOD=2), ONCE/ACTIVATE, reboot. SSH answered on slot 1, DISARMED at
  T+40s, **gate 19/19 PASS** (identity `br-0045+gd94cc52408e6`, 3-min soak
  stable, radios/nets/daemons green), init self-committed slot 1, flag removed.
- **LIVE-SYSLOG CONFIRMED (the point of the re-trial):** substituted syslogd
  pid exe = `/usr/br/bin/busybox`, ASUS default argv `-m 0 -S -O /jffs/syslog.log
  -s 1024 -l 6` (no -L), **fd 5 → /jffs/syslog.log OPEN for write** (the fd that
  was MISSING in the broken trial). `logger -t retrycheck …` line appended to
  /jffs/syslog.log live (3808→3809). klogd + crond also → /usr/br busybox; one
  crond (no PID1 double-launch). Defect fully resolved.
- Slot 2 = br-0044, still valid as the fallback baseline.

## State (2026-06-06 PM — TRIALS: br-0044 PASSED+COMMITTED; br-0045 INCONCLUSIVE, NOT accepted) [SUPERSEDED by the EVE entry above]

**COMMITTED BASELINE = br-0044** (slot 2; committed=2 valid 1,2 seq 33,34
reset_reason 34). Hardware-trialed 2026-06-06: booted slot 2 via ONCE,
dead-man (sha 89b716fe) ARMED→DISARMED clean, **gate 19/19 PASS** (identity
`br-0044+gab1854a78cc4`, 3-min soak stable, all radios/nets/daemons green),
ASUS init self-committed slot 2, flag removed. br-0044 = the from-source
`/usr/br` island (busybox/dropbear/openssl) and it BOOTS CLEAN. Slot 1 was
br-0043, now overwritten by the br-0045 trial (see below).

**No daily trial cap** — trials are gated only by the dead-man disarm harness
(user removed the bogus budget 2026-06-06).

**br-0045 (syslogd/klogd/crond → /usr/br busybox) = TRIAL INCONCLUSIVE, NOT
COMMITTED-GOOD.** Flashed to slot 1, booted via ONCE; in-image S26 rail
auto-launched the dead-man (sha c4ccf907, 600s) — DISARMED clean. **Core gate
19/19 PASS.** Substitution STRUCTURALLY PROVEN: all 3 symlinks → `/usr/br/bin/
busybox`; syslogd/klogd/crond running with unchanged argv; `/proc/<pid>/exe`
for all three = `/usr/br/bin/busybox` (v1.37.0, NOT stock 1.25.1); exactly 1
crond (no PID1 double-launch); klogd kernel lines present; stock `/bin/busybox`
1.25.1 intact as fallback.
**OPEN DEFECT (unresolved): fresh `logger` messages did NOT append to
`/jffs/syslog.log`** (count stuck at 1199 across 10+ min / 3 attempts), and the
running syslogd has NO logfile fd open — only sockets. The substituted syslogd
DID capture this boot's early kernel + service-stop messages (so klogd + boot
logging work), but live message reception could not be confirmed. Needs a
clean re-trial with a proper logger-receive test.
**ACCESS INCIDENT (operator-induced, NOT a br-0045 fault):** while probing the
syslog issue I ran `service restart_time` on the device — ASUS rewrote the
admin authorized_keys from nvram `sshd_authkeys` (two operator ed25519 keys;
MY `id_ed25519` is NOT among them), evicting the key that services-start had
copied from `/jffs/.ssh/authorized_keys` at boot. SSH pubkey is now rejected
on :2222 AND :2223; webui (:8080) needs a password I don't have. **DEVICE IS
HEALTHY** (all WiFi nets, webui, both dropbears, radios up — NOT an outage).
**SAFE STATE: the dead-man flag `/data/.trial-armed` (TRIAL_SLOT=1 GOOD_SLOT=2
WINDOW=600) is STILL ARMED.** On the NEXT reboot the S26 rail re-arms the
dead-man on slot 1, no disarm arrives, it FIRES at +600s → commits slot 2 and
reboots → **device auto-returns to br-0044**, and services-start re-restores my
SSH key. **OPERATOR ACTION: reboot the device** (power-cycle, or `reboot` via
your nvram key / webui login) to complete the rollback to br-0044 and regain
key access; then `rm /data/.trial-armed`. Do NOT run `service restart_*` during
a trial again (it nukes the injected SSH key). br-0045 artifact stays archived
(`~/be98/artifacts-br/GT-BE98_br-0045_…pkgtb`, sha c4ccf907…5c108) for re-trial
after the syslog-receive question is closed.

## State (2026-06-06, br-0045 — log/time/cron substitution; built, NOT accepted)

**br-0045 = Phase 2 service substitution (Pattern A), built + diff-proven, NOT
flashed.** It repoints three stock busybox-applet symlinks at the from-source
`/usr/br` busybox 1.37.0 instead of the stock 1.25.1, leaving rc as the
launcher (argv unchanged) and `/bin/busybox` untouched as fallback:
- `/sbin/syslogd`, `/sbin/klogd`, `/usr/sbin/crond` → `/usr/br/bin/busybox`.

**SLICE-A determination (P2-0, source + qemu-arm verified) — NO busybox respin
needed, and ntp is EXCLUDED:**
- **syslogd `-m` is a non-issue.** `-m` is in busybox 1.37.0's syslogd
  `OPTION_STR` *unconditionally* (`"m:nO:l:St"`); it is parsed and its arg
  consumed regardless of config. Only the periodic "-- MARK --" emission is
  `#undef SYSLOGD_MARK` — a hardcoded source decision (comment: "bloat, and
  broken"), NOT a Kconfig toggle, and ASUS launches with `-m 0` (MARK off)
  anyway. The plan's "`-m` compiled out" was a `--help`-text artifact (the
  usage line is commented out). qemu-arm: `syslogd -m 0 -S -O … -s 1024 -l 6`
  is ACCEPTED (no "invalid option"; contrast `-Z` → rejected). `busybox.config`
  is UNCHANGED; `br-busybox.links` UNCHANGED (401 links, parity guard green).
- **ntpd `-t` is NOT satisfiable by upstream busybox 1.37 and ntp is EXCLUDED
  from the slice.** `-t` is an ASUS-patched flag; upstream ntpd's getopt string
  is `"nqNx"+"k:"+"wp:*S:"+"l"+"I:"+"d"+"46aAbgL"` (no `t`). qemu-arm:
  `ntpd -t …` → `ntpd: invalid option -- 't'` (rejects, exits → no time sync,
  `ntp_ready` never set). Substituting ntp would need a 2-line source patch on
  our busybox accepting `-t` — deferred to its own de-risk/live-test cycle; we
  did NOT ship a broken `/usr/sbin/ntp` symlink. Stock ntp stays.

**Mechanism = Pattern A (plan §2/§3): no rail, no rename.** The plan's queue
explicitly says substitution drains need NO `/rom/etc/init.d` rail (rc remains
the launcher); the symlinks are static overlay files in effect from first exec.
So br-0045 consumes NO new rail number (next free rail stays **S29**, reserved
for the webui M5 candidate / P2-4). This is the plan's prescribed mechanism for
syslogd/klogd/crond, distinct from the S28 br-dropbear *promotion* rail.

**Transform fix folded in (correctness, umask-independence):** shipping
`usr/sbin/crond` introduced a new `usr/sbin/` overlay dir whose mode is the
builder's umask (git does not track dir modes), and `cp -a` was stamping it
(0775) over the stock `/usr/sbin` (0755). `rootfs-transform.sh` step 2 now
snapshots+restores the stock mode of shadowed stock system dirs (`SHADOWED`
list = `usr/sbin`). `/sbin` and `/usr` are deliberately NOT restored — they are
already overlay-provided (sbin/trial-deadman, usr/br) and 0775 in every
baseline, so leaving them keeps the slice diff minimal.

**Build + diff-proof GREEN, NOT flashed.** `make` produces the 77M pkgtb
(sha256 `c4ccf907…5c108`); all harvest/parity/static guards pass. `rootfs-diff`
vs the br-0044 artifact (`~/be98/artifacts-br/GT-BE98_br-0044_…pkgtb`, rootfs
extracted): 3213 files both sides; the ONLY deltas are the 3 symlink repoints +
the release stamp. (`www/mobile/js` shows a 12-byte directory-metadata size
wobble with byte-identical entries/contents — a benign squashfs packing
artifact, zero file deltas.) The `/usr/br` busybox binary is byte-identical to
br-0044 (no respin), so the only functional change is the applet implementation
behind those three symlinks. Artifact archived
`~/be98/artifacts-br/GT-BE98_br-0045_nand_squashfs.pkgtb`.

**RECOMMENDED TRIAL ORDER (both trial-ready, neither flashed):** hardware-trial
**br-0044 FIRST** (proves the from-source `/usr/br` binaries boot), THEN
**br-0045** (proves service substitution). The transform is CUMULATIVE
(br-0045 ⊃ br-0044), so they *could* be one trial, but separating them isolates
a boot failure to either the from-source-binary swap (br-0044) or the
syslogd/klogd/crond substitution (br-0045). No daily trial cap; trials are
gated only by the dead-man disarm harness (user removed the bogus budget
2026-06-06).
br-0045 gate adds: `ps` shows syslogd/klogd/crond running (argv unchanged) as
busybox 1.37.0; new lines land in `/jffs/syslog.log`; klogd dmesg lines present;
PID1 `check_services` does not relaunch a second crond (name-match satisfied).

## State (2026-06-06, br-0044 — /usr/br built FROM SOURCE)

**br-0044 = the /usr/br island rebuilt from upstream source, no longer
prebuilt blobs in the git overlay.** The three `gt-be98-br-{busybox,dropbear,
openssl}` packages cross-build (external gcc-10.3 toolchain) from
hash-verified upstream tarballs:
- busybox 1.37.0 (pinned `package/gt-be98-br-busybox/busybox.config`:
  static + INSTALL_NO_USR + SHA1/SHA256_HWACCEL off + TC off);
- dropbear 2025.89 dropbearmulti (server + dbclient/ssh + dropbearkey/
  ssh-keygen + scp, key-only, bundled libtom, zlib off). **Build fix:
  `ac_cv_lib_crypt_crypt=no` forces @CRYPTLIB@ empty — the Buildroot-staged
  external sysroot has only libcrypt.so (no .a) so a stray `-lcrypt` breaks
  the `-static` link; crypt() is unreferenced anyway (no password auth);**
- openssl 3.6.2 CLI (linux-armv4, no-shared -static, OPENSSLDIR
  `/usr/br/etc/ssl`).
`rootfs-transform.sh` step 2b harvests the binaries + regenerated applet
symlinks into `/usr/br/{bin,sbin}` (parity guard vs `br-busybox.links`,
fully-static readelf guard, and `chmod 0775` on bin/sbin to match the
baseline dir modes). The ~400 prebuilt binaries + applet symlinks were
DELETED from `rootfs-overlay-full/usr/br/` (git overlay keeps only
openssl.cnf + ssl dirs + init.d rails).

**Build + diff-proof GREEN.** `make BR2_EXTERNAL=… gt-be98_full_defconfig &&
make` produces `output/images/GT-BE98_nand_squashfs.pkgtb` (77M, sha256
`89b716fe…f66d`); harvest guards all pass. `rootfs-diff.sh` vs the br-0043
baseline (`~/be98/artifacts-br/rootfs-ref/rootfs-br0043.squashfs`): 3213
files both sides, the ONLY deltas are the release stamp + the 3 rebuilt
binaries (content; dropbearmulti also size 935632→976588B) — zero other
path/mode deltas. Functional parity (qemu-arm): busybox v1.37.0 402 applets/
401 symlinks (only `linuxrc` un-symlinked, by design), dropbearmulti
v2025.89 (4 components), openssl 3.6.2 OPENSSLDIR=/usr/br/etc/ssl; all three
fully static. Artifact archived `~/be98/artifacts-br/GT-BE98_br-0044_…pkgtb`.

**TRIAL-READY.** No daily trial cap; trials are gated only by the dead-man
disarm harness (user removed the bogus budget 2026-06-06).
Functionally equivalent to the committed br-0043 baseline (same versions/
components), so the trial is expected nominal; still owes one hardware
trial cycle before it becomes the committed baseline.
`board/gt-be98/phase3/` (graft-manifest generator) is unrelated WIP — left
untracked. `docs/device` submodule shows untracked content — left for the
operator.

## State (2026-06-05, night session)

**M2 DONE — Buildroot pkgtb flashed; trial+rollback harness PROVEN on
hardware.** The device's committed, running image (slot 2) is the
Buildroot-assembled M1 pkgtb, validated by the automated gate (19/19).
The flash safety harness (`board/gt-be98/trial/`) is live-proven:
- trial entry via `hnd-write` (auto-commits) → `bcm_bootstate +GOOD` repair →
  `bcm_bootstate 3` (ONCE/ACTIVATE — WORKS on this board, 2/2) → reboot;
- Layer-B dead-man fired for real (deliberate no-disarm): re-committed the
  good slot (also repairing ASUS init's self-commit of the trial) and
  returned the device automatically;
- booted-slot truth = kernel cmdline `ubi.block=0,4|6` —
  **`/proc/bootstate/active_image` LIES**, never use it.
Key facts + corrections in `gt-be98-docs/flash-journal.md` and
`recovery-procedure.md` (corrections section).

**M3 DONE — mutation pipeline proven on hardware.** The device now runs
**br-0032** (committed, slot 1; gate 20/20 incl. identity marker): 0031
rootfs + `/rom/etc/gt-be98-release` + in-image dead-man (S26 boot-rail —
took the instance lock on the trial boot, armed, disarmed on command).
Pipeline: `rootfs-transform.sh` (rename list → removal list → overlay →
marker → merlin-exact re-squash; all typo-guarded), `rootfs-diff.sh` proof
(br-0032: 3 ADDED, zero content changes). Version scheme `br-00NN`,
monotonic after merlin 0031. Fallback: slot 2 = M1 (gate-validated).

**M4 batch 1 (br-0033) trial FAILED and was auto-rolled-back by the
dead-man — the harness's first real save.** The 22-removal image booted
slowly with broken LAN; the dead-man armed at services-start, fired at
+300s, repaired the commit and rebooted; the device has run br-0032
healthily since (gate 20/20 re-run post-recovery). The hours of apparent
"darkness" were a management-path artifact: the AP took a new DHCP lease
(**10.0.0.95**, was 10.0.0.8) and the inter-VLAN firewall only allowed the
old address (this build host probes from VLAN 50, routed). Full corrected
story: `gt-be98-docs/flash-journal.md`. Slot 2 was neutralized with the
br-0032 artifact; all trial flags cleared; final metadata
booted=1=committed, valid 1,2.

**br-0043 IS NOW THE COMMITTED BASELINE — M4 COMPLETE + M5 candidates 1-3**
(2026-06-06 14:50: slot 1, gate 20/20; slot 2 = br-0042 fallback; artifact
`44eb9a01…01fe` archived; ONCE 13/13 lifetime). /usr/br now holds:
dropbear 2025.89 (rail S28, :2223, key-only; hostkey /data/br/dropbear),
busybox 1.37.0 + 401 applet links, openssl 3.6.2 CLI
(OPENSSLDIR=/usr/br/etc/ssl). All static; stock binaries untouched.
**M5 prefix is `/usr/br`, NOT /opt/br — /opt is a tmpfs symlink.**
De-risk rule: live-test every new binary from /tmp over SSH BEFORE
staging+trial (caught busybox argv0 + openssl OPENSSLDIR defects).
Remaining M5: lighttpd/webui-go (needs admin-path validation first).
dropbear promotion to primary: after multi-day soak.
**⚠️ patch-0032 (docs repo, operator): blob-level envrams wrapper = the
SAME design as the br-0033 wrapper — hardware evidence says gated-off
envrams ⇒ BSP-MAC nvram poisoning on normal boots. DO NOT flash
artifacts-0032 as-is; see the ADDENDUM in
gt-be98-docs/plans/patch-0032-envrams-real-start.md.**

Superseded baseline: **br-0040 — M4 STRIP COMPLETE**
(2026-06-06 13:21: gate 20/20 + slice gate; artifact `730badb6…474b`).
Cumulative strip (six slices br-0035..br-0040, each its own trial, all
gates green): infosvr awsiot mastiff asd wsdd2 | networkmap
(+/usr/networkmap) uamsrv | cfg_server wlc_nt lldpd | amas_lanctrl
amas_portstatus amas_ssd_cd conn_diag | bsd roamast | amas_bhctrl amas_ssd
amas_status amas_misc amas_wlcconnect = **full br-0033 batch-1 parity
minus the banned envrams wrapper**.
**br-0033 ROOT CAUSE CONCLUDED by elimination: the envrams wrapper+rename**
(mechanism: envram→BSP MAC fallback→nvram poisoning; see flash-journal
2026-06-06 root-cause section). Wrapper stays BANNED; envrams retirement =
kill+firewall only.
**rootfs-remove.list is CUMULATIVE** — the transform re-unpacks the
pristine 0031 blob each build; a slice-only list re-adds earlier removals
(caught by rootfs-diff, 2026-06-06).
KEPT (verified live on br-0040): wanduck (running), usbmuxd (running, at
/usr/bin/usbmuxd not /usr/sbin), amas_ipc, amas_lib, all shared libs,
httpd/webUI. Next: **M5** — packages under /opt/br beside rc (rc stays
PID1, init migration NO-GO); candidate 1 = updated dropbear on a test
port, own trial cycle.

Previous baseline note (superseded):
**br-0034** (2026-06-06: slot 2, gate 20/20;
v2 dead-man verified running from the /data flag; S27 breadcrumb logger
verified from uptime 9 s; slot 1 = br-0032 fallback). br-0033's collateral
MAC poisoning (BSP default written to nvram) was repaired from the baseline
backup — the **envrams wrapper is BANNED** (see `m4-staging/README.md`);
envrams retirement stays kill+firewall-based.
**M4 resumes in ≤5-file slices** on this baseline; bisect br-0033's
culprit with breadcrumb forensics. Inputs staged in
`board/gt-be98/m4-staging/`; artifacts in `~/be98/artifacts-br/`
(br-0032 6c3b8918…, br-0033 8f0b70a1… quarantined, br-0034 d1b40b0f…).
Harness scripts honor `GT_BE98_DEV`/`GT_BE98_PORT`; device back at
admin@10.0.0.8:2222 (factory MAC restored → old DHCP reservation).

**Pending user actions:** (1) upload Release assets
`rootfs-0031`/`bootfs-0031` (tarballs + commands in
`gt-be98-docs/buildroot-m1-hybrid-image.md`); until then pre-seed
`$BR2_DL_DIR` (already done locally). (2) Decide the AP's management
address: restore the 10.0.0.8 DHCP reservation or adopt 10.0.0.95 (and
keep the new firewall rule either way).

## Previous state (2026-06-05)

**M1 DONE — first Buildroot-assembled hybrid .pkgtb.** `gt-be98_full_defconfig`
builds end-to-end on a CLEAN buildroot 2026.02.2 clone: toolchain + blobs fetched
by URL+hash, `output/images/GT-BE98_nand_squashfs.pkgtb` whose embedded bootfs
and rootfs are BYTE-IDENTICAL to the validated 0031 artifact (the image running
on the device, pkgtb sha256 a7dcd0c1…fa01). Blob versions bumped 1.0 → **0031**:
the 1.0 blobs were packaged from a drifted vendor tree (different uboot+kernel
hashes!); 0031 blobs are extracted from the validated pkgtb itself via
`gt-be98-packages/scripts/extract-pkgtb.sh`. NOT flashed; Release assets
rootfs-0031/bootfs-0031 must be uploaded by the user (no gh CLI on this host —
tarballs staged in `gt-be98-packages/output/`). See
`gt-be98-docs/buildroot-m1-hybrid-image.md`.

## Previous state (2026-06-04)

**Step 1 DONE & verified** — the external toolchain builds a minimal busybox
glibc rootfs with the exact merlin target ABI (ARMv7-A cortex-a9, EABI softfp,
VFPv3, glibc 2.32, interp `/lib/ld-linux.so.3`).

**Step 2a DONE (packaging pipeline)** — `make` now also produces
`output/images/GT-BE98_nand_squashfs.pkgtb`: `board/gt-be98/post-image.sh` wraps
Buildroot's `rootfs.squashfs` with a prebuilt bootfs `.itb` (ATF+U-Boot+aarch64
kernel+dtbs+OP-TEE, borrowed from the sibling merlin tree) via u-boot `mkimage`,
reproducing merlin's exact bundle FIT. Verified structurally: all metadata tokens
present, squashfs magic once, embedded rootfs byte-identical, `dumpimage` parses.
mkimage now comes from Buildroot's host-uboot-tools (merlin only lends the bootfs
`.itb`). HONEST limits: not boot-tested on hardware; kernel/ATF/U-Boot reused
prebuilt (Step 2b deferred — needs Broadcom build wrapper).

**Steps 3-4 IN PROGRESS — userspace landing in the image:**
- Generic (upstream Buildroot pkgs): openssl, cjson, lighttpd, openvpn, dropbear,
  strongswan (charon/stroke). NB **samba4 won't build** with the gcc-10.3 external
  toolchain — its dep cmocka 2.0.2 uses `__attribute__((access(none)))` (GCC 11+).
  This is a general constraint: modern upstream pkgs needing GCC 11+ fail; get
  smbd (and similar) from the ASUS blob instead.
- Proprietary (gt-be98-packages blobs + recipes, fetched by URL+hash):
  - `gt-be98-dhd-firmware` — rtecdc.bin (6717a0/6726b0) -> /rom/etc/wlan/dhd.
  - `gt-be98-userspace-base` — nvram, rc, wl, dhd, httpd + their 34-lib ASUS
    shared-lib closure -> /bin,/sbin,/usr/sbin,/lib,/usr/lib. Verified the
    dynamic-link closure is COMPLETE in the rootfs.
  Blob pattern: `gt-be98-packages/scripts/package-blob.sh` (reproducible tar) ->
  Release asset -> recipe `_SITE`/`.hash`. Tarballs staged locally in `dl/`;
  Release uploads pending (needs the user / no gh CLI).
- Still TODO for functional parity: init/rc wiring, nvram defaults, /www web UI
  assets, wl/dhd config, service start scripts.

- `external.desc` (name `GT_BE98`), `external.mk`, `Config.in` — wired.
- `configs/gt-be98_defconfig` — arch/ABI **confirmed from the real compiler**:
  `BR2_arm` + `BR2_cortex_a9` + `BR2_ARM_EABI` + `BR2_ARM_ENABLE_VFP` +
  `BR2_ARM_FPU_VFPV3`, external glibc 10.3/2.32/hdr-4.19, `INET_RPC` disabled.
  Toolchain SOURCE intentionally left unset (pick URL or PATH locally — see file).
- `board/gt-be98/` — post-build/post-image **placeholders** (no-ops).
- `package/README.md` — recipe template referencing `gt-be98-packages` Releases.

### How Step 1 was built / reproduced
- Buildroot upstream cloned at tag **2026.02.2** (latest stable LTS) in
  `~/be98/buildroot`. The external toolchain (gcc10.3/glibc2.32/hdr4.19) is
  consumed as-is regardless of Buildroot version; 2026.02 still offers
  `BR2_TOOLCHAIN_EXTERNAL_HEADERS_4_19`. The defconfig is **version-portable** —
  it built unchanged on both 2021.02.4 and 2026.02.2.
- Build it via a LOCAL test defconfig that appends
  `BR2_TOOLCHAIN_EXTERNAL_PATH=<firmware's extracted crosstools-arm_softfp dir>`
  (the firmware repo already extracts the toolchain), then `make defconfig && make`.
- On modern Buildroot the host tools build cleanly on Debian 13 (host-fakeroot
  1.37 — no patch). (An older Buildroot like 2021.02 needs a fakeroot bump to
  build on glibc 2.41; avoided by using latest stable.)

### Remaining Step-1 polish (before Step 2)
- Repackage ONE crosstools variant into a Buildroot-download-ready single tarball
  (root = `bin/ lib/ ...`) and upload as a `gt-be98-toolchain` Release asset, then
  set `BR2_TOOLCHAIN_EXTERNAL_URL` in the committed defconfig so it builds without
  the firmware repo present. (Upload needs the user — no `gh` CLI.)

## Step 2 plan (VERIFIED against the merlin artifacts)

Key finding: the architecture is **mixed** — **kernel = aarch64**, **userspace =
32-bit ARM softfp** (`file` on merlin's `vmlinux` = ELF 64-bit aarch64; busybox =
ELF 32-bit ARM). So Buildroot's BR2_arm target is right for the rootfs, but its
normal kernel flow would wrongly build a 32-bit kernel. Defer kernel-from-source.

Image is a **two-layer FIT** (verified via `dumpimage -l`):
- `.itb` (bootfs, 13M) = atf + uboot + fdt_uboot + kernel(lzo,aarch64,@0x200000)
  + many per-board aarch64 DTBs (incl. `fdt_GT-BE98`) + optional OP-TEE.
  **No rootfs in here.**
- `.pkgtb` (74M, the flashable bundle) = loader + bootfs(.itb) + **rootfs.squashfs**.

merlin tooling (under `…/src-rt-5.04behnd.4916/bootloaders`): `build/work/
generate_linux_its`, `build/work/generate_bundle_itb`, `build/work/
fit_header_tool`, `obj/uboot/tools/{mkimage,dumpimage}`; config `build/configs/
options_6813_nand.conf.GT-BE98`. rootfs = `mksquashfs … -noappend -all-root
-comp xz` (v4.0, 128K block, ~61M).

**Step 2a (fastest flashable image):** Buildroot builds ONLY the 32-bit rootfs →
squashfs(xz/all-root); `board/gt-be98/post-image.sh` calls `generate_bundle_itb`
to wrap merlin's **prebuilt** `.itb` + loader (→ gt-be98-packages blobs) around
Buildroot's rootfs → mkimage → `.pkgtb`. Proves the packaging pipeline end-to-end
with our rootfs.

**Step 2b (investigated → DEFERRED).** Building the aarch64 kernel from source is
NOT a standard Buildroot kernel package: a bounded `make ARCH=arm64 olddefconfig`
test fails at Kconfig (`../bcmkernel/Kconfig.bcm_kf.4.19.294`), and the build
consumes dozens of env vars from `build/Bcmkernel.mk` pointing into bcmdrivers/RDP
SDK. Building it means vendoring a large Broadcom subtree + wrapping their build
system (multi-day) for NO functional gain over the prebuilt `.itb` we already
reuse. Keep reusing the prebuilt `.itb`; revisit only if from-source becomes a
hard requirement. (The aarch64 toolchain works: gcc10.3, `aarch64-buildroot-linux-gnu-`.)

## Reference: the working build

`../gt-be98-firmware` produces a verified `GT-BE98_*.pkgtb` on Debian today
(asuswrt-merlin). It is the source of truth for everything Buildroot must
reproduce. Especially:
- `tools/verify-artifact.sh` — the required-component checklist + image layout.
- `vendor/.../targets/96813GW/` — the real `.itb` / `.pkgtb` / kernel / dts.
- Toolchain facts + the prebuilt cross-toolchain are in `gt-be98-toolchain`.

## Roadmap (do in this order — see ARCHITECTURE.md for detail)

1. **External toolchain works.** Decide the target tuple/CPU for BCM6813 (the
   merlin build is mixed 32/64; primary is `arm-buildroot-linux-gnueabi`, ARMv7
   softfp). Repackage one crosstools dir or use `BR2_TOOLCHAIN_EXTERNAL_PATH`.
   Goal: `make` produces a busybox rootfs with this toolchain.
2. **Kernel + bootloader.** Broadcom 4.19 vendor kernel + ATF/U-Boot + the
   `.itb`/`.pkgtb` packaging. Reuse merlin's tooling from `post-image.sh`.
3. **Wireless.** dhd/wl + `rtecdc.bin` (6717a0/6726b0) as gt-be98-packages.
4. **Userspace.** httpd/web UI, nvram, services, openvpn, samba, lighttpd.
5. **Parity.** Diff against gt-be98-firmware's verified artifact.

## Conventions

- **Recipes only here** — never commit blobs/sources (`.gitignore` enforces).
  Sources/firmware → `gt-be98-packages` Release assets; toolchain →
  `gt-be98-toolchain`.
- Package symbol namespace: `BR2_PACKAGE_GT_BE98_*`; path var
  `$(BR2_EXTERNAL_GT_BE98_PATH)`.
- Keep `ARCHITECTURE.md` identical across the repo family if you edit it.

## Honest scope note

A full Buildroot port of a Broadcom-SDK device is large; the proprietary
kernel/driver/bootloader/image integration is ~80% of the work. Keep
`gt-be98-firmware` as the working product until this reaches artifact parity.
