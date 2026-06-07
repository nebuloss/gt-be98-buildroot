#!/bin/bash
# From-source WIRED-ONLY rootfs variant (build-only, no flash, no device).
#
# WHY: the from-source rootfs (br-0049 base + clean-room nvram + k-verbs fix +
# forensics rails) hangs at boot T+60-70s in the WIFI bring-up stage. Instrumented
# forensics (job-tmp/nvram-retrial-*/FORENSIC-VERDICT.md) proved:
#   - S40 hndnvram kernelset populates all 8218 nvram vars cleanly (rc=0)   [wired-safe]
#   - dhd loads all 4 radios by T+60, THEN the box hard-hangs T+60-70 during
#     `wlaffinity auto` + the wifi bring-up's heavy clean-room nvram CLI ops
#     (`nvram show`/getall over ~8266 live vars, `kcommit`) — the suspect is the
#     clean-room nvram CLI diverging from the closed blob at full boot scale, and
#     the only place that path is exercised at boot is the WIFI bring-up scripts.
# Operator: wifi is NOT required; wired ethernet is enough. So disable wifi
# bring-up -> boot should sail past the hang to wired + SSH + webui.
#
# DISABLE MECHANISM (layered, deterministic, wired-safe). All three target ONLY
# the wl/wifi path; none touch the eth/switch/bridge/lan/nvram-populate path:
#   1. Rename the radio drivers  dhd.ko -> dhd.ko.wifi-disabled,
#      wl.ko -> wl.ko.wifi-disabled  in /lib/modules/$KVER/extra/.
#      `rc`'s load_wl() does the dhd/wl insmod directly (the rc3.d wlan rail is
#      stock-merlin INERT - start_main only echoes "skip load_modules"). With the
#      radio .ko renamed, load_wl's insmod fails fast (ENOENT) -> no dhd_attach,
#      no rtecdc.bin firmware load, no PCIe/MLO radio bring-up, no wlaffinity
#      trigger, no post-load nvram config -> the T+60-70 hang cannot occur.
#      KEPT loadable: hnd/emf/igs/wlshared (harmless wl infra rc also loads) and
#      ALL wired/switch/datapath modules (bcm_enet, rdpa*, bcmvlan, pktflow,
#      pktrunner, bdmf, wfd, bcm_pcie_hcd) + bcm_knvram.
#   2. bcm-wlan-drivers.sh: early `exit 0`. Its main body (runs on every
#      invocation regardless of the inert start_main) does `nvram kget wl_unitlist`,
#      pwlcs kget/kset/kcommit, `nvram show | grep kernel_mods`, `nvram kget
#      kernel_mods` and calls `wifi.sh dpdmode` + `wlaffinity` - i.e. exactly the
#      clean-room nvram CLI churn that hangs. Skip it.
#   3. wifi.sh: early `exit 0`. This is the restart_wireless / dpd / PCIe-MLO
#      worker (rc's restart_wireless calls it). No-op it so a half-disabled wifi
#      path cannot hang on radio/PCIe/MLO ops.
#
# WIRED stays intact: S45bcm-base-drivers loads enet/switch/rdpa; `rc` start_lan
# builds br0 + eth0-3 + VLANs + udhcpc; S40 hndnvram populates the kernel nvram
# (lan_ifnames/IP/etc); S28br-dropbear = SSH; /usr/br = webui. Verified byte-equal
# vs br-0049 in the parity step below.
#
# KEEP the forensics instrumentation (S26nvram-forensics, S26trial-deadman,
# S27boot-breadcrumb, S28br-dropbear, hndnvram kernelset logging) - the boot should
# now REACH /data, so we get good logs whatever happens.
#
# Usage: fromsrc-wired-only.sh <instr-fromsrc-tree> <out-dir>
#   <instr-fromsrc-tree> = the assembled from-source + clean-room-nvram + forensics
#                          rootfs tree (e.g. output-instr/fromsrc).
set -euo pipefail
SRC="${1:?instr from-source rootfs tree}"; OUT="${2:?out dir}"
KVER="${KVER:-4.19.294}"
MKSQ="${MKSQ:-/home/guillaume/be98/buildroot/output/host/bin/mksquashfs}"

FS="$OUT/fromsrc"; mkdir -p "$OUT/images"
rm -rf "$FS"; cp -a "$SRC" "$FS"

EX="$FS/lib/modules/$KVER/extra"
mv "$EX/dhd.ko" "$EX/dhd.ko.wifi-disabled"
mv "$EX/wl.ko"  "$EX/wl.ko.wifi-disabled"

gate() {  # insert an early exit 0 right after the shebang of $1
    local f="$1" tag="$2"
    awk -v tag="$tag" 'NR==1{print; print "# === WIRED-ONLY VARIANT: WiFi bring-up DISABLED ==="; print "echo \"" tag ": WIRED-ONLY variant - wifi bring-up DISABLED, exit 0\" 2>/dev/null || true"; print "exit 0"; next} {print}' "$f" > "$f.tmp" && mv "$f.tmp" "$f" && chmod +x "$f"
}
gate "$FS/rom/etc/init.d/bcm-wlan-drivers.sh" "bcm-wlan-drivers.sh"
gate "$FS/rom/etc/init.d/wifi.sh"             "wifi.sh"

SQ="$OUT/images/rootfs.squashfs"; rm -f "$SQ"
"$MKSQ" "$FS" "$SQ" -noappend -all-root -comp xz -b 131072 -no-progress >/dev/null
echo "== wired-only rootfs: $(stat -c%s "$SQ") bytes  sha=$(sha256sum "$SQ" | cut -d' ' -f1) =="
echo "Now FIT-wrap with board/gt-be98/post-image.sh \"$OUT/images\" (GT_BE98_BOOTFS_ITB + GT_BE98_MKIMAGE set)."
exit 0
