#!/usr/bin/env bash
# open-flash.sh — OPEN replacement for the closed `hnd-write` (= an rc applet).
# Flashes a .pkgtb to the INACTIVE/spare slot using ONLY open tools, so the
# closed `rc` binary (which provides hnd-write) can be deleted.
#
# ★PROVEN 2026-06-08 (see memory open-flasher-feasible):★ the volume write is
# byte-identical to stock and BOOTS; the metadata seq-bump writer is offline
# CRC-validated. hnd-write decomposes 100% into: dumpimage (FIT parse, we own
# the producer) + ubirmvol/ubimkvol/ubiupdatevol (mtd-utils, on-device at /bin)
# + a CRC32-env metadata writer + bcm_bootstate (activate). No closed code.
#
# SAFETY: writes ONLY the spare (non-committed) slot; the committed slot is the
# untouched recovery target. Backs up the shared metadata before touching it.
# Pairs with the deadman-early/trial-deadman dead-man (revert to GOOD on fail).
#
# Usage: GT_BE98_PORT=2222 ./open-flash.sh <image.pkgtb>      (arms; you reboot)
set -euo pipefail
PKG="${1:?usage: open-flash.sh <image.pkgtb>}"
DEV="${GT_BE98_DEV:-admin@10.0.0.8}"; PORT="${GT_BE98_PORT:-2222}"
SSH="ssh -p $PORT -o ConnectTimeout=8 -o StrictHostKeyChecking=no $DEV"
SSHT="ssh -T -p $PORT -o ConnectTimeout=10 -o StrictHostKeyChecking=no $DEV"
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
say(){ echo "== $*"; }; die(){ echo "!! $*" >&2; exit 1; }

# --- 1. preflight: determine GOOD (booted+committed) and TRIAL (spare) slots ---
ST="$($SSH 'bcm_bootstate 2>/dev/null; echo CMD=$(grep -o ubi.block=0,[0-9] /proc/cmdline); echo RR=$(cat /proc/bootstate/reset_reason)')"
# read the booted slot from the CMD= line ONLY (the bcm_bootstate 'seq' value can itself contain '0,[0-9]', e.g. seq 50,48)
BOOT=$(echo "$ST" | sed -n 's/^CMD=ubi\.block=\(0,[0-9]\).*/\1/p'); case "$BOOT" in 0,4) GOOD=1;; 0,6) GOOD=2;; *) die "cannot read booted slot";; esac
COMMIT=$(echo "$ST" | grep -om1 'committed [0-9]' | awk '{print $2}')
echo "$ST" | grep -q 'valid 1,2' || die "both slots must be valid"
[ "$GOOD" = "$COMMIT" ] || die "booted($GOOD)!=committed($COMMIT) — clean up first"
echo "$ST" | grep -q 'RR=34' || die "reset_reason!=34 (a trial is already armed)"
TRIAL=$((3-GOOD))
# runtime ubi vol indices: bootfs1=ubi0_3 rootfs1=ubi0_4 ; bootfs2=ubi0_5 rootfs2=ubi0_6 ; meta=ubi0_1,ubi0_2
if [ "$TRIAL" = 1 ]; then BVOL=3; RVOL=4; else BVOL=5; RVOL=6; fi
say "preflight OK: good=$GOOD (committed, untouched), trial=$TRIAL -> bootfs=ubi0_$BVOL rootfs=ubi0_$RVOL"

# --- 2. extract + verify FIT segments (host dumpimage; we produced the FIT) ----
dumpimage -T flat_dt -p 0 -o "$TMP/bootfs.itb"   "$PKG" >/dev/null || die "dumpimage bootfs"
dumpimage -T flat_dt -p 1 -o "$TMP/rootfs.sqfs"  "$PKG" >/dev/null || die "dumpimage rootfs"
RSZ=$(stat -c%s "$TMP/rootfs.sqfs"); RSHA=$(sha256sum "$TMP/rootfs.sqfs"|cut -c1-16); BSHA=$(sha256sum "$TMP/bootfs.itb"|cut -c1-16)
say "segments: rootfs ${RSZ}B sha=$RSHA  bootfs sha=$BSHA"

# --- 3. transfer segments ------------------------------------------------------
$SSHT 'cat > /tmp/of.bootfs' < "$TMP/bootfs.itb"
$SSHT 'cat > /tmp/of.rootfs' < "$TMP/rootfs.sqfs"
$SSH "[ \$(sha256sum /tmp/of.rootfs|cut -c1-16) = $RSHA ]" || die "rootfs transfer corrupt"

# --- 4. OPEN-WRITE the trial slot volumes (recreate sized, like stock) ---------
say "open-writing trial slot $TRIAL volumes (ubirmvol/ubimkvol/ubiupdatevol)"
$SSH "set -e
  case \"\$(cat /proc/cmdline)\" in *0,$((GOOD==1?4:6))*) : ;; *) echo GUARD-FAIL; exit 9;; esac
  /bin/ubirmvol /dev/ubi0 -n $RVOL
  /bin/ubimkvol /dev/ubi0 -n $RVOL -N rootfs$TRIAL -s $RSZ -t dynamic
  /bin/ubiupdatevol /dev/ubi0_$RVOL /tmp/of.rootfs
  /bin/ubiupdatevol /dev/ubi0_$BVOL /tmp/of.bootfs"
