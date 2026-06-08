---
name: openrc-handoff
description: HANDOFF — continue to a FULLY WORKING OpenRC open-init on GT-BE98. Entry point: state, resources, method, next moves, safety.
metadata:
  type: project
---

# OPENRC OPEN-INIT — HANDOFF / CONTINUATION (2026-06-08)
You (new orchestrator) are continuing one job: get a **fully working OpenRC open-init** on the
GT-BE98 — OpenRC as PID1 replacing the closed ASUS `rc`, **reachable + usable + committed** as a
baseline. Read this + [[phase3-openrc-init-feasible]] (the detailed v1→v13 log) FIRST.

## GOAL / DEFINITION OF DONE
A flashed slot boots OpenRC as PID1, is **reachable from the LAN** (SSH :2222 + webui), runs the
services, brings up wifi, and is **committed** (survives reboot, no auto-revert). The open-OS =
open init (this) + open wifi userspace (validated) + from-source userspace (byte-identical) +
pinned Broadcom graft (wl/dhd, eapd/wlceventd/mcpd, nvram, HW-ctl).

## STATE — what's PROVEN vs the BLOCKER
PROVEN (13 trials, no Broadcom wall — every blocker a mundane Linux-on-minimal-rootfs detail):
OpenRC 0.56 PID1 BOOTS on the closed bcm stack, runs sysinit→boot→default, runs the graft
early-init (bcm_boot_launcher → drivers/accelerators), runs services, and has **OUTBOUND network**
(the open-init's on-device self-test: `ping gateway 10.0.0.1` PASS). ★The F gate — does the closed
bcm stack tolerate a non-`rc` PID1 — is PASSED.★
★THE BLOCKER = INBOUND reachability.★ The open-init talks OUT but nothing external reaches it. All
the orchestrator's earlier ":80=200 reachable" catches were actually **br-0045 (slot1) after the
open-init reverted** — the open-init (slot2) was NEVER caught from outside. The Broadcom
flow-accelerator/runner forwards CPU→net but apparently not net→CPU. SSH :2222 authkeys now
byte-match br-0045 (NOT the issue) — inbound is. Debugging is BLIND (can't interact; only the
on-device self-test → /data, read after the auto-revert). ★ALWAYS confirm the SLOT (`/proc/cmdline`
ubi.block=0,6 = slot2 = open-init) before claiming the open-init is reachable — a port answering
on 10.0.0.8 is usually br-0045/slot1.★

## RESOURCES (all pushed / on disk)
- Open-init SOURCE: gt-be98-buildroot branch **`openrc-init-explore`** (origin, HEAD 06977fd).
  Worktree: `gt-be98-buildroot/.claude/worktrees/openrc-init`. Key files under
  `board/gt-be98/phase3/openrc/`: `init.d/{deadman-early,etc-farm,bcm-knvram,bcm-platform,hw-wdt
  (removed v7),net-lan,wifi-radio,webui}`, `init-wrapper.sh` (PID1 wrapper: mounts /data, arms
  wdtctl, execs openrc-init.real), `openrc-assemble.sh` (builds the image on the br-0050 base),
  `README.md` (the full v1→v13 journey).
- LATEST image: `~/be98/artifacts-br/GT-BE98_openrc-init-v13_nand_squashfs.pkgtb` (sha eae507ff,
  rootfs fits slot-2 ceiling 71,106,560). All v4–v13 pkgtbs in `~/be98/artifacts-br/`.
- BASELINE (restore the device here): `GT-BE98_blob0035_nand_squashfs.pkgtb` (sha 9a723b5a =
  br-0050, origin/blob-0035) → slot2. slot1 seq-bump image: `GT-BE98_br-0045_nand_squashfs.pkgtb`.
- TRIAL HARNESS: `gt-be98-buildroot/board/gt-be98/trial/trial-flash.sh --reboot --window 600 <pkgtb>`
  + `gate-check.sh` + `trial-deadman`. OpenRC build: Buildroot `package/openrc` in
  `~/be98/buildroot/output-openrc-init`; squashfs tools at `~/be98/buildroot/output-full/host/bin`.
- DEVICE: 10.0.0.8, SSH admin@ on :2222 (main) + :2223 (rescue dropbearmulti). Slot truth =
  /proc/cmdline (ubi.block=0,4=slot1, 0,6=slot2). bcm_bootstate: committed/valid/seq.

## METHOD (this is what works — keep it)
- OFFLINE-FIRST: builds/diagnoses → SUBAGENTS (no boot-wait → no yield). DEVICE flash-trials →
  the ORCHESTRATOR drives them itself via background Bash polls (subagents YIELD on boot-waits +
  fragment/tangle — proven repeatedly). One device mutator at a time.
- TRIAL FLOW: device on slot1 (br-0045, committed1, rr=34) → `trial-flash.sh <openrc pkgtb>` →
  flashes slot2 + arms dead-man + ONCE-boots slot2 → run a CATCHER (background, polls every ~4-5s)
  that, the instant slot2 answers (confirm ubi.block=0,6!), runs `wdtctl stop` + `touch
  /tmp/deadman-disarm` + validates. Open-init fits SLOT2 ONLY (≈70MB > slot1's 67.8MB ceiling); br-0050
  also fits slot2 only — so GOOD=slot1=br-0045 (the only image fitting slot1).
- ★NON-PETTING WATCHDOG (v7+): the PID1 wrapper arms `wdtctl -t 240` (NO -d) → ANY hang auto-resets
  → slot1 in ≤240s → CANNOT hard-hang. (v6 used the PETTING hw-wdt daemon → hard-hung the device →
  needed a power-cycle. NEVER ship a petting watchdog on a trial.) Disarm on a healthy boot = `wdtctl stop`.
- SELF-DIAGNOSTICS (HOW to debug blind): the net-lan service dumps to PERSISTENT /data:
  net-diag.log (ip/brctl/ethswctl/fcctl/runner state + netstat + ping-gateway/loopback self-test +
  authkeys byte-match), dropbear-auth.log (a `dropbear -E -F` debug instance on :2229 — `-E` is the
  ONLY flag that logs the auth verdict; `-v` is INVALID on dropbear v2025.88 and prints usage),
  openrc-boot.log (wrapper + per-service breadcrumbs), openrc-dmesg-early.log. Read these on slot1
  AFTER the revert. ★After every trial: `rm /data/.trial-armed /data/*-diag.log /data/openrc-*.log
  /data/dropbear-auth.log`, check `df /data` (a fopen-loop once filled it 100%), confirm rr.★
- reset_reason: trial-flash needs rr=34. A power-cycle leaves rr=ffffffff; a warm `reboot` of br-0045
  settles it to 34. Writing /proc/bootstate/reset_reason directly did NOT take — warm-reboot instead.

## NEXT MOVES (priority order)
1. ★v14 — INBOUND via flow-accel DISABLED★ (likely fastest path to reachable): build a v14 where
   net-lan does `fc disable` + runner off (instead of `fc enable`/`rtpolicy auto ALL`) so the CPU
   falls back to a PLAIN LINUX SOFTWARE BRIDGE (kernel br0 delivers inbound to the CPU natively —
   slower, no HW offload, but REACHABLE). Trial → catcher confirms slot2 :2222/:80 reachable → SSH in
   (authkeys match) → validate → `wdtctl stop` + `bcm_bootstate +2` (commit slot2) + `rm /data/.trial-armed`
   = the open-init becomes the committed baseline. If it works, optimize the HW datapath later.
2. If software-bridge still no inbound → debug the bcm runner's net→CPU forwarding: compare br-0045's
   WORKING inbound datapath (read it READ-ONLY: ethswctl CPU-port config, the runner/rdpa CPU rule,
   `fcctl`, the bridge's CPU port membership) vs the open-init's net-diag dump; add the missing CPU
   ingress/forwarding step to net-lan. Consider a REVERSE-TUNNEL (the open-init, which has OUTBOUND,
   `ssh -R` or a callback to the build host) to get interactive access despite no inbound.
3. Once reachable + committed: polish (webui start-stop-daemon needed libcap.so.2 [v9 added it];
   the /mnt + /mnt/defaults mount noise from graft rc3.d; S50ssl-not-found). Re-validate gate.
4. Open-wifi sole-supervisor: the EnsureRadio fix is MERGED (webui main 718bcb1, emulator-validated).
   LIVE re-test (separate from open-init): on a blob-0035 base, deploy that webui + arm nvram
   `gtbe98_wifi_extsup=1` + `webui_radio_init=1` → confirm 4 primaries + 7 secondaries ENABLED.

## SAFETY / STANDING AUTHORIZATIONS
- Operator authorized: FLASH FREELY (dead-man covers it), work in FULL AUTONOMY, NO questions.
- Every open-init trial = dead-man + NON-PETTING watchdog → auto-reverts to br-0045 (GOOD). Device
  has NEVER bricked (many recoveries). If hard-hung (only if you forget the non-petting watchdog) →
  operator power-cycle → boots br-0045. The wired mgmt (br0/eth/:2222) is the lifeline — never break it.
- merge-on-green (FF-only, never force); worktree-per-writer; ONE writer per repo; watch for ZOMBIE
  agents (a re-fired old agent collided in firmware once — confirm prior agents are dead before a fleet).
- Update MEMORY every round (append to [[phase3-openrc-init-feasible]]); leave the device on a clean
  committed baseline (br-0050) when pausing.
- Be HONEST: confirm the SLOT before claiming the open-init reachable (the ":80=200 was br-0045" trap).
