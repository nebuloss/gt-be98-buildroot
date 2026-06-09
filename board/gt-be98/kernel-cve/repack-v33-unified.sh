#!/usr/bin/env bash
# repack-v33-unified.sh — OFFLINE pure repack (no device, no build, no flash).
#
# GOAL: produce GT-BE98 v33 = the CVE-HARDENED kernel + the v32 rootfs, so the
# hardened kernel can be trialed WITHOUT regressing the just-promoted
# hostapd-on-openssl3 (which lives only in the v32 rootfs).
#
# This is a PURE REPACK of two already-built+validated .pkgtb artifacts. Nothing
# is recompiled. It takes:
#   - bootfs.itb (the kernel FIT segment, image 0) from the HARDENED pkgtb
#   - nand_squashfs (the rootfs, image 1)         from the V32 pkgtb
# and recombines them via the proven repack-pkgtb.py (same external-data FIT
# structure as v31/v32: bootfs node @data-offset 0 + nand_squashfs node +
# conf node + per-segment sha256 hashes).
#
# Segment split/recombine is byte-exact and mirrors open-flash.sh's dumpimage
# path (bootfs = FIT image 0, nand_squashfs = image 1).
#
# Verified provenance (2026-06-09):
#   v33 bootfs  sha256 = d73dfafa…  == HARDENED pkgtb image 0 (the 61-CVE vmlinux)
#   v33 rootfs  sha256 = 0de17e56…  == V32 pkgtb image 1 (rc-free + self-heal +
#                                       hostapd-openssl3)
#   v33 pkgtb   sha256 = 566dc968…  (size 48 839 764 B)
# Sanity: v33 bootfs DIFFERS from v32's kernel; v33 rootfs DIFFERS from the v31
# rootfs that shipped inside the hardened pkgtb. So the unified image is exactly
# "hardened kernel + v32 rootfs", nothing carried over by accident.
#
# CAVEAT (carried from NOTES.md Step 4): the rootfs's in-tree cfg80211.ko is the
# v32/v31 (pre-CVE) one — the wireless-CVE cfg80211.ko fix lives in vmlinux-built
# subsystems for everything except cfg80211 itself. To fully land the wireless
# CVE fixes, drop the hardened cfg80211.ko into the rootfs before squashing. The
# 61 built-in CVE fixes (net core, ipv4/6, netfilter, sctp, crypto, fs, security,
# lib) are ALL in the hardened vmlinux this v33 carries.
#
# NO FLASH. Trial gate = same as NOTES.md "Trial command + GATE".
set -euo pipefail

ART="${ART:-/home/guillaume/be98/artifacts-br}"
W="${W:-/home/guillaume/be98/job-tmp/v33-repack}"
HERE="$(cd "$(dirname "$0")" && pwd)"

HARDENED="$ART/GT-BE98_kernel-cve-hardened.pkgtb"          # sha 174eb963 (kernel: WANT, rootfs v31: DROP)
V32="$ART/GT-BE98_openrc-init-v32_nand_squashfs.pkgtb"     # sha 90c64182 (rootfs 0de17e56: WANT)
OUT="$ART/GT-BE98_openrc-init-v33_nand_squashfs.pkgtb"

WANT_BOOTFS=d73dfafa40a5ccaa6c93318ae7e43b5db03bc4ed80dce1d7d7950db7cdcb94cd  # hardened kernel itb
WANT_ROOTFS=0de17e562d7ade6bc5f34f3f4cd305423773e4af04ce339bac2e78949c81fb5a  # v32 rootfs

mkdir -p "$W"

# 1. HARDENED bootfs.itb = FIT image 0 of the hardened pkgtb
dumpimage -T flat_dt -p 0 -o "$W/hardened-bootfs.itb" "$HARDENED" >/dev/null
# 2. V32 nand_squashfs = FIT image 1 of the v32 pkgtb
dumpimage -T flat_dt -p 1 -o "$W/v32-nand_squashfs.bin" "$V32" >/dev/null

GOT_BOOTFS=$(sha256sum "$W/hardened-bootfs.itb"   | cut -d' ' -f1)
GOT_ROOTFS=$(sha256sum "$W/v32-nand_squashfs.bin" | cut -d' ' -f1)
[ "$GOT_BOOTFS" = "$WANT_BOOTFS" ] || { echo "FAIL: hardened bootfs sha mismatch ($GOT_BOOTFS)"; exit 1; }
[ "$GOT_ROOTFS" = "$WANT_ROOTFS" ] || { echo "FAIL: v32 rootfs sha mismatch ($GOT_ROOTFS)"; exit 1; }
echo "inputs verified: bootfs=hardened($GOT_BOOTFS) rootfs=v32($GOT_ROOTFS)"

# 3. Repack (proven external-data FIT assembler, identical to v31/v32 structure)
python3 "$HERE/repack-pkgtb.py" "$W/hardened-bootfs.itb" "$W/v32-nand_squashfs.bin" "$OUT"

# 4. Verify: well-formed FIT + open-flash split recovers both segments byte-exact
echo "=== dumpimage -l ==="
dumpimage -l "$OUT"
dumpimage -T flat_dt -p 0 -o "$W/recov-bootfs.itb"  "$OUT" >/dev/null
dumpimage -T flat_dt -p 1 -o "$W/recov-rootfs.sqfs" "$OUT" >/dev/null
cmp "$W/recov-bootfs.itb"  "$W/hardened-bootfs.itb"
cmp "$W/recov-rootfs.sqfs" "$W/v32-nand_squashfs.bin"
echo "OK: v33 well-formed; bootfs=hardened-kernel, rootfs=v32 (byte-exact split recovery)"
sha256sum "$OUT"
