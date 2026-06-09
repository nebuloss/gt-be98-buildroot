#!/usr/bin/env bash
# repack-v34-cfg80211-modtrim.sh — OFFLINE rootfs-modify + repack (no device, no
# build, no flash).
#
# GOAL: produce GT-BE98 v34 = v33 (hardened CVE kernel + v32 openssl-3 rootfs)
# PLUS two rootfs-only changes:
#   (1) drop in the hardened cfg80211.ko  -> lands the wireless CVEs (scan/sme)
#       that live in the in-tree module (CONFIG_MAC80211 is OFF, so cfg80211.ko
#       is the only CVE-relevant in-tree .ko that ships in the rootfs).
#   (2) strip 3 unused kernel modules (bcm_pondrv, bcm_bca_usb, nat46) confirmed
#       not-loaded on this unit -> shrinks the image, removes dead attack surface.
#
# Pure repack of validated artifacts: take the v33 pkgtb, split it, unsquash the
# rootfs, apply the two changes, re-squash with the SAME mksquashfs flags
# openrc-assemble.sh uses (xz / -b 131072 / -all-root), then recombine the
# UNCHANGED hardened bootfs.itb + the new rootfs squashfs via repack-pkgtb.py
# (same external-data FIT structure as v31/v32/v33).
#
# Module-load safety (verified): the 3 removed .ko are referenced only in:
#   - bcm-base-drivers.sh: a COMMENT (no insmod)
#   - hndmfg.sh: best-effort mfg_insmod, only in the CFE mfg_nvram_mode=1 path
#   - disk.sh: a SATA/USB list iterated under /proc/modules guards (never forced)
# None unconditionally fail on a missing .ko -> removal is safe.
#
# modules.dep/.alias/.symbols (+ .bin) contain ZERO references to the 3 modules
# (they are leaf, non-dependency .ko). The only index reference is 3 lines in
# modules.order (informational, not consulted at load time) which are stripped.
# No depmod regeneration needed (and host depmod against an aarch64 4.19 tree is
# avoided to not perturb the .bin indices).
#
# Verified provenance (2026-06-09):
#   v34 bootfs sha256 = d73dfafa…  == v33 bootfs (the 61-CVE hardened vmlinux), UNCHANGED
#   v34 rootfs sha256 = 48309c25…  (v32 rootfs + hardened cfg80211.ko - 3 .ko)
#   v34 pkgtb  sha256 = c69cf409…  (size 48 798 804 B)
#   hardened cfg80211.ko sha256 = 6c3d7779…  vermagic 4.19.294 SMP preempt mod_unload aarch64
#
# NO FLASH. Trial gate = same as NOTES.md "Trial command + GATE".
set -euo pipefail

ART="${ART:-/home/guillaume/be98/artifacts-br}"
W="${W:-/home/guillaume/be98/job-tmp/v34-repack}"
HERE="$(cd "$(dirname "$0")" && pwd)"

# squashfs tools + flags MUST match openrc-assemble.sh (xz, 131072, -all-root).
UNSQ="${UNSQ:-/home/guillaume/be98/buildroot/output/host/bin/unsquashfs}"
MKSQ="${MKSQ:-/home/guillaume/be98/buildroot/output/host/bin/mksquashfs}"

V33="$ART/GT-BE98_openrc-init-v33_nand_squashfs.pkgtb"            # sha 566dc968
HARDENED_KO="${HARDENED_KO:-/home/guillaume/be98/job-tmp/kernel-fromsrc/hardened-modules/cfg80211.ko}"
OUT="$ART/GT-BE98_openrc-init-v34_nand_squashfs.pkgtb"

WANT_V33=566dc9680ff7ee241ed0a9045efc9dc28df8da173a146569b291fe6b1c4ca7f1
WANT_BOOTFS=d73dfafa40a5ccaa6c93318ae7e43b5db03bc4ed80dce1d7d7950db7cdcb94cd  # hardened kernel itb (unchanged)
WANT_HARDENED_KO=6c3d777931d324152d366ca7498245b076e97dd74a3d391eaaebb6481d0cd634

VERMAGIC="4.19.294 SMP preempt mod_unload aarch64"
MODDIR_REL="lib/modules/4.19.294"
DROP_KO=(bcm_pondrv bcm_bca_usb nat46)
CEILING=71106560

mkdir -p "$W"

# grep helper that consumes all input (no SIGPIPE under `set -o pipefail`, unlike
# `grep -q` which exits early and makes the upstream producer return 141).
has_line() { grep -c -- "$1" >/dev/null; }   # rc 0 if >=1 match, 1 otherwise

# 0. Validate inputs
[ "$(sha256sum "$V33" | cut -d' ' -f1)" = "$WANT_V33" ] || { echo "FAIL: v33 pkgtb sha mismatch"; exit 1; }
[ "$(sha256sum "$HARDENED_KO" | cut -d' ' -f1)" = "$WANT_HARDENED_KO" ] || { echo "FAIL: hardened cfg80211.ko sha mismatch"; exit 1; }
strings "$HARDENED_KO" | has_line "vermagic=$VERMAGIC" || { echo "FAIL: hardened cfg80211.ko vermagic != $VERMAGIC"; exit 1; }
echo "inputs verified: v33=$WANT_V33  hardened-cfg80211=$WANT_HARDENED_KO (vermagic OK)"

