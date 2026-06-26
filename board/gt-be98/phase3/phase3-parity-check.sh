#!/bin/bash
# Phase-3 inversion Step-0 — parity check (plan §5, machine-checkable).
# Compares the assembled INVERTED rootfs against the Phase-2 BASELINE transform
# output, and classifies EVERY difference as EXPECTED-NEW / EXPECTED-GONE /
# CRITICAL. Exit gate (plan §6 Step-0): CRITICAL = 0.
#
# Usage: phase3-parity-check.sh <inv-root> <base-root> <manifest> <busybox-applets.txt> <report-dir>
set -uo pipefail
INV="${1:?inv-root}"; BASE="${2:?base-root}"; MAN="${3:?manifest}"
BBNEW="${4:?busybox-applets list}"; RPT="${5:?report-dir}"
mkdir -p "$RPT"
crit=0

echo "############ Phase-3 Step-0 parity check ############"
echo "INV  = $INV"
echo "BASE = $BASE"

echo; echo "## §5-1/3  Manifest completeness: every seed/closure/struct present + sha match"
nseed=0; nbad=0
while read -r kind bytes sha path arrow target; do
  case "$kind" in
    seed:*|closure|struct)
      rel="${path#/}"; nseed=$((nseed+1))
      if [ ! -e "$INV/$rel" ] && [ ! -L "$INV/$rel" ]; then
        echo "  CRITICAL missing: $path"; nbad=$((nbad+1)); crit=$((crit+1)); continue; fi
      if [ "$sha" != "-" ] && [ "$sha" != "?" ]; then
        got=$(sha256sum "$INV/$rel" 2>/dev/null | cut -d' ' -f1)
        if [ "$got" != "$sha" ]; then echo "  CRITICAL sha: $path want=$sha got=$got"; nbad=$((nbad+1)); crit=$((crit+1)); fi
      fi ;;
  esac
done < <(grep -vE '^\s*#|^\s*$|^dlopen' "$MAN")
echo "  manifest binary/struct entries checked=$nseed  failures=$nbad"

echo; echo "## §5-2  Symlinks (link / link:rc) resolve to manifest target"
nl=0; nlbad=0
while read -r kind bytes sha path arrow target; do
  case "$kind" in
    link|link:rc)
      rel="${path#/}"; nl=$((nl+1))
      got=$(readlink "$INV/$rel" 2>/dev/null)
      if [ "$got" != "$target" ]; then echo "  CRITICAL link: $path want=$target got=${got:-<none>}"; nlbad=$((nlbad+1)); crit=$((crit+1)); fi ;;
  esac
done < <(grep -vE '^\s*#|^\s*$|^dlopen' "$MAN")
echo "  symlinks checked=$nl  failures=$nlbad"

echo; echo "## §5-3  Wholesale trees byte-identical to baseline (/rom, /lib/modules)"
# Symlink-aware compare (diff -rq dereferences and chokes on stock dangling
# symlinks like rc3.d/S50ssl that exist identically in BOTH trees): compare the
# set of regular-file sha256 + the set of symlink targets, ignoring the
# build-identity marker gt-be98-release (expected to differ by design).
for t in rom lib/modules; do
  if [ -d "$BASE/$t" ]; then
    sig() { ( cd "$1/$t" && { find . -type f | LC_ALL=C sort | xargs -r sha256sum; \
              find . -type l | LC_ALL=C sort | while read -r l; do echo "$l -> $(readlink "$l")"; done; } ) | grep -v 'gt-be98-release'; }
    d=$(diff <(sig "$INV") <(sig "$BASE") || true)
    if [ -n "$d" ]; then n=$(echo "$d" | grep -cE '^[<>]'); echo "  CRITICAL tree delta in /$t ($n lines):"; echo "$d" | head -20 | sed 's/^/    /'; crit=$((crit + n)); else echo "  /$t: byte-identical (file sha + symlink targets, modulo gt-be98-release)"; fi
  else echo "  (baseline has no /$t to compare)"; fi
done

echo; echo "## §5-4  Structural skeleton (top-level symlinks + stub dirs + no real /etc)"
for ls in etc:tmp/etc home:tmp/home mnt:tmp/mnt opt:tmp/opt root:tmp/home/root debug:sys/kernel/debug; do
  l="${ls%%:*}"; want="${ls#*:}"; got=$(readlink "$INV/$l" 2>/dev/null)
  if [ "$got" != "$want" ]; then echo "  CRITICAL skel symlink /$l want=$want got=${got:-<none>}"; crit=$((crit+1)); fi
