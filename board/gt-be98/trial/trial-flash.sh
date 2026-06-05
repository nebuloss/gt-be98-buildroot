#!/bin/bash
# GT-BE98 host-side trial-flash driver.
# Flash a pkgtb to the INACTIVE slot, repair commit flags, arm the dead-man
# and the one-shot trial (ONCE/ACTIVATE), verify metadata, then (with
# --reboot) reboot and poll SSH, reporting which slot answered.
#
# Safety invariants enforced (see flash-journal.md Phase 1.1 for semantics):
#  - never flashes the active/committed slot (hnd-write targets the inactive
#    slot by design; we verify active==committed before starting)
#  - commit is repaired back to the good slot BEFORE any reboot
#  - refuses to proceed on any metadata anomaly (verified by reading state,
#    never by exit codes - bcm_bootstate exit codes are unreliable)
#
# Usage: trial-flash.sh [--reboot] [--no-deadman] [--window N] <image.pkgtb>
set -u

DEV="admin@10.0.0.8"; PORT=2222
SSH="ssh -p $PORT -o ConnectTimeout=10 $DEV"
WINDOW=300
DO_REBOOT=0
DEADMAN=1

die() { echo "FATAL: $*" >&2; exit 1; }
info() { echo "== $*"; }

while [ $# -gt 1 ]; do
    case "$1" in
        --reboot) DO_REBOOT=1; shift;;
        --no-deadman) DEADMAN=0; shift;;
        --window) WINDOW=$2; shift 2;;
        *) die "unknown option $1";;
    esac
done
IMG=${1:?usage: trial-flash.sh [--reboot] [--no-deadman] [--window N] <image.pkgtb>}
[ -f "$IMG" ] || die "no such image: $IMG"
HERE=$(cd "$(dirname "$0")" && pwd)

SHA=$(sha256sum "$IMG" | cut -d' ' -f1)
info "image: $IMG"
info "sha256: $SHA"

# ---- preflight ---------------------------------------------------------------
STATE=$($SSH 'bcm_bootstate 2>/dev/null' ) || die "SSH unreachable"
ACTIVE=$($SSH 'cat /proc/bootstate/active_image')
COMMITTED=$(echo "$STATE" | grep -om1 'committed [0-9]' | awk '{print $2}')
RR=$($SSH 'cat /proc/bootstate/reset_reason')
echo "$STATE" | grep -q 'valid 1,2' || die "preflight: both slots must be valid, got: $(echo "$STATE" | grep -om1 'valid [0-9,]*')"
[ "$ACTIVE" = "$COMMITTED" ] || die "preflight: active($ACTIVE) != committed($COMMITTED) - device in a trial or inconsistent state"
[ "$RR" = "34" ] || die "preflight: reset_reason=$RR (expected 34/steadystate) - ONCE already armed?"
GOOD=$ACTIVE
TRIAL=$((3 - GOOD))
info "preflight OK: good slot=$GOOD (active+committed), trial slot=$TRIAL, both valid"

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

# ---- dead-man install (before flash - must be in place before any reboot) -----
if [ $DEADMAN = 1 ]; then
    info "installing dead-man (window=${WINDOW}s)"
    $SSH 'cat > /jffs/scripts/trial-deadman && chmod +x /jffs/scripts/trial-deadman' \
        < "$HERE/trial-deadman" || die "dead-man install failed"
    # idempotent hook into services-start (preserves existing content e.g. webui-go)
    $SSH 'touch /jffs/scripts/services-start; chmod +x /jffs/scripts/services-start;
          grep -q trial-deadman /jffs/scripts/services-start ||
          echo "/bin/sh /jffs/scripts/trial-deadman &  # flash-trial harness (slot-aware, inert when not armed)" >> /jffs/scripts/services-start'
    $SSH "printf 'TRIAL_SLOT=%s\nGOOD_SLOT=%s\nWINDOW=%s\nSHA=%s\n' $TRIAL $GOOD $WINDOW $SHA > /jffs/.trial-armed; rm -f /jffs/.trial-armed.rolledback /jffs/.trial-armed.fired /jffs/.trial-armed.disarmed"
    $SSH 'cat /jffs/.trial-armed' | grep -q "TRIAL_SLOT=$TRIAL" || die "arming flag verify failed"
    info "dead-man armed: trial=$TRIAL good=$GOOD"
