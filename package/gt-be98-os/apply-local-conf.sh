#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# Apply the lab-specific values of the local configuration file to the
# rootfs (gt-be98-os target-finalize hook). Nothing lab-specific is in git:
# keys, addresses and host names come only from $GT_BE98_LOCAL_CONF.
#
# Keys used here (all optional):
#   SSH_AUTHORIZED_KEYS  file of public keys for root (one per line)
#   SSH_HOSTKEY_DIR      directory with ssh_host_{ed25519,ecdsa,rsa}_key[.pub]
#                        (stable host keys across rebuilds and reboots;
#                        build.sh creates it). Empty: new keys every boot.
#   TELNET_LIFELINE      auto (default: enabled only without an SSH key),
#                        yes, no
#   RNR0_FALLBACK        A.B.C.D/NN: static address dhcpcd falls back to on
#                        rnr0 when no DHCP server answers
#   USB_FALLBACK         the same for the USB lifeline
#   SYSLOG_REMOTE        host[:port]: forward all logs (UDP)
#   WEBUI_PASSWORD       web UI admin password (>= 6 characters), or
#   WEBUI_PASSWORD_HASH  SALT:HASH as the webui stores it (HASH =
#                        sha256(SALT || password), hex). Either one writes
#                        /etc/webui/auth.conf and ENABLES the webui service;
#                        neither: the webui stays disabled (never first-run
#                        open setup on the LAN).
set -eu
: "${TARGET_DIR:?}"
CONF=${GT_BE98_LOCAL_CONF:-}
SSH_AUTHORIZED_KEYS=
SSH_HOSTKEY_DIR=
TELNET_LIFELINE=auto
RNR0_FALLBACK=
USB_FALLBACK=
SYSLOG_REMOTE=
WEBUI_PASSWORD=
WEBUI_PASSWORD_HASH=
if [ -n "$CONF" ]; then
	[ -f "$CONF" ] || { echo "gt-be98-os: local configuration $CONF missing" >&2; exit 1; }
	. "$CONF"
fi
warn() { echo "gt-be98-os: WARNING: $*" >&2; }

# root: no password login at all (sshd keys only; "*" is not "locked" for sshd)
if [ -f "$TARGET_DIR/etc/shadow" ]; then
	sed -i 's/^root:[^:]*:/root:*:/' "$TARGET_DIR/etc/shadow"
fi

# --- SSH authorized keys ----------------------------------------------------------
AK=$TARGET_DIR/etc/ssh/authorized_keys/root
mkdir -p "$TARGET_DIR/etc/ssh/authorized_keys"
rm -f "$AK"
nkeys=0
if [ -n "$SSH_AUTHORIZED_KEYS" ]; then
	[ -f "$SSH_AUTHORIZED_KEYS" ] || { echo "gt-be98-os: $SSH_AUTHORIZED_KEYS missing" >&2; exit 1; }
	grep -E '^(ssh-|ecdsa-|sk-)' "$SSH_AUTHORIZED_KEYS" > "$AK" || true
	nkeys=$(wc -l < "$AK")
	chmod 0644 "$AK"
fi
[ "$nkeys" -gt 0 ] || { warn "no SSH authorized key: ssh login impossible"; rm -f "$AK"; }

# --- SSH host keys ----------------------------------------------------------------
rm -f "$TARGET_DIR"/etc/ssh/ssh_host_*
if [ -n "$SSH_HOSTKEY_DIR" ]; then
	for t in ed25519 ecdsa rsa; do
		k=$SSH_HOSTKEY_DIR/ssh_host_${t}_key
		[ -f "$k" ] && [ -f "$k.pub" ] || { warn "$k missing"; continue; }
		install -m 0600 "$k" "$TARGET_DIR/etc/ssh/ssh_host_${t}_key"
		install -m 0644 "$k.pub" "$TARGET_DIR/etc/ssh/ssh_host_${t}_key.pub"
	done
else
	warn "no SSH_HOSTKEY_DIR: sshd generates new host keys at every boot"
fi

