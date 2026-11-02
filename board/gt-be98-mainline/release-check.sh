#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# release-check.sh: refuse a GT-BE98 mainline OS image that carries a lab
# secret or a lab address (docs/RELEASE-BUILD.md).
#
#   release-check.sh [options] TARGET
#   release-check.sh --selftest
#
# TARGET: a Buildroot images directory ($OUT/images: rootfs.squashfs, and
# rescue/ml-defaults, ml-bootfs.info, Image when present), a rootfs.squashfs,
# or an extracted rootfs directory.
#
# Built-in checks (no input needed):
#   HOSTKEY   any ssh_host_* file (private or public host key) in the rootfs
#   PRIVKEY   a text file holding a PEM/OpenSSH PRIVATE KEY block
#   PWHASH    /etc/webui/auth.conf or webui.db, a HASH=<64 hex> line, or a
#             crypt hash in /etc/shadow
#   REMOTE    a remote syslog target, a NETCONSOLE target, a static
#             dhcpcd fallback address
#   AKCOMMENT an authorized_keys line with a comment (user@host)
#   RELMODE   /etc/gt-be98-release does not say "release-mode yes"
#   ROOTFSURL a non-empty ROOTFS_URL in rescue/ml-defaults (the initramfs
#             copy) or ml-bootfs.info (images directory only)
#   HOMEPATH  a build-host home path (/home/<name>/) in any file
# Lab patterns, supplied at run time ONLY (never commit them; derive them
# from the lab harness on the build host):
#   -e ERE      extended regex (repeatable), e.g. a lab IP range
#   -s STRING   fixed string (repeatable), e.g. the lab ROOTFS_URL, a host name
#   -u NAME     a user name, matched as a word (repeatable)
#   -i ADDR     an IPv4 address, matched whole (10.1.1.2 does not match
#               10.1.1.20) (repeatable)
#   -f FILE     one pattern per line: "re:ERE", "fixed:STRING", "user:NAME",
#               "ip:ADDR";
#               a bare line is an ERE; "#" starts a comment
#   -v          also print what matched (the output then contains the lab
#               values: keep it out of commits and reports)
# Every file is scanned, binaries included (grep -a). The pattern text is
# never printed without -v, only its number. The initramfs inside the kernel
# Image is xz-compressed: the check reads its source, rescue/ml-defaults.
#
# Exit: 0 PASS, 1 FAIL (one "FAIL <CHECK> ..." line per finding), 2 usage or
# tool error. Needs unsquashfs ($UNSQUASHFS) for a squashfs target.
set -u

usage() { sed -n '3,/^set -u$/p' "$0" | sed -e '/^set -u$/d' -e 's/^# \{0,1\}//'; exit 2; }

PATS=$(mktemp) || exit 2
cleanup_list="$PATS"
cleanup() { for f in $cleanup_list; do rm -rf "${f:?}"; done; }
trap cleanup EXIT INT TERM
VERBOSE=0

addpat() {	# kind value [source]
	case "$1" in
	re|fixed) printf '%s\t%s\t%s\n' "$1" "${3:-arg}" "$2" >> "$PATS" ;;
	user) printf 're\t%s\t%s\n' "${3:-arg}" "(^|[^A-Za-z0-9_.-])$2([^A-Za-z0-9_-]|\$)" >> "$PATS" ;;
	ip)
		echo "$2" | grep -qE '^[0-9]{1,3}(\.[0-9]{1,3}){3}$' || { echo "release-check: not an IPv4 address: ${3:-arg}" >&2; exit 2; }
		printf 're\t%s\t%s\n' "${3:-arg}" "(^|[^0-9.])$(echo "$2" | sed 's/\./\\./g')([^0-9]|\$)" >> "$PATS" ;;
	esac
}

readpats() {	# file
	[ -r "$1" ] || { echo "release-check: cannot read $1" >&2; exit 2; }
	n=0
	while IFS= read -r line || [ -n "$line" ]; do
		n=$((n + 1))
		case "$line" in ''|'#'*) continue ;; esac
		case "$line" in
		re:*) addpat re "${line#re:}" "$1:$n" ;;
		fixed:*) addpat fixed "${line#fixed:}" "$1:$n" ;;
		user:*) addpat user "${line#user:}" "$1:$n" ;;
		ip:*) addpat ip "${line#ip:}" "$1:$n" ;;
		*) addpat re "$line" "$1:$n" ;;
		esac
	done < "$1"
}