RB=$($SSH "dd if=/dev/ubi0_$RVOL bs=4096 count=\$(( ($RSZ+4095)/4096 )) 2>/dev/null | sha256sum | cut -c1-16")
[ "$RB" = "$RSHA" ] || die "read-back mismatch ($RB != $RSHA) — trial slot only; committed slot safe"
say "volume write verified byte-identical (rootfs $RB)"

# --- 5. metadata: backup, bump TRIAL seq to max+1, recompute CRC, write both ---
# (mirrors the offline-validated writer; uses on-device ubicrc32 for the CRC.)
$SSHT 'dd if=/dev/ubi0_1 bs=1 count=1280 2>/dev/null' > "$TMP/meta.bak"
[ "$(stat -c%s "$TMP/meta.bak")" = 1280 ] || die "metadata backup failed — abort before any metadata write"
python3 - "$TMP/meta.bak" "$TMP/meta.new" "$TRIAL" <<'PY'
import sys,zlib,struct,re
b=bytearray(open(sys.argv[1],'rb').read()); trial=int(sys.argv[3])
# layout: [0:4]=word0 (=n+4, n = CRC data-region length, FIXED), [8:12]=crc32(data[:n]),
# data=b[12:12+n] is a region of NUL-separated key entries; the LAST entry is the
# (already truncated-to-fit) mtd partition-map text. The bootloader reads
# COMMITTED=/VALID=/SEQ= from here. n is fixed by the buffer, so a SEQ that grows
# digits (9->10, 99->100, ...) is absorbed by REFLOWING within the fixed n-byte
# window: shift the bytes after SEQ and trim the equal number of bytes off the
# partition-map tail (which is informational + pre-truncated). On a SHRINK
# (unlikely) we pad the tail with NUL to keep n constant.
w0,=struct.unpack_from('<I',b,0); n=(w0-4)&0xffff; data=bytearray(b[12:12+n])
m=re.search(rb'SEQ=(\d+),(\d+)\x00',bytes(data))
assert m, "SEQ token not found in metadata data region"
s=[int(m.group(1)),int(m.group(2))]
new=max(s)+1; s[trial-1]=new; nt=f"SEQ={s[0]},{s[1]}\x00".encode()
old=m.group(0); delta=len(nt)-len(old)
if delta==0:
    data[m.start():m.end()]=nt
else:
    head=data[:m.start()]; tail=data[m.end():]      # tail = everything after old SEQ token
    if delta>0:
        # SEQ grew: drop `delta` bytes from the END of the window (map-text tail slack)
        if len(tail) < delta:
            sys.exit("FATAL: seq rollover would overflow CRC window (no map-text slack to reclaim)")
        # guard: never trim into a structural entry (COMMITTED/VALID/SEQ live in head)
        tail=tail[:len(tail)-delta]
    else:
        # SEQ shrank: pad the tail back to length with NUL so n stays constant
        tail=tail + b'\x00'*(-delta)
    newdata=head+nt+tail
    assert len(newdata)==n, f"reflow length error: {len(newdata)} != {n}"
    data=newdata
b[12:12+n]=data
struct.pack_into('<I',b,8,zlib.crc32(bytes(data[:n]))&0xffffffff)
open(sys.argv[2],'wb').write(b); print(f"seq->{s[0]},{s[1]}" + (f" (reflowed {delta:+d}B)" if delta else ""))
PY
$SSHT 'cat > /tmp/of.meta' < "$TMP/meta.new"
# write vol1, verify; only then vol2 (one valid copy always remains)
$SSH '/bin/ubiupdatevol /dev/ubi0_1 /tmp/of.meta'
$SSH "bcm_bootstate 2>/dev/null | grep -q 'valid 1,2'" || { say "vol1 suspect — restoring"; $SSHT 'cat>/tmp/of.meta.bak' <"$TMP/meta.bak"; $SSH '/bin/ubiupdatevol /dev/ubi0_1 /tmp/of.meta.bak'; die "metadata vol1 write failed — restored from backup"; }
$SSH '/bin/ubiupdatevol /dev/ubi0_2 /tmp/of.meta'
say "metadata seq-bumped (trial slot now newest): $($SSH 'bcm_bootstate 2>/dev/null | grep -om1 "seq [0-9,]*"')"

# --- 6. arm dead-man + activate (one-shot boot of the trial slot) --------------
$SSH "printf 'TRIAL_SLOT=%s\nGOOD_SLOT=%s\nWINDOW=240\n' $TRIAL $GOOD > /data/.trial-armed; sync"
$SSH 'bcm_bootstate 3 >/dev/null 2>&1'
$SSH "[ \$(cat /proc/bootstate/reset_reason) = 1 ]" || die "activate failed"
say "READY: committed stays $GOOD (safe), trial $TRIAL armed (higher seq + activate). Reboot to boot it;"
say "       dead-man reverts to slot $GOOD if it doesn't come up. Disarm a healthy boot: wdtctl stop."
