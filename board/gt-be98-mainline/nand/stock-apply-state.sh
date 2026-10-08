#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# Store a mainline OS state archive in the STOCK /jffs (run from the lab
# host while the box runs the stock firmware; stock writes its own /jffs).
#
#   ssh root@<box-mainline> gt-be98-save > state.tgz      (on mainline)
#   sh stock-apply-state.sh state.tgz <user@stock> [port]  (box on stock)
#
# Result on stock: /jffs/mainline-os/state.tgz + state.tgz.sha256, read at
# the next mainline boot by the gt-be98-jffs service (read-only).
set -eu
ARCHIVE=${1:?usage: stock-apply-state.sh state.tgz user@stock [port]}
STOCK=${2:?user@stock}
PORT=${3:-22}
[ -f "$ARCHIVE" ] || { echo "no $ARCHIVE"; exit 1; }
tar -tzf "$ARCHIVE" >/dev/null || { echo "$ARCHIVE is not a tar.gz"; exit 1; }
SUM=$(sha256sum "$ARCHIVE" | cut -d' ' -f1)
SSH="ssh -p $PORT -o ConnectTimeout=10 $STOCK"
# never on a mainline-booted box: stock's /proc/cmdline has ubi.block
$SSH 'grep -q "ubi.block=" /proc/cmdline' || { echo "target is not running the stock firmware"; exit 1; }
$SSH 'cat > /tmp/mainline-state.tgz' < "$ARCHIVE"
$SSH "set -e
	[ \"\$(sha256sum /tmp/mainline-state.tgz | cut -d' ' -f1)\" = $SUM ]
	grep -q ' /jffs ' /proc/mounts
	mkdir -p /jffs/mainline-os
	[ -f /jffs/mainline-os/state.tgz ] && cp /jffs/mainline-os/state.tgz /jffs/mainline-os/state.tgz.prev
	cp /tmp/mainline-state.tgz /jffs/mainline-os/state.tgz.new
	mv /jffs/mainline-os/state.tgz.new /jffs/mainline-os/state.tgz
	echo '$SUM  state.tgz' > /jffs/mainline-os/state.tgz.sha256
	sync
	rm -f /tmp/mainline-state.tgz
	ls -la /jffs/mainline-os"
echo "stored: /jffs/mainline-os/state.tgz ($SUM)"