FAILS=0
fail() { FAILS=$((FAILS + 1)); echo "FAIL $*"; }
note() { echo "ok   $*"; }

# list up to 5 files of $@ (relative to $BASE)
rel() { sed "s|^$BASE/||" | head -n 5 | tr '\n' ' '; }

check_root() {	# rootfs dir
	R=$1 BASE=$1
	local f x

	x=$(find "$R" -name 'ssh_host_*' \( -type f -o -type l \) 2>/dev/null | rel)
	[ -z "$x" ] && note "HOSTKEY no ssh_host_* file" || fail "HOSTKEY host key files in the image: $x"

	x=$(grep -rlIE -e '^-----BEGIN ([A-Z0-9]+ )*PRIVATE KEY-----' "$R" 2>/dev/null | rel)
	[ -z "$x" ] && note "PRIVKEY no private key block in a text file" || fail "PRIVKEY private key in: $x"

	x=
	for f in etc/webui/auth.conf etc/webui/webui.db; do [ -e "$R/$f" ] && x="$x $f"; done
	f=$(grep -rlIE -e '^HASH=[0-9a-fA-F]{64}[[:space:]]*$' "$R" 2>/dev/null | rel)
	x="$x $f"
	if [ -f "$R/etc/shadow" ]; then
		f=$(awk -F: '$2 ~ /^\$/ { print $1 }' "$R/etc/shadow" | tr '\n' ' ')
		[ -z "$f" ] || x="$x etc/shadow(users: $f)"
	fi
	x=$(echo $x)
	[ -z "$x" ] && note "PWHASH no password hash" || fail "PWHASH password material: $x"

	x=
	for f in "$R"/etc/syslog.conf "$R"/etc/syslog.d/*; do
		[ -f "$f" ] || continue
		grep -qE '^[^#]*[[:space:]]@' "$f" && x="$x ${f#$R/}"
	done
	f=$R/etc/conf.d/gt-be98-netconsole
	[ -f "$f" ] && grep -qE '^NETCONSOLE=["'\'']?[^"'\''[:space:]]' "$f" && x="$x etc/conf.d/gt-be98-netconsole"
	f=$R/etc/dhcpcd.conf
	[ -f "$f" ] && grep -qE '^[[:space:]]*static[[:space:]]+ip_address=|^# --- local fallbacks' "$f" && x="$x etc/dhcpcd.conf"
	x=$(echo $x)
	[ -z "$x" ] && note "REMOTE no remote syslog, netconsole or static fallback" || fail "REMOTE lab forwarding/address configured in: $x"

	x= n=0
	for f in "$R"/etc/ssh/authorized_keys/* "$R"/root/.ssh/authorized_keys; do
		[ -f "$f" ] || continue
		n=$((n + $(grep -cE '^(ssh-|ecdsa-|sk-)' "$f")))
		awk '/^(ssh-|ecdsa-|sk-)/ && NF > 2 { found = 1 } !/^(ssh-|ecdsa-|sk-|#|$)/ { found = 1 } END { exit !found }' "$f" &&
			x="$x ${f#$R/}"
	done
	x=$(echo $x)
	[ -z "$x" ] && note "AKCOMMENT $n authorized key(s), none with a comment or options" ||
		fail "AKCOMMENT authorized_keys with a comment/options (user@host): $x"

	if grep -qx 'release-mode yes' "$R/etc/gt-be98-release" 2>/dev/null; then
		note "RELMODE built with RELEASE=1"
	else
		fail "RELMODE /etc/gt-be98-release does not say \"release-mode yes\" (not a RELEASE=1 build)"
	fi

	# a path that starts at /home (not e.g. the stock /tmp/home/root)
	x=$(grep -rlaE -e '(^|[^A-Za-z0-9._/-])/home/[A-Za-z0-9._-]+/' "$R" 2>/dev/null | rel)
	[ -z "$x" ] && note "HOMEPATH no /home/<name>/ path" || fail "HOMEPATH build-host home path in: $x"
}

check_extras() {	# images dir
	local d=$1 x=
	BASE=$d
	if [ -f "$d/rescue/ml-defaults" ] && grep -qE '^ROOTFS_URL=.+' "$d/rescue/ml-defaults"; then
		x="$x rescue/ml-defaults"
	fi
	if [ -f "$d/ml-bootfs.info" ] && grep -E 'ROOTFS_URL=' "$d/ml-bootfs.info" | grep -qvE 'ROOTFS_URL=(<none>)?( |$)'; then
		x="$x ml-bootfs.info"
	fi
	x=$(echo $x)
	[ -z "$x" ] && note "ROOTFSURL no ROOTFS_URL" || fail "ROOTFSURL ROOTFS_URL set in: $x"
}

check_patterns() {	# dirs/files...
	local i=0 kind src pat x opt
	[ -s "$PATS" ] || { echo "warn no lab patterns given (-e/-s/-u/-f): lab addresses and user names NOT checked"; return 0; }
	while IFS='	' read -r kind src pat; do
		i=$((i + 1))
		[ "$kind" = fixed ] && opt=-F || opt=-E
		x=$(grep -rla $opt -e "$pat" "$@" 2>/dev/null | sed "s|^$BASE/||" | head -n 5 | tr '\n' ' ')
		if [ -z "$x" ]; then
			note "PATTERN #$i ($src) not found"
		else
			fail "PATTERN #$i ($src) found in: $x"
			[ $VERBOSE = 1 ] && grep -rhoa $opt -e "$pat" "$@" 2>/dev/null | sort -u | head -n 3 | sed 's/^/     match: /'
		fi
	done < "$PATS"
}

run_check() {	# target
	local t=$1 root= extras= files=
	if [ -d "$t" ] && [ -f "$t/rootfs.squashfs" ]; then
		extras=$t
		t=$t/rootfs.squashfs
	fi
	if [ -d "$t" ]; then
		root=$t
	elif [ -f "$t" ]; then
		US=${UNSQUASHFS:-$(command -v unsquashfs)}
		[ -n "$US" ] || { echo "release-check: unsquashfs not found (set UNSQUASHFS)" >&2; return 2; }
		X=$(mktemp -d) || return 2
		cleanup_list="$cleanup_list $X"
		# as a normal user: device nodes and ownership are not restored,
		# file contents are
		"$US" -no-xattrs -quiet -n -d "$X/root" "$t" >"$X/unsquashfs.log" 2>&1
		[ -d "$X/root/etc" ] || { echo "release-check: $t did not extract (see unsquashfs output):" >&2; tail -n 5 "$X/unsquashfs.log" >&2; return 2; }
		root=$X/root
	else
		echo "release-check: $t: no such file or directory" >&2
		return 2
	fi
	echo "release-check: $1"
	check_root "$root"
	BASE=$root
	check_patterns "$root"
	if [ -n "$extras" ]; then
		check_extras "$extras"
		BASE=$extras
		files=
		# what ships: the kernel Image (inside the FIT), the initramfs
		# sources, the image description of the flash kit
		for f in rescue ml-bootfs.info Image; do
			[ -e "$extras/$f" ] && files="$files $extras/$f"
		done
		[ -z "$files" ] || check_patterns $files
	fi
	if [ $FAILS = 0 ]; then
		echo "release-check: PASS"
		return 0
	fi
	echo "release-check: FAIL ($FAILS finding(s))"
	return 1
}

# ---- selftest: a clean twin must PASS, every planted secret must FAIL with
# its own check name -------------------------------------------------------------
selftest() {
	local T S ok=0 total=0 out rc
	T=$(mktemp -d) || exit 2
	cleanup_list="$cleanup_list $T"
	S=$T/clean
	mkdir -p "$S/etc/ssh/authorized_keys" "$S/etc/conf.d" "$S/etc/syslog.d" "$S/usr/bin" "$S/root" "$S/etc/webui"
	echo 'release-mode yes' > "$S/etc/gt-be98-release"
	echo 'HostKey /etc/ssh/ssh_host_ed25519_key' > "$S/etc/ssh/sshd_config"
	echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIselftestkeyselftestkeyselftestkey' > "$S/etc/ssh/authorized_keys/root"
	printf 'NETCONSOLE=\nNETCONSOLE_WAIT=30\n' > "$S/etc/conf.d/gt-be98-netconsole"
	printf '*.*\t-/var/log/messages\n' > "$S/etc/syslog.conf"
	printf 'hostname\n# static ip_address= is documented here only\n' > "$S/etc/dhcpcd.conf"
	echo 'root:*:19000:0:99999:7:::' > "$S/etc/shadow"
	# near misses that must NOT fail: a PEM marker inside a binary, a
	# 63-hex HASH, an address outside the lab pattern, a bare /home and the
	# stock /tmp/home/root
	printf '\000\001ELF\000-----BEGIN OPENSSH PRIVATE KEY-----\000\001' > "$S/usr/bin/ssh-keygen"
	printf 'HASH=%s\n' 012345678901234567890123456789012345678901234567890123456789abc > "$S/etc/notes"
	printf '\000version 203.0.114.3 home=/home\000/tmp/home/root/.ssh\000' > "$S/usr/bin/tool"
	echo 'alicedata not a user word: xalice; other host 198.51.100.70' > "$S/root/readme"
	P=$T/patterns
	printf '# lab patterns (selftest)\nre:203\\.0\\.113\\.[0-9]+\nfixed:labhost.example\nuser:alice\nip:198.51.100.7\n' > "$P"

	expect() {	# name rc-wanted check-word target [extra args]
		local name=$1 want=$2 word=$3 tgt=$4
		shift 4
		total=$((total + 1))
		# a subshell per case; its temporary dirs go under $T
		out=$( (FAILS=0; : > "$PATS"; TMPDIR=$T/tmp; export TMPDIR; mkdir -p "$TMPDIR"
			set -- -f "$P" "$@" "$tgt"; main "$@") 2>&1); rc=$?
		if [ $rc = "$want" ] && { [ -z "$word" ] || echo "$out" | grep -q "^FAIL $word "; } &&
		   { [ "$want" != 1 ] || [ "$(echo "$out" | grep -c '^FAIL ')" = 1 ]; }; then
			ok=$((ok + 1)); echo "selftest ok   $name (rc $rc${word:+, FAIL $word})"
		else
			echo "selftest FAIL $name: rc $rc, want $want ${word:+FAIL $word only}"; echo "$out" | sed 's/^/    | /'
		fi
	}
	plant() {	# name ; then commands on $D
		D=$T/$1
		rm -rf "$D"; cp -a "$S" "$D"
	}

	expect clean 0 '' "$S"
	plant hostkey; echo pub > "$D/etc/ssh/ssh_host_ed25519_key.pub"; expect hostkey 1 HOSTKEY "$D"
	plant privkey; printf '%s\n' '-----BEGIN OPENSSH PRIVATE KEY-----' b3Bl '-----END OPENSSH PRIVATE KEY-----' > "$D/root/id"; expect privkey 1 PRIVKEY "$D"
	plant authconf; : > "$D/etc/webui/auth.conf"; expect authconf 1 PWHASH "$D"
	plant hashline; printf 'SALT=ab\nHASH=%s\n' 0123456789012345678901234567890123456789012345678901234567890abc > "$D/etc/notes"; expect hashline 1 PWHASH "$D"
	plant shadow; echo 'root:$6$salt$hash:19000:0:99999:7:::' > "$D/etc/shadow"; expect shadow 1 PWHASH "$D"
	plant syslog; printf '*.*\t@loghost\n' > "$D/etc/syslog.d/60-remote.conf"; expect syslog 1 REMOTE "$D"
	plant netcons; printf 'NETCONSOLE="@/rnr0,6666@192.0.2.1/"\n' > "$D/etc/conf.d/gt-be98-netconsole"; expect netconsole 1 REMOTE "$D"
	plant fallback; printf 'profile fb\nstatic ip_address=192.0.2.9/24\n' >> "$D/etc/dhcpcd.conf"; expect fallback 1 REMOTE "$D"
	plant akcomment; echo 'ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIother bob@box' >> "$D/etc/ssh/authorized_keys/root"; expect akcomment 1 AKCOMMENT "$D"
	plant relmode; echo 'release-mode no' > "$D/etc/gt-be98-release"; expect relmode 1 RELMODE "$D"
	plant homepath; printf '\000/home/bob/src/x.c\000' > "$D/usr/bin/tool2"; expect homepath 1 HOMEPATH "$D"
	plant labip; printf '\000\001server=203.0.113.9\000' > "$D/usr/bin/tool3"; expect lab-ip-regex 1 PATTERN "$D"
	plant labfixed; echo 'url http://labhost.example/x' > "$D/etc/notes2"; expect lab-fixed-string 1 PATTERN "$D"
	plant user; echo 'owner alice' > "$D/etc/notes3"; expect lab-user-word 1 PATTERN "$D"
	plant labaddr; printf '\000peer=198.51.100.7:8089\000' > "$D/usr/bin/tool4"; expect lab-ip-exact 1 PATTERN "$D"
	# images directory: the initramfs source and the image description
	if command -v "${MKSQUASHFS:-mksquashfs}" >/dev/null 2>&1 &&
	   { [ -n "${UNSQUASHFS:-}" ] || command -v unsquashfs >/dev/null 2>&1; }; then
		I=$T/images; mkdir -p "$I/rescue"
		"${MKSQUASHFS:-mksquashfs}" "$S" "$I/rootfs.squashfs" -noappend -all-root -no-progress -quiet >/dev/null 2>&1
		printf 'WDT_MAX=600\nRESCUE=0\nROOTFS_URL=\n' > "$I/rescue/ml-defaults"
		echo 'boot: RESCUE=0 WDT_MAX=600 ROOTFS_URL=<none> NAND=rw-jffs' > "$I/ml-bootfs.info"
		expect images-clean 0 '' "$I"
		printf 'WDT_MAX=600\nRESCUE=0\nROOTFS_URL=http://198.51.100.8/r.squashfs\n' > "$I/rescue/ml-defaults"
		expect images-rootfsurl 1 ROOTFSURL "$I"
		printf 'WDT_MAX=600\nRESCUE=0\nROOTFS_URL=\n' > "$I/rescue/ml-defaults"
		printf 'cmdline ip=203.0.113.4\n' >> "$I/ml-bootfs.info"
		expect images-pattern-extras 1 PATTERN "$I"
		plant sq-hostkey; echo key > "$D/etc/ssh/ssh_host_rsa_key"
		"${MKSQUASHFS:-mksquashfs}" "$D" "$T/hk.squashfs" -noappend -all-root -no-progress -quiet >/dev/null 2>&1
		expect squashfs-hostkey 1 HOSTKEY "$T/hk.squashfs"
	else
		echo "selftest skip squashfs/images cases (no mksquashfs/unsquashfs)"
	fi
	expect usage-missing 2 '' "$T/does-not-exist"
	echo "release-check selftest: $ok/$total"
	[ $ok = $total ]
}

main() {
	while [ $# -gt 0 ]; do
		case "$1" in
		-e) [ $# -ge 2 ] || usage; addpat re "$2"; shift 2 ;;
		-s) [ $# -ge 2 ] || usage; addpat fixed "$2"; shift 2 ;;
		-u) [ $# -ge 2 ] || usage; addpat user "$2"; shift 2 ;;
		-i) [ $# -ge 2 ] || usage; addpat ip "$2"; shift 2 ;;
		-f) [ $# -ge 2 ] || usage; readpats "$2"; shift 2 ;;
		-v) VERBOSE=1; shift ;;
		-h|--help) usage ;;
		--) shift; break ;;
		-*) usage ;;
		*) break ;;
		esac
	done
	[ $# = 1 ] || usage
	run_check "$1"
}

if [ "${1:-}" = --selftest ]; then
	selftest
	exit $?
fi
main "$@"