# 1. Split v33: image 0 = hardened bootfs.itb, image 1 = v33(=v32) rootfs squashfs
dumpimage -T flat_dt -p 0 -o "$W/hardened-bootfs.itb" "$V33" >/dev/null
dumpimage -T flat_dt -p 1 -o "$W/v33-rootfs.sqfs"     "$V33" >/dev/null
[ "$(sha256sum "$W/hardened-bootfs.itb" | cut -d' ' -f1)" = "$WANT_BOOTFS" ] || { echo "FAIL: v33 bootfs sha mismatch"; exit 1; }

# 2. Unsquash + verify squashfs params match openrc-assemble (xz, 131072)
"$UNSQ" -s "$W/v33-rootfs.sqfs" | has_line "Compression xz" || { echo "FAIL: v33 rootfs not xz"; exit 1; }
"$UNSQ" -s "$W/v33-rootfs.sqfs" | has_line "Block size 131072" || { echo "FAIL: v33 rootfs bsize != 131072"; exit 1; }
rm -rf "$W/rootfs"
"$UNSQ" -d "$W/rootfs" "$W/v33-rootfs.sqfs" >/dev/null
M="$W/rootfs/$MODDIR_REL"

# 2a. Replace cfg80211.ko with the hardened one (target path + vermagic must match)
[ -f "$M/kernel/net/wireless/cfg80211.ko" ] || { echo "FAIL: target cfg80211.ko path missing"; exit 1; }
strings "$M/kernel/net/wireless/cfg80211.ko" | has_line "vermagic=$VERMAGIC" || { echo "FAIL: target cfg80211 vermagic mismatch"; exit 1; }
cp "$HARDENED_KO" "$M/kernel/net/wireless/cfg80211.ko"
chmod 644 "$M/kernel/net/wireless/cfg80211.ko"
echo "cfg80211.ko -> hardened ($(sha256sum "$M/kernel/net/wireless/cfg80211.ko" | cut -d' ' -f1))"

# 2b. Remove the 3 unused modules + strip their (sole) modules.order references
for k in "${DROP_KO[@]}"; do
    [ -f "$M/extra/$k.ko" ] || { echo "FAIL: expected $k.ko to exist before removal"; exit 1; }
    rm -f "$M/extra/$k.ko"
done
cp "$M/modules.order" "$M/.modules.order.in"
grep -vE 'nat46\.ko$|bcm_pondrv\.ko$|bcm_bca_usb\.ko$' "$M/.modules.order.in" > "$M/modules.order"
rm -f "$M/.modules.order.in"
# sanity: no residual references to the 3 in any module index
if grep -rlE 'bcm_pondrv|bcm_bca_usb|nat46' "$M"/modules.* 2>/dev/null; then
    echo "FAIL: residual module-index reference to a removed module"; exit 1
fi
echo "removed: ${DROP_KO[*]} (+ stripped modules.order)"

# 3. Re-squash with the EXACT openrc-assemble.sh flags (bootable + fits)
rm -f "$W/v34-rootfs.sqfs"
"$MKSQ" "$W/rootfs" "$W/v34-rootfs.sqfs" -noappend -all-root -comp xz -b 131072 -no-progress >/dev/null
V34_SQ_SHA=$(sha256sum "$W/v34-rootfs.sqfs" | cut -d' ' -f1)
V34_SQ_SZ=$(stat -c '%s' "$W/v34-rootfs.sqfs")
V33_SQ_SZ=$(stat -c '%s' "$W/v33-rootfs.sqfs")
echo "v34 rootfs squashfs: $V34_SQ_SHA  size=$V34_SQ_SZ  (v33=$V33_SQ_SZ  delta=$((V33_SQ_SZ - V34_SQ_SZ))B smaller)"
[ "$V34_SQ_SZ" -lt "$CEILING" ] || { echo "FAIL: v34 rootfs over slot ceiling $CEILING"; exit 1; }

# 4. Repack: hardened bootfs.itb (unchanged) + v34 rootfs squashfs
python3 "$HERE/repack-pkgtb.py" "$W/hardened-bootfs.itb" "$W/v34-rootfs.sqfs" "$OUT"

# 5. Verify: well-formed FIT + byte-exact split recovery of both segments
echo "=== dumpimage -l ==="
dumpimage -l "$OUT"
dumpimage -T flat_dt -p 0 -o "$W/recov-bootfs.itb"  "$OUT" >/dev/null
dumpimage -T flat_dt -p 1 -o "$W/recov-rootfs.sqfs" "$OUT" >/dev/null
cmp "$W/recov-bootfs.itb"  "$W/hardened-bootfs.itb"
cmp "$W/recov-rootfs.sqfs" "$W/v34-rootfs.sqfs"
echo "OK: v34 well-formed; bootfs=hardened-kernel (unchanged), rootfs=v34 (hardened cfg80211 + 3 .ko removed)"
sha256sum "$OUT"
