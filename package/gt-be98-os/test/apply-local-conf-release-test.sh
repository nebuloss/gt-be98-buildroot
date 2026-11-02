#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# Host test of package/gt-be98-os/apply-local-conf.sh, release mode against
# lab mode, on a fake target tree (no Buildroot, no root):
#   sh package/gt-be98-os/test/apply-local-conf-release-test.sh
# Every release refusal has a lab twin that must still be accepted, and the
# release result is checked with board/gt-be98-mainline/release-check.sh.
set -u
here=$(cd "$(dirname "$0")" && pwd)
A=$here/../apply-local-conf.sh
RC=$here/../../../board/gt-be98-mainline/release-check.sh
T=$(mktemp -d)
trap 'rm -rf "${T:?}"' EXIT
pass=0 fail=0
ok() { pass=$((pass + 1)); echo "ok   $*"; }
ko() { fail=$((fail + 1)); echo "FAIL $*"; }

# lab material, generated here (test values only)
mkdir -p "$T/hk"
for t in ed25519 ecdsa rsa; do
	printf '%s\n' '-----BEGIN OPENSSH PRIVATE KEY-----' test '-----END OPENSSH PRIVATE KEY-----' > "$T/hk/ssh_host_${t}_key"
	echo "ssh-$t AAAAtesthostkey$t root@testhost" > "$T/hk/ssh_host_${t}_key.pub"
done
echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItestrecipientkey tester@testlaptop' > "$T/ak"

target() {	# fresh fake target dir in $TD
	TD=$T/target
	rm -rf "$TD"
	mkdir -p "$TD/etc/ssh" "$TD/etc/conf.d" "$TD/etc/runlevels/default" "$TD/etc/syslog.d" "$TD/usr/sbin" "$TD/etc/webui"
	echo 'root:x:0:0::/root:/bin/sh' > "$TD/etc/passwd"
	echo 'root::19000:0:99999:7:::' > "$TD/etc/shadow"
	echo 'hostname' > "$TD/etc/dhcpcd.conf"
	printf 'NETCONSOLE="@/rnr0,6666@192.0.2.5/"\nNETCONSOLE_WAIT=30\n' > "$TD/etc/conf.d/gt-be98-netconsole"
	printf '#!/bin/sh\n# webui build with the setup-token feature\n' > "$TD/usr/sbin/webui"
	chmod +x "$TD/usr/sbin/webui"
	echo 'release-mode yes' > "$TD/etc/gt-be98-release"
}
conf() {	# KEY=VALUE... -> $T/conf
	: > "$T/conf"
	for kv in "$@"; do echo "$kv" >> "$T/conf"; done
}
run() {	# release(y|"") -> rc
	GT_BE98_LOCAL_CONF=$T/conf TARGET_DIR=$TD HOST_DIR=/nonexistent GT_BE98_RELEASE=$1 \
		sh "$A" > "$T/out" 2>&1
}

# 1. each lab key: refused in release, accepted in lab mode
for kv in "SSH_HOSTKEY_DIR=$T/hk" "WEBUI_PASSWORD=secret123" \
	"WEBUI_PASSWORD_HASH=ab:0123456789012345678901234567890123456789012345678901234567890abc" \
	"SYSLOG_REMOTE=192.0.2.9" "NETCONSOLE=@/rnr0,6666@192.0.2.9/" \
	"RNR0_FALLBACK=192.0.2.10/24" "USB_FALLBACK=192.0.2.11/24"; do
	k=${kv%%=*}
	target; conf "SSH_AUTHORIZED_KEYS=$T/ak" "$kv"
	if run y; then ko "release accepted $k"; else
		grep -q "must be empty in a release image: $k" "$T/out" && ok "release refuses $k" || ko "release refused $k without naming it: $(cat "$T/out")"
	fi
	target; conf "SSH_AUTHORIZED_KEYS=$T/ak" "$kv"
	run "" && ok "lab mode accepts $k" || ko "lab mode refused $k: $(cat "$T/out")"
done