done
[ -d "$INV/etc" ] && [ ! -L "$INV/etc" ] && { echo "  CRITICAL: /etc is a real dir (must be symlink)"; crit=$((crit+1)); }
for d in data jffs mmc cifs1 cifs2 sysroot bootfs dev proc sys tmp var; do
  [ -d "$INV/$d" ] || { echo "  CRITICAL missing stub dir /$d"; crit=$((crit+1)); }
done
echo "  skeleton checked"

echo; echo "## §5-5  No special files; (mksquashfs -all-root normalizes ownership)"
sp=$(find "$INV" \( -type b -o -type c -o -type p -o -type s \) 2>/dev/null)
if [ -n "$sp" ]; then echo "  CRITICAL special files present:"; echo "$sp" | sed 's/^/    /'; crit=$((crit + $(echo "$sp"|grep -c .))); else echo "  none (OK)"; fi

echo; echo "## §5-6  Full-tree diff vs baseline, CLASSIFIED"
( cd "$BASE" && find . | LC_ALL=C sort ) > "$RPT/base.lst"
( cd "$INV"  && find . | LC_ALL=C sort ) > "$RPT/inv.lst"
comm -13 "$RPT/base.lst" "$RPT/inv.lst" > "$RPT/only-in-inv.lst"   # NEW in inverted
comm -23 "$RPT/base.lst" "$RPT/inv.lst" > "$RPT/only-in-base.lst"  # GONE from inverted

# Build the set of legitimate INV-only paths: manifest paths + structural + busybox-new.
{
  grep -vE '^\s*#|^\s*$|^dlopen' "$MAN" | awk '{ if ($1=="tree"){print "."$NF} else if ($4 ~ /^\//){print "."$4} }'
  # structural skeleton paths
  for p in /etc /home /mnt /opt /root /debug /data /jffs /jffs/awscerts /mmc /cifs1 /cifs2 \
           /sysroot /bootfs /dev /dev/misc /proc /sys /tmp /tmp/etc /tmp/mnt /var /var/var /bin /sbin /usr /usr/bin /usr/sbin /lib /lib64 /usr/lib; do echo ".$p"; done
  # busybox-new applet links + the busybox binary
  sed 's/ ->.*//' "$BBNEW" | sed 's|^|.|'
  echo "./bin/busybox"
} | LC_ALL=C sort -u > "$RPT/expected-inv.set"

# Anything in INV that's neither a manifest path, a parent dir of one, nor expected = CRITICAL leakage.
# (We allow any directory that is an ancestor of an expected path.)
awk 'NR==FNR{ok[$0]=1; next}{print}' "$RPT/expected-inv.set" "$RPT/only-in-inv.lst" > /dev/null
: > "$RPT/inv-unexpected.lst"
while IFS= read -r p; do
  grep -qxF "$p" "$RPT/expected-inv.set" && continue
  # allow ancestor dirs of any expected path
  if grep -qE "^${p//./\\.}/" "$RPT/expected-inv.set"; then continue; fi
  echo "$p" >> "$RPT/inv-unexpected.lst"
done < "$RPT/only-in-inv.lst"
nunexp=$(grep -c . "$RPT/inv-unexpected.lst"); nunexp=${nunexp:-0}

echo "  only-in-INV (EXPECTED-NEW: busybox + skeleton): $(grep -c . "$RPT/only-in-inv.lst")"
echo "  only-in-BASE (EXPECTED-GONE: blob content not grafted): $(grep -c . "$RPT/only-in-base.lst")"
echo "  INV-unexpected (CRITICAL leakage, must be 0): $nunexp"
if [ "$nunexp" -gt 0 ]; then echo "  --- unexpected INV paths (head) ---"; head -30 "$RPT/inv-unexpected.lst" | sed 's/^/    /'; crit=$((crit + nunexp)); fi

echo; echo "############ RESULT ############"
echo "CRITICAL diff count = $crit   (Step-0 exit gate: 0)"
echo "Reports in: $RPT"
exit $([ "$crit" -eq 0 ] && echo 0 || echo 1)
