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
#
# Release image: RELEASE=1 (in the environment, or RELEASE=1 in the local
# configuration; template release.conf.example). It sets
# BR2_PACKAGE_GT_BE98_OS_RELEASE, and the build refuses every lab secret or
# lab address of the local configuration (package/gt-be98-os/apply-local-conf.sh,
# post-image.sh). Use a separate OUT for it, then check the result:
#   RELEASE=1 GT_BE98_LOCAL_CONF=~/.config/gt-be98-os/release.conf rtk sh build.sh
#   sh board/gt-be98-mainline/release-check.sh -f <lab patterns> $OUT/images
# --print-config: only write the configuration fragment build.sh would merge
# (to stdout) and exit; no Buildroot call.
set -eu
HERE=$(cd "$(dirname "$0")" && pwd)
EXT=$(cd "$HERE/../.." && pwd)
CONF=${GT_BE98_LOCAL_CONF:-$HOME/.config/gt-be98-os/local.conf}
[ -f "$CONF" ] || { echo "no local configuration $CONF (see $HERE/local.conf.example)"; exit 1; }
REL_ENV=${RELEASE:-}
BR2_SRC= OUT= BR2_DL_DIR= SSH_HOSTKEY_DIR= WEBUI_DIR= RELEASE=
. "$CONF"
# the environment can only turn release mode on, never off
[ "$REL_ENV" = 1 ] && RELEASE=1
case "${RELEASE:-0}" in 0|'') RELEASE=0 ;; 1) ;; *) echo "RELEASE must be 0 or 1"; exit 1 ;; esac
: "${BR2_SRC:?BR2_SRC not set in $CONF}" "${OUT:?OUT not set in $CONF}"
export BR2_DL_DIR

fragment() {
	echo "BR2_PACKAGE_GT_BE98_OS_LOCAL_CONF=\"$CONF\""
	echo "BR2_PACKAGE_GT_BE98_WEBUI_DIR=\"$WEBUI_DIR\""
	if [ "$RELEASE" = 1 ]; then
		echo "BR2_PACKAGE_GT_BE98_OS_RELEASE=y"
	else
		echo "# BR2_PACKAGE_GT_BE98_OS_RELEASE is not set"
	fi
}
if [ "${1:-}" = --print-config ]; then
	fragment
	exit 0
fi

if [ "$RELEASE" = 1 ]; then
	# fail early (apply-local-conf.sh and post-image.sh check again)
	bad=
	for k in SSH_HOSTKEY_DIR WEBUI_PASSWORD WEBUI_PASSWORD_HASH ROOTFS_URL SYSLOG_REMOTE \
		NETCONSOLE RNR0_FALLBACK USB_FALLBACK; do
		eval "v=\${$k:-}"
		[ -z "$v" ] || bad="$bad $k"
	done
	[ -z "$bad" ] || { echo "RELEASE=1: these keys of $CONF must be empty:$bad"; exit 1; }
	echo "build.sh: RELEASE=1 (no host keys, no web UI password, no lab addresses) -> $OUT"
fi

# stable ssh host keys, outside git (lab builds only)
if [ "$RELEASE" = 0 ] && [ -n "$SSH_HOSTKEY_DIR" ] && [ ! -f "$SSH_HOSTKEY_DIR/ssh_host_ed25519_key" ]; then
	mkdir -p "$SSH_HOSTKEY_DIR"; chmod 700 "$SSH_HOSTKEY_DIR"
	for t in ed25519 ecdsa rsa; do
		ssh-keygen -q -t $t -N '' -C gt-be98 -f "$SSH_HOSTKEY_DIR/ssh_host_${t}_key"
	done
	echo "generated ssh host keys in $SSH_HOSTKEY_DIR"
fi

mkdir -p "$OUT"
rel_now() { grep -q '^BR2_PACKAGE_GT_BE98_OS_RELEASE=y' "$OUT/.config" && echo 1 || echo 0; }
if [ ! -f "$OUT/.config" ] || [ "$EXT/configs/gt-be98_mainline_defconfig" -nt "$OUT/.config" ] ||
   [ "$CONF" -nt "$OUT/.config" ] || [ "$(rel_now)" != "$RELEASE" ]; then
	make -C "$BR2_SRC" O="$OUT" BR2_EXTERNAL="$EXT" gt-be98_mainline_defconfig
	fragment > "$OUT/gt-be98-local.fragment"
	"$BR2_SRC/support/kconfig/merge_config.sh" -m -O "$OUT" "$OUT/.config" \
		"$OUT/gt-be98-local.fragment" >/dev/null
	make -C "$OUT" olddefconfig >/dev/null
	grep -q "^BR2_PACKAGE_GT_BE98_OS_LOCAL_CONF=\"$CONF\"" "$OUT/.config"
	[ "$(rel_now)" = "$RELEASE" ] || { echo "BR2_PACKAGE_GT_BE98_OS_RELEASE did not take in $OUT/.config"; exit 1; }
fi
exec make -C "$OUT" "$@"