# --- telnet lifeline --------------------------------------------------------------
RL=$TARGET_DIR/etc/runlevels/default
rm -f "$RL/gt-be98-telnet"
case "$TELNET_LIFELINE" in
yes) en=1 ;;
no) en=0 ;;
*) [ "$nkeys" -gt 0 ] && en=0 || en=1 ;;
esac
if [ $en = 1 ]; then
	ln -s /etc/init.d/gt-be98-telnet "$RL/gt-be98-telnet"
	warn "gt-be98-telnet enabled: passwordless root telnet on the USB lifeline"
fi

# --- dhcpcd static fallbacks ------------------------------------------------------
DC=$TARGET_DIR/etc/dhcpcd.conf
sed -i '/^# --- local fallbacks/,$d' "$DC"
valid_cidr() { echo "$1" | grep -qE '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$'; }
if [ -n "$RNR0_FALLBACK$USB_FALLBACK" ]; then
	echo "# --- local fallbacks (build time, local configuration) ---" >> "$DC"
	if [ -n "$RNR0_FALLBACK" ]; then
		valid_cidr "$RNR0_FALLBACK" || { echo "RNR0_FALLBACK: A.B.C.D/NN" >&2; exit 1; }
		printf 'profile fb_rnr0\nstatic ip_address=%s\n\ninterface rnr0\nfallback fb_rnr0\n\n' \
			"$RNR0_FALLBACK" >> "$DC"
	fi
	if [ -n "$USB_FALLBACK" ]; then
		valid_cidr "$USB_FALLBACK" || { echo "USB_FALLBACK: A.B.C.D/NN" >&2; exit 1; }
		for i in eth0 usb0; do
			printf 'profile fb_%s\nstatic ip_address=%s\n\ninterface %s\nfallback fb_%s\n\n' \
				"$i" "$USB_FALLBACK" "$i" "$i" >> "$DC"
		done
	fi
fi

# --- remote syslog ----------------------------------------------------------------
rm -f "$TARGET_DIR/etc/syslog.d/60-remote.conf"
if [ -n "$SYSLOG_REMOTE" ]; then
	echo "*.*	@$SYSLOG_REMOTE" > "$TARGET_DIR/etc/syslog.d/60-remote.conf"
fi
# --- web UI password -> /etc/webui/auth.conf, enable the service -------------------
AUTH=$TARGET_DIR/etc/webui/auth.conf
rm -f "$AUTH" "$RL/webui"
webui=no
if [ -x "$TARGET_DIR/usr/sbin/webui" ]; then
	salt= hash=
	if [ -n "$WEBUI_PASSWORD_HASH" ]; then
		salt=${WEBUI_PASSWORD_HASH%%:*}; hash=${WEBUI_PASSWORD_HASH#*:}
		echo "$hash" | grep -qE '^[0-9a-f]{64}$' && [ -n "$salt" ] && [ "$salt" != "$WEBUI_PASSWORD_HASH" ] ||
			{ echo "WEBUI_PASSWORD_HASH: SALT:HASH (HASH = 64 hex)" >&2; exit 1; }
	elif [ -n "$WEBUI_PASSWORD" ]; then
		[ ${#WEBUI_PASSWORD} -ge 6 ] || { echo "WEBUI_PASSWORD: at least 6 characters" >&2; exit 1; }
		salt=$(head -c 16 /dev/urandom | od -An -tx1 | tr -d ' \n')
		hash=$(printf '%s%s' "$salt" "$WEBUI_PASSWORD" | sha256sum | cut -d' ' -f1)
	fi
	if [ -n "$hash" ]; then
		mkdir -p "$TARGET_DIR/etc/webui"
		( umask 077; printf 'SALT=%s\nHASH=%s\n' "$salt" "$hash" > "$AUTH" )
		ln -s /etc/init.d/webui "$RL/webui"
		webui=enabled
	else
		webui="installed, disabled (no WEBUI_PASSWORD)"
	fi
fi
echo "gt-be98-os: local configuration applied (keys: $nkeys, telnet: $en, webui: $webui)"
