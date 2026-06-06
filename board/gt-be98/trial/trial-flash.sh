#!/bin/bash
# GT-BE98 host-side trial-flash driver.
#
# BOARD REALITY (live-verified 2026-06-05, flash-journal.md):
#  - The ONCE/ACTIVATE one-shot trial DOES work: `bcm_bootstate 3` writes
#    ACTIVATE into the reset-reason register; the next boot loads the
#    NON-committed slot, and the ACTIVATE is consumed (any later reset boots
#    the committed slot again). Layer A (kernel-hang) is therefore covered.
#  - /proc/bootstate/active_image LIES about the booted slot. The booted slot
#    comes from /proc/cmdline (ubi.block=0,4 = slot 1, 0,6 = slot 2) and
#    matches bcm_bootstate's "Booted Partition".
#  - hnd-write auto-commits the slot it writes (repair to the good slot
#    before arming ONCE).
#  - ASUS init self-commits the booted ONCE-trial slot late in boot
#    (sync_boot_state) and re-commits the higher-seq slot on every boot of
#    the lower-seq one - the dead-man's branches repair both.
#
# Trial outcomes:
#   PASS: disarm within the window (touch /tmp/deadman-disarm), gate-check.sh,
#         then rm /data/.trial-armed. The trial slot is already committed
#         (init self-commit) = the new good; old good stays valid as fallback.
#   FAIL (SSH up):   bcm_bootstate +G; reboot; then NEUTRALIZE: re-run this
#                    script with the GOOD image (overwrites the trial slot),
#                    rm the flag.
#   FAIL (SSH dead): dead-man fires at +WINDOW: commits good slot, reboots.
#                    Its armed flag is never consumed by failure paths - every
#                    good-slot boot re-repairs the commit until you neutralize.
#   Kernel hang:     ONCE consumed at load; watchdog reset boots committed
#                    good slot. (Corrupt flash: U-Boot FIT-load fallback.)
#
# Usage: trial-flash.sh [--reboot] [--window N] <image.pkgtb>
set -u

DEV="${GT_BE98_DEV:-admin@10.0.0.8}"; PORT="${GT_BE98_PORT:-2222}"
SSH="ssh -p $PORT -o ConnectTimeout=10 $DEV"
# booted slot via kernel cmdline - the ONLY reliable source (see header)
BOOTED_SLOT_CMD='case "$(cat /proc/cmdline)" in *ubi.block=0,4*) echo 1;; *ubi.block=0,6*) echo 2;; *) echo "";; esac'
WINDOW=300
DO_REBOOT=0

die() { echo "FATAL: $*" >&2; exit 1; }
info() { echo "== $*"; }

while [ $# -gt 1 ]; do
    case "$1" in
        --reboot) DO_REBOOT=1; shift;;
        --window) WINDOW=$2; shift 2;;
        *) die "unknown option $1";;
    esac
done
IMG=${1:?usage: trial-flash.sh [--reboot] [--window N] <image.pkgtb>}
[ -f "$IMG" ] || die "no such image: $IMG"
HERE=$(cd "$(dirname "$0")" && pwd)

SHA=$(sha256sum "$IMG" | cut -d' ' -f1)
info "image: $IMG"
info "sha256: $SHA"

# ---- preflight ---------------------------------------------------------------
STATE=$($SSH 'bcm_bootstate 2>/dev/null') || die "SSH unreachable"
ACTIVE=$($SSH "$BOOTED_SLOT_CMD")
[ -n "$ACTIVE" ] || die "preflight: cannot determine booted slot from cmdline"
COMMITTED=$(echo "$STATE" | grep -om1 'committed [0-9]' | awk '{print $2}')
RR=$($SSH 'cat /proc/bootstate/reset_reason')
echo "$STATE" | grep -q 'valid 1,2' || die "preflight: both slots must be valid, got: $(echo "$STATE" | grep -om1 'valid [0-9,]*')"
[ "$ACTIVE" = "$COMMITTED" ] || die "preflight: booted($ACTIVE) != committed($COMMITTED) - unfinished trial? clean up first"
[ "$RR" = "34" ] || die "preflight: reset_reason=$RR (expected 34/steadystate) - ONCE already armed?"
$SSH 'test -f /data/.trial-armed' && die "preflight: /data/.trial-armed exists - previous trial not cleaned up"
GOOD=$ACTIVE
TRIAL=$((3 - GOOD))
info "preflight OK: good slot=$GOOD (booted+committed), trial slot=$TRIAL, both valid"

$SSH 'mount | grep -q "jffs.*rw" && [ "$(nvram get jffs2_scripts)" = "1" ]' \
    || die "preflight: jffs not rw or jffs2_scripts!=1 (dead-man bootstrap needs both)"

FREE=$($SSH "df /tmp | awk 'NR==2{print \$4}'")
[ "$FREE" -gt 150000 ] || die "preflight: only ${FREE}K free in /tmp, need >150M"

# ---- transfer ------------------------------------------------------------------
info "transferring image to /tmp/trial.pkgtb (ssh-cat)"
$SSH 'cat > /tmp/trial.pkgtb' < "$IMG" || die "transfer failed"
RSHA=$($SSH 'sha256sum /tmp/trial.pkgtb' | cut -d' ' -f1)
[ "$RSHA" = "$SHA" ] || die "on-device sha mismatch: $RSHA"
info "on-device sha256 verified"

