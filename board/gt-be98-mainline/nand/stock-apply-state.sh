#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# Store a mainline OS state archive in the STOCK /jffs (run from the lab
# host while the box runs the stock firmware; stock writes its own /jffs).
#
#   ssh root@<box-mainline> gt-be98-save > state.tgz      (on mainline)
#   sh stock-apply-state.sh state.tgz <user@stock> [port]  (box on stock)
#
# Result on stock: /jffs/mainline-os/state.tgz + state.tgz.sha256, read at
# the next mainline boot by the gt-be98-jffs service (read-only). The
# archive holds SSH host private keys and the web UI password hash: the
# directory is made 0700 and the files 0600 (root only) on stock.
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
	umask 077
	mkdir -p /jffs/mainline-os
	chmod 0700 /jffs/mainline-os
	[ -f /jffs/mainline-os/state.tgz ] && cp /jffs/mainline-os/state.tgz /jffs/mainline-os/state.tgz.prev
	cp /tmp/mainline-state.tgz /jffs/mainline-os/state.tgz.new
	chmod 0600 /jffs/mainline-os/state.tgz.new
	mv /jffs/mainline-os/state.tgz.new /jffs/mainline-os/state.tgz
	echo '$SUM  state.tgz' > /jffs/mainline-os/state.tgz.sha256
	chmod 0600 /jffs/mainline-os/* 2>/dev/null
	chmod 0700 /jffs/mainline-os/overlay 2>/dev/null || true
	sync
	rm -f /tmp/mainline-state.tgz
	ls -la /jffs/mainline-os"
echo "stored: /jffs/mainline-os/state.tgz ($SUM)"
