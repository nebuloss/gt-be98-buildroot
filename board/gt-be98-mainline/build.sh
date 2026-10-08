#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# Build the GT-BE98 mainline OS on the build host.
#
#   board/gt-be98-mainline/build.sh [make targets...]
#
# Reads the local configuration ($GT_BE98_LOCAL_CONF, default
# ~/.config/gt-be98-os/local.conf; template local.conf.example), configures
# $OUT with gt-be98_mainline_defconfig plus the local values, and runs make.
# Without targets: the full build; result $OUT/images/ml-bootfs.itb.
# Run long builds through rtk on the build host:  rtk sh build.sh
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
EXT=$(cd "$HERE/../.." && pwd)
CONF=${GT_BE98_LOCAL_CONF:-$HOME/.config/gt-be98-os/local.conf}
[ -f "$CONF" ] || { echo "no local configuration $CONF (see $HERE/local.conf.example)"; exit 1; }
BR2_SRC= OUT= BR2_DL_DIR= SSH_HOSTKEY_DIR= WEBUI_DIR=
. "$CONF"
: "${BR2_SRC:?BR2_SRC not set in $CONF}" "${OUT:?OUT not set in $CONF}"
export BR2_DL_DIR

# stable ssh host keys, outside git
if [ -n "$SSH_HOSTKEY_DIR" ] && [ ! -f "$SSH_HOSTKEY_DIR/ssh_host_ed25519_key" ]; then
	mkdir -p "$SSH_HOSTKEY_DIR"; chmod 700 "$SSH_HOSTKEY_DIR"
	for t in ed25519 ecdsa rsa; do
		ssh-keygen -q -t $t -N '' -C gt-be98 -f "$SSH_HOSTKEY_DIR/ssh_host_${t}_key"
	done
	echo "generated ssh host keys in $SSH_HOSTKEY_DIR"
fi

mkdir -p "$OUT"
if [ ! -f "$OUT/.config" ] || [ "$EXT/configs/gt-be98_mainline_defconfig" -nt "$OUT/.config" ] ||
   [ "$CONF" -nt "$OUT/.config" ]; then
	make -C "$BR2_SRC" O="$OUT" BR2_EXTERNAL="$EXT" gt-be98_mainline_defconfig
	{
		echo "BR2_PACKAGE_GT_BE98_OS_LOCAL_CONF=\"$CONF\""
		echo "BR2_PACKAGE_GT_BE98_WEBUI_DIR=\"$WEBUI_DIR\""
	} > "$OUT/gt-be98-local.fragment"
	"$BR2_SRC/support/kconfig/merge_config.sh" -m -O "$OUT" "$OUT/.config" \
		"$OUT/gt-be98-local.fragment" >/dev/null
	make -C "$OUT" olddefconfig >/dev/null
	grep -q "^BR2_PACKAGE_GT_BE98_OS_LOCAL_CONF=\"$CONF\"" "$OUT/.config"
fi
exec make -C "$OUT" "$@"