# ---- dead-man install + arm (BEFORE the flash) ---------------------------------
info "installing dead-man (window=${WINDOW}s)"
$SSH 'cat > /jffs/scripts/trial-deadman && chmod +x /jffs/scripts/trial-deadman' \
    < "$HERE/trial-deadman" || die "dead-man install failed"
$SSH 'touch /jffs/scripts/services-start; chmod +x /jffs/scripts/services-start;
      grep -q trial-deadman /jffs/scripts/services-start ||
      echo "/bin/sh /jffs/scripts/trial-deadman &  # flash-trial harness (slot-aware, inert when not armed)" >> /jffs/scripts/services-start'
$SSH "printf 'TRIAL_SLOT=%s\nGOOD_SLOT=%s\nWINDOW=%s\nSHA=%s\n' $TRIAL $GOOD $WINDOW $SHA > /data/.trial-armed; sync"
$SSH 'cat /data/.trial-armed' | grep -q "TRIAL_SLOT=$TRIAL" || die "arming flag verify failed"
info "dead-man armed: trial=$TRIAL good=$GOOD (flag persists until operator cleanup)"

# ---- flash inactive slot (hnd-write auto-commits it) ---------------------------
info "flashing inactive slot $TRIAL with hnd-write (exit 99 is normal)"
$SSH 'hnd-write /tmp/trial.pkgtb; echo "hnd-write exit=$?"' 2>&1 | tail -3
AFTER=$($SSH 'bcm_bootstate 2>/dev/null')
echo "$AFTER" | grep -q 'valid 1,2' || die "post-flash: slots no longer both valid! state: $AFTER"
echo "$AFTER" | grep -qm1 "committed $TRIAL" || die "post-flash: expected committed=$TRIAL (hnd-write auto-commit), got: $(echo "$AFTER" | grep -om1 'committed [0-9]')"
NEWSEQ=$(echo "$AFTER" | grep -om1 'seq [0-9]*,[0-9]*' | sed 's/seq //')
info "post-flash: committed=$TRIAL (hnd-write auto-commit), seq=$NEWSEQ, both valid"

# ---- repair commit back to the good slot ---------------------------------------
info "repairing commit -> good slot $GOOD"
$SSH "bcm_bootstate +$GOOD" >/dev/null 2>&1
$SSH 'bcm_bootstate 2>/dev/null' | grep -qm1 "committed $GOOD" || die "commit repair FAILED - DO NOT REBOOT; fix manually (bcm_bootstate +$GOOD)"
info "commit repaired: committed=$GOOD"

# ---- arm ONCE (one-shot boot of the non-committed = trial slot) ----------------
info "arming one-shot trial boot (bcm_bootstate 3)"
$SSH 'bcm_bootstate 3' >/dev/null 2>&1
RR=$($SSH 'cat /proc/bootstate/reset_reason')
[ "$RR" = "1" ] || die "ONCE arm failed: reset_reason=$RR (expected 1/ACTIVATE)"
FINAL=$($SSH 'bcm_bootstate 2>/dev/null')
echo "$FINAL" | grep -qm1 "committed $GOOD" || die "final check: committed flipped!"
echo "$FINAL" | grep -q 'valid 1,2' || die "final check: validity lost!"
info "metadata verified: committed=$GOOD, both valid, ONCE armed -> next boot = slot $TRIAL (once)"

if [ $DO_REBOOT = 0 ]; then
    cat <<EOF
== READY. Not rebooting (run with --reboot, or manually: ssh -p $PORT $DEV reboot)
== To ABORT the trial instead:
==   $SSH 'echo steadystate > /proc/bootstate/reset_reason; rm -f /data/.trial-armed'
==   then neutralize: re-run this script with the good image to overwrite slot $TRIAL.
EOF
    exit 0
fi

info "REBOOTING into trial slot $TRIAL (dead-man window=${WINDOW}s after services-start)"
$SSH 'reboot' 2>/dev/null
sleep 50
DEADLINE=$(( $(date +%s) + 1200 ))
while [ "$(date +%s)" -lt $DEADLINE ]; do
    A=$($SSH "$BOOTED_SLOT_CMD" 2>/dev/null) && [ -n "$A" ] && {
        info "SSH ANSWERED - booted slot: $A (trial=$TRIAL good=$GOOD)"
        $SSH 'bcm_bootstate 2>/dev/null' | grep -m3 -E 'committed|Booted'
        if [ "$A" = "$TRIAL" ]; then
            cat <<EOF
== TRIAL SLOT IS UP. Dead-man fires at services-start+${WINDOW}s unless disarmed:
==   $SSH 'touch /tmp/deadman-disarm'
== then run gate-check.sh; on PASS finish with:
==   $SSH 'rm -f /data/.trial-armed'   (trial slot stays committed via init self-commit)
EOF
        else
            echo "== device is on the GOOD slot - trial failed or rolled back; see /jffs/trial-deadman.log"
            echo "== neutralize before anything else: re-flash slot $TRIAL with the good image, then rm /data/.trial-armed"
        fi
        exit 0
    }
    sleep 10
done
echo "== device did not answer within 20 min - keep probing; dead-man + power-cycle both return to slot $GOOD"
exit 2