fi

# ---- flash inactive slot -------------------------------------------------------
info "flashing inactive slot $TRIAL with hnd-write (exit 99 is normal)"
$SSH 'hnd-write /tmp/trial.pkgtb; echo "hnd-write exit=$?"' 2>&1 | tail -5
AFTER=$($SSH 'bcm_bootstate 2>/dev/null')
echo "$AFTER" | grep -q 'valid 1,2' || die "post-flash: slots no longer both valid! state: $AFTER"
NEWSEQ=$(echo "$AFTER" | grep -om1 'seq [0-9]*,[0-9]*' | sed 's/seq //')
info "post-flash seq: $NEWSEQ"

# ---- repair commit back to the good slot ---------------------------------------
info "repairing commit -> slot $GOOD"
$SSH "bcm_bootstate +$GOOD" >/dev/null 2>&1
$SSH 'bcm_bootstate 2>/dev/null' | grep -qm1 "committed $GOOD" || die "commit repair FAILED - DO NOT REBOOT; fix manually (bcm_bootstate +$GOOD)"
info "commit repaired: committed=$GOOD"

# ---- arm ONCE -------------------------------------------------------------------
info "arming one-shot trial boot (bcm_bootstate 3)"
$SSH 'bcm_bootstate 3' >/dev/null 2>&1
RR=$($SSH 'cat /proc/bootstate/reset_reason')
[ "$RR" = "1" ] || die "ONCE arm failed: reset_reason=$RR (expected 1/ACTIVATE)"
FINAL=$($SSH 'bcm_bootstate 2>/dev/null')
echo "$FINAL" | grep -qm1 "committed $GOOD" || die "final check: committed flipped!"
echo "$FINAL" | grep -q 'valid 1,2' || die "final check: validity lost!"
TGT=$([ "$TRIAL" = 1 ] && echo First || echo Second)
echo "$FINAL" | grep -q "Reboot Partition: $TGT" || die "final check: reboot partition is not the trial slot!"
info "metadata verified: committed=$GOOD, both valid, ONCE armed -> next boot = slot $TRIAL (once)"

if [ $DO_REBOOT = 0 ]; then
    cat <<EOF
== READY. Not rebooting (run with --reboot, or manually: ssh -p $PORT $DEV reboot)
== To abort the trial instead:
==   $SSH 'rm -f /jffs/.trial-armed; echo steadystate > /proc/bootstate/reset_reason'
EOF
    exit 0
fi

info "REBOOTING into trial (window=${WINDOW}s; dead-man returns to slot $GOOD if not disarmed)"
$SSH 'reboot' 2>/dev/null
sleep 50
DEADLINE=$(( $(date +%s) + 900 ))
while [ "$(date +%s)" -lt $DEADLINE ]; do
    A=$($SSH 'cat /proc/bootstate/active_image' 2>/dev/null) && {
        info "SSH ANSWERED - active slot: $A (trial=$TRIAL good=$GOOD)"
        $SSH 'bcm_bootstate 2>/dev/null' | grep -E 'committed|Booted|Reboot' | head -4
        if [ "$A" = "$TRIAL" ]; then
            echo "== TRIAL SLOT IS UP. To disarm the dead-man (operator decision):"
            echo "==   $SSH 'touch /tmp/deadman-disarm'"
        else
            echo "== device is on the GOOD slot (rollback or trial never started)"
        fi
        exit 0
    }
    sleep 10
done
echo "== device did not answer within 15 min - keep probing manually; expected auto-return <= deadman window + boot time"
exit 2
