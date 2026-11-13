#!/bin/sh
# shellcheck shell=busybox
# SPDX-License-Identifier: GPL-2.0
# Offline test of sbin/gt-be98-wps (no device, no root):
#   sh test/gt-be98-wps-test.sh
# A real plan and configs from sbin/gt-be98-wifi-gen (a network with wps=1,
# and the control without), a fake hostapd_cli that logs its arguments and
# answers OK (or FAIL with FAKE_FAIL=1).
set -u
here=$(cd "$(dirname "$0")" && pwd)
W="$here/../src/sbin/gt-be98-wps"
G="$here/../src/sbin/gt-be98-wifi-gen"
SH=${SH:-sh}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0 n=0
check() {	# name expected actual
	n=$((n + 1))
	if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$2] got [$3]"; fail=1; fi
}
M="2g=00:00:5e:00:53:a0 5gl=00:00:5e:00:53:a4 5gh=00:00:5e:00:53:a8 6g=00:00:5e:00:53:ac"
mkdir -p "$T/run/gt-be98-wifi" "$T/bin"
cat > "$T/bin/hostapd_cli" <<EOF
#!/bin/sh
echo "\$*" >> "$T/cli.log"
case "\$*" in *wps_get_status*) printf 'PBC Status: Disabled\nLast WPS result: None\n'; exit 0 ;; esac
[ "\${FAKE_FAIL:-0}" = 1 ] && { echo FAIL; exit 0; }
echo OK
EOF
chmod +x "$T/bin/hostapd_cli"
render() {	# render LIST: the service layout, $STATE/gen
	rm -rf "$T/run/gt-be98-wifi/gen"
	$SH "$G" -n "$1" -o "$T/run/gt-be98-wifi/gen" -m "$M" -x /run/hostapd 2> "$T/gen.err" || { echo "FAIL render"; fail=1; }
}
wps() { : > "$T/cli.log"; GT_BE98_RUN="$T/run" GT_BE98_HOSTAPD_CLI="$T/bin/hostapd_cli" $SH "$W" "$@" 2> "$T/err"; }

printf 'network=1\nssid=w\nsecurity=psk2sae\npassphrase=password1\nbands=5gl 2g 6g\nvlan=10\nwps=1\nnetwork=2\nssid=x\nsecurity=psk2\npassphrase=password2\nbands=2g 5gl\nvlan=20\n' > "$T/on"
render "$T/on"
wps pbc; check "pbc: exit 0, one wps_pbc on the first WPS BSS" "0|-p /run/hostapd -i bcawl3 wps_pbc" "$?|$(cat "$T/cli.log")"
wps pin 12345670; check "pin 8 digits, valid checksum: wps_pin any, 120 s" "0|-p /run/hostapd -i bcawl3 wps_pin any 12345670 120" "$?|$(cat "$T/cli.log")"
wps pin 1234; check "pin 4 digits: accepted" "0" "$?"
wps pin 12345678; check "pin with a wrong checksum: refused, hostapd not asked" "1|" "$?|$(cat "$T/cli.log")"
wps pin 12a4; check "pin not digits: refused" "1" "$?"
wps pin 123456; check "pin 6 digits: refused" "1" "$?"
wps cancel; check "cancel: wps_cancel" "0|-p /run/hostapd -i bcawl3 wps_cancel" "$?|$(cat "$T/cli.log")"
wps status > "$T/st"; check "status: hostapd's WPS status" "0 PBC Status: Disabled" "$? $(head -n 1 "$T/st")"
FAKE_FAIL=1 wps pbc; check "hostapd answers FAIL: exit 1, said" "1 yes" "$? $(grep -q 'hostapd answered: FAIL' "$T/err" && echo yes || echo no)"
wps; check "no command: usage, exit 2" "2" "$?"
wps pbc extra; check "pbc with an argument: usage, exit 2" "2" "$?"
# control: no network has wps=1 -> refused, hostapd never asked
printf 'network=2\nssid=x\nsecurity=psk2\npassphrase=password2\nbands=2g 5gl\nvlan=20\n' > "$T/off"
render "$T/off"
wps pbc; check "WPS off: pbc refused, hostapd not asked" "1||yes" "$?|$(cat "$T/cli.log")|$(grep -q 'WPS is off' "$T/err" && echo yes || echo no)"
rm -rf "$T/run/gt-be98-wifi/gen"
wps pbc; check "service not running (no plan): refused" "1" "$?"

if [ $fail = 0 ]; then echo "ALL OK ($n checks)"; else echo "FAILED"; fi
exit $fail
