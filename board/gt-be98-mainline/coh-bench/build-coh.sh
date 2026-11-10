#!/bin/bash
# build-coh.sh : the IO-coherent PCIe BENCH image (D31), on dev-build. Lane tx-cpu. NOT a Buildroot output tree: a 14 GB
#   second output does not fit, so this rebuilds only what differs from img39 and reuses img39's host tools (read-only):
#     kernel   = pristine 7.2.9 + board patches + img39's combined open-ethernet series (a9960de) + 0990/0991 (bench)
#                with img39's .config (only CONFIG_INITRAMFS_SOURCE points at this build's NAND=off initramfs)
#     modules  = all in-tree modules + bca_pcie_ipc (open-wifi b2a70da3) + bcm4916-runner + rtl8372 (open-ethernet
#                a9960de), rebuilt against THIS kernel with img39's exact make lines
#     rootfs   = img39's rootfs.squashfs, /lib/modules replaced, RUNNER_ARGS += cci_snoop=1; repacked under fakeroot
#     DTB      = img39's gt-be98-os.dts + the bench overlay (dma-coherent on &pcie0..3 with brcm,ubus-master/cci/cci-cpu-si,
#                &runner dma-coherent); NAND=off (no ML_NAND_RO: no NAND node)
#     FIT      = mkbootfs.py with the stock bootfs, as post-image.sh
# Nothing in ~/os-build or ~/orch/os/img39 is written. Output: ~/orch/os/img-coh (+ SHA256SUMS, KCONFIG.sha256, info).
set -euo pipefail
C=$HOME/orch/lanes/coh; K=$C/linux-7.2.9; O=$C/out; OUT=$HOME/orch/os/img-coh
MO=$HOME/os-build/out-mainline; H=$MO/host; IMG39=$HOME/orch/os/img39
export TMPDIR=$C/tmp; mkdir -p "$TMPDIR" "$O" "$OUT"
XC="$H/bin/aarch64-buildroot-linux-gnu-"
MK=(rtk make -j12 ARCH=arm64 CROSS_COMPILE="$XC" KCFLAGS=-Wno-attribute-alias WERROR=0 HOSTCC="/usr/bin/gcc -O2 -isystem $H/include -L$H/lib -Wl,-rpath,$H/lib")
# the bench rootfs is served next to the image one: <ROOTFS_URL of the base conf> with /os/ -> /os-coh/
BASE_CONF=${BASE_CONF:-$HOME/.config/gt-be98-os/img39.conf}
URL=$(sed -n 's/^ROOTFS_URL=//p' "$BASE_CONF" | tr -d '"' | sed 's#/os/#/os-coh/#')
case "$URL" in http://*/os-coh/*) ;; *) echo "cannot derive the bench ROOTFS_URL from $BASE_CONF"; exit 1 ;; esac
OEV=a9960de5dfead2e62b4f3d8461142ad5b4264d92; OWV=b2a70da3267712111c51d70f3311b1bb1d37e28d
step() { echo "== $(date +%T) $*"; }

step "1. initramfs (NAND=off: no UBI keys; ROOTFS_URL=$URL)"
I=$C/initramfs; rm -rf "$I"; mkdir -p "$I"
printf 'WDT_MAX=%s\nRESCUE=%s\nROOTFS_URL=%s\n' 600 0 "$URL" > "$I/ml-defaults"
B=$MO/images
cat > "$I/list" <<EOF
dir /dev 0755 0 0
nod /dev/console 0600 0 0 c 5 1
nod /dev/null 0666 0 0 c 1 3
nod /dev/kmsg 0644 0 0 c 1 11
dir /proc 0755 0 0
dir /sys 0755 0 0
dir /tmp 1777 0 0
dir /root 0700 0 0
dir /etc 0755 0 0
dir /bin 0755 0 0
dir /sbin 0755 0 0
dir /usr 0755 0 0
dir /usr/bin 0755 0 0
dir /usr/sbin 0755 0 0
dir /mnt 0755 0 0
dir /lib 0755 0 0
file /bin/busybox $B/rescue/busybox 0755 0 0
slink /bin/sh busybox 0777 0 0
file /init $B/rescue/init 0755 0 0
file /etc/udhcpc.script $B/rescue/udhcpc.script 0755 0 0
file /etc/ml-defaults $I/ml-defaults 0644 0 0
dir /lib/firmware 0755 0 0
file /lib/firmware/regulatory.db $MO/target/lib/firmware/regulatory.db 0644 0 0
file /lib/firmware/regulatory.db.p7s $MO/target/lib/firmware/regulatory.db.p7s 0644 0 0
EOF

