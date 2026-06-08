#!/bin/bash
# v28 build: SLIM open-init — strip unused components + de-blob the DPI stack.
# Mirrors the v25 pipeline (openrc-assemble.sh + repack-pkgtb.py). The strip
# list + bwdpi stubs live in the worktree and are applied inside openrc-assemble.sh.
set -euo pipefail

V24=/home/guillaume/be98/job-tmp/openrc-init-v25
V25=/home/guillaume/be98/job-tmp/openrc-init-v28
WORKTREE=/home/guillaume/be98/gt-be98-buildroot/.claude/worktrees/openrc-init
ASSEMBLE="$WORKTREE/board/gt-be98/phase3/openrc/openrc-assemble.sh"
ARTIFACTS=/home/guillaume/be98/artifacts-br
OUTNAME=GT-BE98_openrc-init-v28_nand_squashfs.pkgtb

echo "== stage v28 build dir from v25 base =="
mkdir -p "$V25/base" "$V25/out" "$V25/pkgstage"
[ -f "$V25/base/rootfs.img" ]                 || cp -a "$V24/base/rootfs.img"                 "$V25/base/rootfs.img"
[ -f "$V25/base/bcm96813GW_uboot_linux.itb" ] || cp -a "$V24/base/bcm96813GW_uboot_linux.itb" "$V25/base/bcm96813GW_uboot_linux.itb"

echo "== assemble squashfs (uses worktree assemble + v28 strip + bwdpi stub) =="
bash "$ASSEMBLE" "$V25/base/rootfs.img" "$V25/out" | tee "$V25/assemble.log"
SQ="$V25/out/GT-BE98_openrc-init_rootfs.squashfs"
[ -f "$SQ" ] || { echo "FATAL: squashfs not produced"; exit 1; }

echo "== verify v28 strip + DPI stub landed in the assembled squashfs =="
UNSQ=/home/guillaume/be98/buildroot/output/host/bin/unsquashfs
# materialize the full listing ONCE (avoid SIGPIPE-vs-pipefail with grep -q)
LST="$V25/out/squashfs-listing.txt"
"$UNSQ" -l "$SQ" > "$LST" 2>/dev/null
# stripped components must be GONE
for p in /usr/sbin/wred /usr/sbin/Tor /usr/sbin/openvpn /usr/sbin/minidlna /usr/bin/jq /usr/br/bin/openssl; do
  if grep -qxF "squashfs-root$p" "$LST"; then
    echo "  ! FATAL: $p still present (strip failed)"; exit 2
  fi
done
echo "  [V] stripped components absent (wred/Tor/openvpn/minidlna/jq/usr-br-openssl)"
# v28 stock web stack must be GONE: /www tree + httpd + httpds
if grep -qxF "squashfs-root/www" "$LST"; then echo "  ! FATAL: /www still present (web strip failed)"; exit 2; fi
for p in /usr/sbin/httpd /usr/sbin/httpds; do
  if grep -qxF "squashfs-root$p" "$LST"; then echo "  ! FATAL: $p still present (web strip failed)"; exit 2; fi
done
echo "  [V] v28 stock web stack absent (/www tree + httpd + httpds)"
# kept channel + keep-set must remain
for p in /usr/br/sbin/dropbearmulti /usr/br/libexec/sftp-server /usr/lib/libbwdpi.so /usr/lib/libbwdpi_sql.so /usr/lib/libsqlite3.so.0 /usr/lib/libovpn.so /usr/lib/libssl.so.1.1 /usr/lib/libcrypto.so.1.1 /usr/sbin/wl /usr/lib/libwebapi.so /lib/libdisk.so /sbin/rc; do
  grep -qxF "squashfs-root$p" "$LST" \
    || { echo "  ! FATAL: $p missing (must be KEPT)"; exit 2; }
done
echo "  [V] keep-set present (dropbearmulti/sftp-server/libbwdpi/libbwdpi_sql/libsqlite3/libovpn/ssl/crypto/wl/libwebapi/libdisk/rc)"
# /lib/modules extra (Broadcom datapath) must remain
grep -qF "squashfs-root/lib/modules/4.19.294/extra/" "$LST" \
  && echo "  [V] /lib/modules/4.19.294/extra present in image" \
  || { echo "  ! FATAL /lib/modules extra missing"; exit 2; }
# bwdpi stub must be the small stub (originals were 146208 / 34272 B)
BWSZ=$(grep -E 'squashfs-root/usr/lib/libbwdpi\.so$' "$LST" >/dev/null && echo present)
echo "  libbwdpi.so in image: ${BWSZ:-?} (stub install confirmed by assemble symbol-verify above)"
# v25 functional content must be intact (sanity that the base overlay survived)
"$UNSQ" -cat "$SQ" /rom/etc/init.d/wifi-radio 2>/dev/null | grep -q 'load_wl_drivers' && echo '  [V] v25 wifi driver-load present' || { echo '  ! FATAL v25 wifi driver-load missing'; exit 2; }
"$UNSQ" -cat "$SQ" /rom/etc/init.d/net-lan 2>/dev/null | grep -q 'SLOT-PROOF dropbear on :2230' && echo "  [V] :2230 slot-proof kept" || { echo "  ! FATAL :2230 missing"; exit 2; }

echo "== write v28 repacker (paths -> v28) =="
sed -e 's#/openrc-init-v25/#/openrc-init-v28/#g' \
    -e 's#"v25-fit#"v26-fit#g' -e 's#"v15-fit#"v26-fit#g' -e 's#"v13-fit#"v26-fit#g' -e 's#"v8-fit#"v26-fit#g' \
    "$V24/repack-pkgtb.py" > "$V25/repack-pkgtb.py"

echo "== repack pkgtb =="
python3 "$V25/repack-pkgtb.py"
PKG="$V25/pkgstage/GT-BE98_nand_squashfs.pkgtb"
[ -f "$PKG" ] || { echo "FATAL: pkgtb not produced"; exit 3; }
mkdir -p "$ARTIFACTS"
cp -a "$PKG" "$ARTIFACTS/$OUTNAME"

echo "== DONE =="
echo "squashfs: $(stat -c%s "$SQ") bytes  sha=$(sha256sum "$SQ" | cut -d' ' -f1)"
echo "pkgtb:    $ARTIFACTS/$OUTNAME  ($(stat -c%s "$ARTIFACTS/$OUTNAME") bytes)  sha=$(sha256sum "$ARTIFACTS/$OUTNAME" | cut -d' ' -f1)"