# 2. lab build: host keys and the hash are baked in (the reason for release mode)
target; conf "SSH_AUTHORIZED_KEYS=$T/ak" "SSH_HOSTKEY_DIR=$T/hk" "WEBUI_PASSWORD=secret123"
run ""
[ -f "$TD/etc/ssh/ssh_host_ed25519_key" ] && ok "lab: host keys installed" || ko "lab: no host keys"
[ -f "$TD/etc/webui/auth.conf" ] && ok "lab: auth.conf written" || ko "lab: no auth.conf"
grep -q 'tester@testlaptop' "$TD/etc/ssh/authorized_keys/root" && ok "lab: key comment kept" || ko "lab: key comment dropped"

# 3. release build, clean configuration, over a target that held lab files
target
cp "$T/hk/ssh_host_rsa_key" "$TD/etc/ssh/"
echo 'HASH=0123456789012345678901234567890123456789012345678901234567890abc' > "$TD/etc/webui/auth.conf"
printf '*.*\t@192.0.2.9\n' > "$TD/etc/syslog.d/60-remote.conf"
conf "SSH_AUTHORIZED_KEYS=$T/ak"
if run y; then ok "release: clean configuration accepted"; else ko "release refused a clean configuration: $(cat "$T/out")"; fi
ls "$TD"/etc/ssh/ssh_host_* >/dev/null 2>&1 && ko "release: host keys left in the target" || ok "release: no host keys"
[ -e "$TD/etc/webui/auth.conf" ] && ko "release: auth.conf left" || ok "release: no auth.conf"
[ -e "$TD/etc/syslog.d/60-remote.conf" ] && ko "release: remote syslog left" || ok "release: no remote syslog"
grep -q '^NETCONSOLE=$' "$TD/etc/conf.d/gt-be98-netconsole" && ok "release: NETCONSOLE of an earlier build reset" || ko "release: NETCONSOLE kept: $(grep ^NETCONSOLE= "$TD/etc/conf.d/gt-be98-netconsole")"
[ "$(cat "$TD/etc/ssh/authorized_keys/root")" = 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAItestrecipientkey' ] &&
	ok "release: authorized key without its comment" || ko "release: authorized_keys = $(cat "$TD/etc/ssh/authorized_keys/root")"
[ -L "$TD/etc/runlevels/default/webui" ] && [ -L "$TD/etc/runlevels/default/gt-be98-webui-guard" ] &&
	ok "release: webui + guard enabled without a password" || ko "release: webui not enabled"
grep -q 'first login: setup token' "$T/out" && ok "release: says how the first login works" || ko "release: no first-login line"
grep -q 'no setup token' "$T/out" && ko "release: warned about a webui that has the token" || ok "release: no false warning about the webui"
# a webui without the token feature: still enabled (the guard refuses it at
# boot), but the build says so
target; printf '#!/bin/sh\n' > "$TD/usr/sbin/webui"; conf "SSH_AUTHORIZED_KEYS=$T/ak"; run y
grep -q 'no first-login setup token' "$T/out" && ok "release: warns about a webui without the token" || ko "release: no warning for an old webui"

# 4. the release target passes release-check; the lab target does not
target; conf "SSH_AUTHORIZED_KEYS=$T/ak"; run y
sh "$RC" -u tester -s testhost "$TD" > "$T/rc.out" 2>&1 && ok "release target passes release-check" || { ko "release target fails release-check"; cat "$T/rc.out"; }
target; conf "SSH_AUTHORIZED_KEYS=$T/ak" "SSH_HOSTKEY_DIR=$T/hk" "WEBUI_PASSWORD=secret123"; run ""
sh "$RC" -u tester -s testhost "$TD" > "$T/rc.out" 2>&1
[ $? = 1 ] && grep -q '^FAIL HOSTKEY' "$T/rc.out" && grep -q '^FAIL PWHASH' "$T/rc.out" &&
	grep -q '^FAIL AKCOMMENT' "$T/rc.out" && ok "lab target fails release-check (HOSTKEY, PWHASH, AKCOMMENT)" ||
	{ ko "lab target not refused by release-check"; cat "$T/rc.out"; }

echo "apply-local-conf release test: $pass passed, $fail failed"
[ $fail = 0 ]