step "2. kernel config = img39's + this initramfs"
cp "$MO/build/linux-7.2.9/.config" "$O/.config"
sed -i "s#^CONFIG_INITRAMFS_SOURCE=.*#CONFIG_INITRAMFS_SOURCE=\"$I/list\"#" "$O/.config"
"${MK[@]}" -C "$K" O="$O" olddefconfig >/dev/null
diff <(grep -v INITRAMFS_SOURCE "$MO/build/linux-7.2.9/.config") <(grep -v INITRAMFS_SOURCE "$O/.config") >/dev/null \
	|| { echo "CONFIG DRIFT vs img39 beyond INITRAMFS_SOURCE"; exit 1; }
sha256sum "$O/.config" | cut -d' ' -f1 > "$C/KCONFIG.sha256"	# push-ko.sh convention: sha256 of zcat /proc/config.gz
echo "  KCONFIG $(cut -c1-12 "$C/KCONFIG.sha256"); img39 differs only in CONFIG_INITRAMFS_SOURCE"

step "3. kernel Image + in-tree modules"
"${MK[@]}" -C "$K" O="$O" Image modules
rm -rf "$C/modroot"; mkdir -p "$C/modroot"
"${MK[@]}" -C "$K" O="$O" INSTALL_MOD_PATH="$C/modroot" INSTALL_MOD_STRIP=1 DEPMOD=true modules_install >/dev/null

step "4. out-of-tree modules against this kernel (img39's make lines; sources copied, never built in ~/os-build)"
S=$C/src; rm -rf "$S"; mkdir -p "$S"
cp -a "$MO/build/gt-be98-open-wifi-$OWV" "$S/ow"; cp -a "$MO/build/gt-be98-open-ethernet-$OEV" "$S/oe"
for M in "$S/ow/driver" "$S/oe/driver/runner" "$S/oe/driver/rtl8372"; do
	"${MK[@]}" -C "$O" PWD="$M" M="$M" clean >/dev/null 2>&1 || true
	"${MK[@]}" -C "$O" PWD="$M" M="$M" modules
	"${MK[@]}" -C "$O" PWD="$M" M="$M" INSTALL_MOD_PATH="$C/modroot" INSTALL_MOD_STRIP=1 DEPMOD=true modules_install >/dev/null
done
"$H/sbin/depmod" -b "$C/modroot" 7.2.9
n_in=$(find "$C/modroot/lib/modules/7.2.9/kernel" -name '*.ko' | wc -l); n_up=$(find "$C/modroot/lib/modules/7.2.9/updates" -name '*.ko' | wc -l)
echo "  modules: in-tree $n_in (img39 37), updates $n_up (img39 3)"
[ "$n_in" = 37 ] && [ "$n_up" = 3 ] || { echo "MODULE COUNT differs from img39"; exit 1; }

step "5. rootfs = img39's, /lib/modules replaced, RUNNER_ARGS += cci_snoop=1 (one fakeroot session: owners kept)"
R=$C/rootfs; rm -rf "$R" "$C/rootfs.squashfs"
"$H/bin/fakeroot" -- sh -c "
	set -e
	'$H/bin/unsquashfs' -q -d '$R' '$IMG39/rootfs.squashfs'
	rm -rf '$R/lib/modules/7.2.9'
	cp -a '$C/modroot/lib/modules/7.2.9' '$R/lib/modules/7.2.9'
	chown -R 0:0 '$R/lib/modules/7.2.9'
	sed -i 's/^RUNNER_ARGS=\"/RUNNER_ARGS=\"cci_snoop=1 /' '$R/etc/conf.d/gt-be98-drivers'
	grep -q '^RUNNER_ARGS=\"cci_snoop=1 ' '$R/etc/conf.d/gt-be98-drivers'
	'$H/bin/mksquashfs' '$R' '$C/rootfs.squashfs' -noappend -comp xz -b 1048576 -no-progress -quiet
"
"$H/bin/unsquashfs" -lln "$C/rootfs.squashfs" | awk '$2 !~ /^0\/0$/' | sed 's/^/  non-root kept: /'
rm -rf "$R"

step "6. DTB: img39's gt-be98-os.dts + the bench overlay, NAND=off"
D=$C/dt; rm -rf "$D"; mkdir -p "$D"; SHARE=$H/share/gt-be98-mainline/mainline-boot
cp "$B/dt/gt-be98-os.dts" "$B/dt/mlboot-bootargs.h" "$D/"
cat >> "$D/gt-be98-os.dts" <<'EOF'

/* GT-BE98 coherency BENCH (D31): IO-coherent PCIe on all four RCs + the Runner; NAND stays out (NAND=off: no node).
 * pcie-brcmstb (patch 0991) enables the CCI-500 CPU snoop and this core's UBUS master cache bits at probe, after
 * power-on and before the bus scan, only because the node is dma-coherent. */
