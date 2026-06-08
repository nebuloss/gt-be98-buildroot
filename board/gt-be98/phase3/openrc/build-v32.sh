#!/bin/bash
# v32 build: v31 (rc-free + auto-revert) + hostapd STATIC-linked against
# openssl-3.6.2 (closes the live EOL openssl-1.1 gap — hostapd is the SOLE live
# 1.1 consumer). Mirrors the v31 pipeline (openrc-assemble.sh + repack-pkgtb.py)
# with the v32 HOSTAPD_OSSL3 injection hook. The 1.1 .so are KEPT for the inert
# non-launched 1.1 consumers (conservative).
set -euo pipefail

V31=/home/guillaume/be98/job-tmp/openrc-init-v31
V32=/home/guillaume/be98/job-tmp/openrc-init-v32
# Use the MAIN checkout's assemble (carries the v32 injection hook + recipe work),
# not the openrc-init worktree (which is pinned at v31).
REPO=/home/guillaume/be98/gt-be98-buildroot
ASSEMBLE="$REPO/board/gt-be98/phase3/openrc/openrc-assemble.sh"
ARTIFACTS=/home/guillaume/be98/artifacts-br
OUTNAME=GT-BE98_openrc-init-v32_nand_squashfs.pkgtb
HOSTAPD_OSSL3=/home/guillaume/be98/job-tmp/hostapd-ossl3/out/hostapd.ossl3.stripped

echo "== stage v32 build dir from v31 base =="
mkdir -p "$V32/base" "$V32/out" "$V32/pkgstage"
[ -f "$V32/base/rootfs.img" ]                 || cp -a "$V31/base/rootfs.img"                 "$V32/base/rootfs.img"
[ -f "$V32/base/bcm96813GW_uboot_linux.itb" ] || cp -a "$V31/base/bcm96813GW_uboot_linux.itb" "$V32/base/bcm96813GW_uboot_linux.itb"

[ -f "$HOSTAPD_OSSL3" ] || { echo "FATAL: openssl-3 hostapd not found at $HOSTAPD_OSSL3"; exit 1; }

echo "== assemble squashfs (v31 overlay + v32 openssl-3 hostapd injection) =="
HOSTAPD_OSSL3="$HOSTAPD_OSSL3" \
READELF=/home/guillaume/be98/buildroot/output/host/bin/arm-buildroot-linux-gnueabi-readelf \
  bash "$ASSEMBLE" "$V32/base/rootfs.img" "$V32/out" | tee "$V32/assemble.log"
SQ="$V32/out/GT-BE98_openrc-init_rootfs.squashfs"
[ -f "$SQ" ] || { echo "FATAL: squashfs not produced"; exit 1; }

echo "== verify v32 openssl-3 hostapd landed in the assembled squashfs =="
UNSQ=/home/guillaume/be98/buildroot/output/host/bin/unsquashfs
READELF=/home/guillaume/be98/buildroot/output/host/bin/arm-buildroot-linux-gnueabi-readelf
LST="$V32/out/squashfs-listing.txt"
"$UNSQ" -l "$SQ" > "$LST" 2>/dev/null

# extract hostapd from the assembled squashfs and re-verify openssl-3
rm -rf "$V32/verify"; mkdir -p "$V32/verify"
"$UNSQ" -n -f -d "$V32/verify/x" "$SQ" /usr/sbin/hostapd /usr/sbin/hostapd_cli /usr/lib/libceshared.so >/dev/null 2>&1
HA="$V32/verify/x/usr/sbin/hostapd"
[ -f "$HA" ] || { echo "FATAL: hostapd missing from squashfs"; exit 2; }
echo "  hostapd in image: $(stat -c%s "$HA") bytes  sha=$(sha256sum "$HA" | cut -d' ' -f1)"
if "$READELF" -d "$HA" 2>/dev/null | grep -qE 'libcrypto\.so\.1\.1|libssl\.so\.1\.1'; then
  echo "  ! FATAL: image hostapd still NEEDs libcrypto/libssl.so.1.1"; exit 2
fi
echo "  [V] image hostapd NEEDs NO libcrypto/libssl.so.1.1 (openssl-3 static)"
echo "  hostapd DT_NEEDED:"; "$READELF" -d "$HA" 2>/dev/null | sed -n 's/.*(NEEDED).*\[\(.*\)\]/    \1/p'
# libceshared unchanged + hostapd_cli present
grep -qxF "squashfs-root/usr/lib/libceshared.so" "$LST" && echo "  [V] libceshared.so present (unchanged)" || { echo "  ! FATAL libceshared missing"; exit 2; }
grep -qxF "squashfs-root/usr/sbin/hostapd_cli"   "$LST" && echo "  [V] hostapd_cli present" || { echo "  ! FATAL hostapd_cli missing"; exit 2; }
# rc must remain absent (v30/v31 rc-free); wl driver-load intact
grep -qxF "squashfs-root/sbin/rc" "$LST" && { echo "  ! FATAL /sbin/rc present (v31 rc-free regressed)"; exit 2; } || echo "  [V] /sbin/rc ABSENT (rc-free preserved)"
"$UNSQ" -cat "$SQ" /rom/etc/init.d/wifi-radio 2>/dev/null | grep -q 'load_wl_drivers' && echo "  [V] wifi driver-load present" || { echo "  ! FATAL wifi driver-load missing"; exit 2; }
# watchdog-keeper intact (v31 auto-revert)
"$UNSQ" -l "$SQ" 2>/dev/null | grep -qE 'watchdog-keeper|watchdog-disarm' && echo "  [V] watchdog service present" || echo "  ~ watchdog service not seen in listing (check init.d)"
# DT_NEEDED integrity gate must report clean
if grep -q 'DT_NEEDED integrity OK: 0 dangling' "$V32/assemble.log"; then
  echo "  [V] DT_NEEDED integrity gate PASSED (0 keep-set danglers)"
else
  echo "  ! FATAL: DT_NEEDED integrity gate did NOT report clean — see $V32/assemble.log"; exit 2
fi

echo "== write v32 repacker (paths -> v32) =="
sed -e 's#/openrc-init-v31/#/openrc-init-v32/#g' "$V31/repack-pkgtb.py" > "$V32/repack-pkgtb.py"

echo "== repack pkgtb =="
python3 "$V32/repack-pkgtb.py"
PKG="$V32/pkgstage/GT-BE98_nand_squashfs.pkgtb"
[ -f "$PKG" ] || { echo "FATAL: pkgtb not produced"; exit 3; }
mkdir -p "$ARTIFACTS"
cp -a "$PKG" "$ARTIFACTS/$OUTNAME"

echo "== DONE =="
SQSZ=$(stat -c%s "$SQ")
echo "squashfs: ${SQSZ} bytes  (ceiling 71106560, headroom $((71106560-SQSZ)))  sha=$(sha256sum "$SQ" | cut -d' ' -f1)"
echo "pkgtb:    $ARTIFACTS/$OUTNAME  ($(stat -c%s "$ARTIFACTS/$OUTNAME") bytes)  sha=$(sha256sum "$ARTIFACTS/$OUTNAME" | cut -d' ' -f1)"