&pcie0 { dma-coherent; brcm,ubus-master = <0x83030000>; brcm,cci = <0x81100000>; brcm,cci-cpu-si = <1>; };
&pcie1 { dma-coherent; brcm,ubus-master = <0x83038000>; brcm,cci = <0x81100000>; brcm,cci-cpu-si = <1>; };
&pcie2 { dma-coherent; brcm,ubus-master = <0x83040000>; brcm,cci = <0x81100000>; brcm,cci-cpu-si = <1>; };
&pcie3 { dma-coherent; brcm,ubus-master = <0x83048000>; brcm,cci = <0x81100000>; brcm,cci-cpu-si = <1>; };
EOF
"$H/bin/lzop" -f -c "$O/arch/arm64/boot/Image" > "$C/Image.lzo"
BUILD_ID="$(date -u +%Y%m%dT%H%M%SZ)-$(sha256sum "$C/Image.lzo" | cut -c1-12)-cohbench"
cpp -nostdinc -undef -D__DTS__ -DML_USB -DML_PCIE -DML_PCIE_ALL -DML_MPM_SIZE=0x10000000 -DML_DMA_COHERENT \
	"-DML_BUILD_ID=\"$BUILD_ID\"" -x assembler-with-cpp \
	-I "$D" -I "$SHARE" -I "$K/arch/arm64/boot/dts/broadcom/bcmbca" \
	-I "$K/scripts/dtc/include-prefixes" -I "$K/include" "$D/gt-be98-os.dts" > "$D/gt-be98-os.dts.pre"
"$H/bin/dtc" -q -I dts -O dtb -o "$C/gt-be98-os.dtb" "$D/gt-be98-os.dts.pre"
"$H/bin/dtc" -q -I dtb -O dts "$C/gt-be98-os.dtb" > "$D/check.dts"
nc=$(grep -c 'dma-coherent' "$D/check.dts"); nn=$(grep -c 'brcm,nand-ecc-use-strap' "$D/check.dts" || true)
grep -q 'brcm,bcm6345-wdt' "$D/check.dts" || { echo "DTB has no watchdog"; exit 1; }
echo "  DTB: dma-coherent nodes $nc (want 5: pcie0-3 + runner), NAND node strap lines $nn (want 0)"
[ "$nc" = 5 ] && [ "$nn" = 0 ] || { echo "DTB coherency/NAND check FAILED"; exit 1; }

step "7. FIT (mkbootfs.py, the stock bootfs) and the output"
# the conf is a shell file post-image.sh SOURCES ($HOME etc. expand there): source it the same way
STOCK_BOOTFS=$( . "${BASE_CONF:-$HOME/.config/gt-be98-os/img39.conf}"; printf '%s' "$STOCK_BOOTFS" )
[ -f "$STOCK_BOOTFS" ] || { echo "STOCK_BOOTFS missing: $STOCK_BOOTFS"; exit 1; }
export PATH="$H/bin:$H/sbin:$PATH"	# as post-image.sh: dumpimage/mkimage from the host tools
rm -rf "$C/fit"; python3 "$SHARE/mkbootfs.py" "$STOCK_BOOTFS" "$C/Image.lzo" "$C/gt-be98-os.dtb" "$C/ml-bootfs.itb" "$C/fit" >/dev/null
fsz=$(stat -c %s "$C/ml-bootfs.itb"); isz=$(od -A n -t u8 -j 16 -N 8 "$O/arch/arm64/boot/Image" | tr -d ' ')
[ "$fsz" -lt 16777216 ] && [ "$isz" -lt $((0x2000000 - 0x200000)) ] || { echo "SIZE limits exceeded (FIT $fsz, image_size $isz)"; exit 1; }
cp "$C/ml-bootfs.itb" "$C/rootfs.squashfs" "$O/arch/arm64/boot/Image" "$C/gt-be98-os.dtb" "$OUT/"
cp "$C/KCONFIG.sha256" "$OUT/"; (cd "$OUT" && sha256sum rootfs.squashfs > rootfs.squashfs.sha256)
{
	echo "GT-BE98 coherency BENCH image (D31) — NOT a release; built $(date -u +%FT%TZ)"
	echo "base: img39 (buildroot 0a1bbcf, open-wifi $OWV, open-ethernet $OEV) + open-ethernet series.coh-bench 0990 0991"
	echo "NAND=off (no NAND node); ROOTFS_URL=$URL (serve rootfs.squashfs + rootfs.squashfs.sha256 there)"
	echo "build id (DT): $BUILD_ID"
	echo "KCONFIG.sha256 (sha256 of the uncompressed .config, as push-ko.sh compares /proc/config.gz): $(cat "$C/KCONFIG.sha256") — img39 differs only in CONFIG_INITRAMFS_SOURCE"
	echo "FIT $fsz B, Image image_size $isz B"
} > "$OUT/coh-bench.info"
(cd "$OUT" && sha256sum ml-bootfs.itb rootfs.squashfs Image gt-be98-os.dtb > SHA256SUMS)
cat "$OUT/coh-bench.info"; cat "$OUT/SHA256SUMS"
step "8. clean the lane build (keep patches + output)"
rm -rf "$O" "$C/src" "$C/modroot" "$C/fit" "$K" "$TMPDIR"
du -sh "$C" "$OUT"; df -h / | tail -1
echo BUILD-COH-OK
