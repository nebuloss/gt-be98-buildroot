#!/bin/sh
# SPDX-License-Identifier: GPL-2.0
# Unit test of sbin/gt-be98-macaddr against a fake sysfs, conf.d and U-Boot
# environment (no device, no root): sh test/gt-be98-macaddr-test.sh
# Runs on the dev host; `ip`, `dhcpcd`, `pidof` and `logger` are stubs.
set -u
here=$(cd "$(dirname "$0")" && pwd)
S="$here/../src/sbin/gt-be98-macaddr"
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
export GT_BE98_SYSNET="$T/net" GT_BE98_CONFD="$T/conf.d" \
	GT_BE98_UBOOT_ENV="$T/uboot_env" GT_BE98_MAC_RUN="$T/run"
mkdir -p "$T/bin" "$T/conf.d"
# ip link set dev IF {down|up|address M}; ip -o link show dev IF
cat > "$T/bin/ip" <<'X'
#!/bin/sh
echo "ip $*" >> "$GT_BE98_SYSNET/../ip.log"
case "$*" in
"-o link show dev "*) i=$5; f=$(cat "$GT_BE98_SYSNET/$i/flags")
	echo "1: $i: <$f> mtu 1500" ;;
"link set dev "*" address "*) i=$4
	[ "$(cat "$GT_BE98_SYSNET/$i/flags")" = BROADCAST,MULTICAST ] || { echo busy >&2; exit 1; }
	echo "$6" > "$GT_BE98_SYSNET/$i/address"; echo 3 > "$GT_BE98_SYSNET/$i/addr_assign_type" ;;
"link set dev "*" down") echo BROADCAST,MULTICAST > "$GT_BE98_SYSNET/$4/flags" ;;
"link set dev "*" up") echo BROADCAST,MULTICAST,UP > "$GT_BE98_SYSNET/$4/flags" ;;
esac
X
printf '#!/bin/sh\necho "dhcpcd $*" >> "$GT_BE98_SYSNET/../ip.log"\n' > "$T/bin/dhcpcd"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/pidof"
printf '#!/bin/sh\nexit 0\n' > "$T/bin/logger"
chmod +x "$T/bin/"*
PATH="$T/bin:$PATH"

port() {	# iface address addr_assign_type flags
	mkdir -p "$T/net/$1"
	echo "$2" > "$T/net/$1/address"
	echo "$3" > "$T/net/$1/addr_assign_type"
	echo "$4" > "$T/net/$1/flags"
}
reset() {
	rm -rf "$T/net" "$T/run" "$T/ip.log" "$T/conf.d"/*
	# rnr0: DT (factory) MAC, up; rnr1: random, down
	port rnr0 00:11:22:33:44:50 0 BROADCAST,MULTICAST,UP
	port rnr1 4e:aa:bb:cc:dd:01 1 BROADCAST,MULTICAST
	printf 'bootdelay=1\0ethaddr=00:11:22:33:44:50\0serial#=X1\0' > "$T/uboot_env"
}
fail=0
check() {	# name expected actual
	if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$2] got [$3]"; fail=1; fi
}
cur() { cat "$T/net/$1/address"; }

reset
check "default rnr0 = factory" 00:11:22:33:44:50 "$(sh "$S" rnr0)"
check "default rnr1 = derived LAA +1" 02:11:22:33:44:51 "$(sh "$S" rnr1)"
check "status" "rnr0 00:11:22:33:44:50 00:11:22:33:44:50 factory 00:11:22:33:44:50
rnr1 4e:aa:bb:cc:dd:01 02:11:22:33:44:51 derived -" "$(sh "$S" --status)"
sh "$S" --apply >/dev/null
check "apply leaves rnr0" 00:11:22:33:44:50 "$(cur rnr0)"
check "apply sets rnr1" 02:11:22:33:44:51 "$(cur rnr1)"
check "no rebind for a down port" "" "$(grep dhcpcd "$T/ip.log")"

# per-port override wins over the DT MAC; applied with down/up + rebind
echo 'RNR_MAC0="AA:BB:CC:00:00:10"  # lab' > "$T/conf.d/gt-be98-macaddr"
check "override rnr0" "aa:bb:cc:00:00:10 override" "$(sh "$S" --status | awk '$1=="rnr0"{print $3, $4}')"
sh "$S" --apply rnr0 >/dev/null
check "override applied" aa:bb:cc:00:00:10 "$(cur rnr0)"
check "apply sequence" "ip -o link show dev rnr0
ip link set dev rnr0 down
ip link set dev rnr0 address aa:bb:cc:00:00:10
ip link set dev rnr0 up
dhcpcd -n rnr0" "$(sed -n '/rnr0/p' "$T/ip.log")"
check "port up again" BROADCAST,MULTICAST,UP "$(cat "$T/net/rnr0/flags")"
check "factory still known" "00:11:22:33:44:50" "$(sh "$S" --status | awk '$1=="rnr0"{print $5}')"

# reset to factory: remove the key, re-apply
: > "$T/conf.d/gt-be98-macaddr"
check "reset -> factory" "00:11:22:33:44:50 factory" "$(sh "$S" --status | awk '$1=="rnr0"{print $3, $4}')"
sh "$S" --apply rnr0 >/dev/null
check "factory re-applied" 00:11:22:33:44:50 "$(cur rnr0)"

# invalid overrides are ignored (multicast, zero, junk)
for bad in 01:00:5e:00:00:01 00:00:00:00:00:00 'x;reboot' 'aa:bb:cc:dd:ee'; do
	echo "RNR_MAC1=$bad" > "$T/conf.d/gt-be98-macaddr"
	check "reject $bad" "02:11:22:33:44:51 derived" "$(sh "$S" --status 2>/dev/null | awk '$1=="rnr1"{print $3, $4}')"
done

# RNR_MAC_BASE: every port, rnr0 included, LAA +N; a per-port key still wins
reset
echo 'RNR_MAC_BASE=00:aa:bb:cc:dd:f0' > "$T/conf.d/gt-be98-drivers"
check "base rnr0" 02:aa:bb:cc:dd:f0 "$(sh "$S" rnr0)"
check "base rnr1" 02:aa:bb:cc:dd:f1 "$(sh "$S" rnr1)"
echo 'RNR_MAC1=00:aa:bb:cc:dd:99' > "$T/conf.d/gt-be98-macaddr"
check "port key over base" 00:aa:bb:cc:dd:99 "$(sh "$S" rnr1)"
# the macaddr file wins; an empty key there clears the drivers one
printf 'RNR_MAC_BASE=00:aa:bb:cc:dd:f0\nRNR_MAC0=00:aa:bb:cc:dd:77\n' > "$T/conf.d/gt-be98-drivers"
echo 'RNR_MAC0=' > "$T/conf.d/gt-be98-macaddr"
check "empty key clears" 02:aa:bb:cc:dd:f0 "$(sh "$S" rnr0)"
: > "$T/conf.d/gt-be98-macaddr"
check "drivers key kept" 00:aa:bb:cc:dd:77 "$(sh "$S" rnr0)"

# last-octet wrap, hash fallback, no source at all
reset
printf 'ethaddr=00:11:22:33:44:ff\0' > "$T/uboot_env"
check "wrap" 02:11:22:33:44:00 "$(sh "$S" rnr1)"
printf 'serial#=X1\0boardid=GT-BE98\0' > "$T/uboot_env"
h=$(sh "$S" --status | awk '$1=="rnr1"{print $4}')
check "hash fallback" hash "$h"
rm -f "$T/uboot_env"
sh "$S" rnr1 >/dev/null; check "no source exit 1" 1 $?
check "no source status" "- none" "$(sh "$S" --status | awk '$1=="rnr1"{print $3, $4}')"
check "no source apply keeps" "rnr1: no MAC source, keeping 4e:aa:bb:cc:dd:01" "$(sh "$S" --apply rnr1)"
sh "$S" --apply eth0 2>/dev/null; check "non-rnr refused" 1 $?

[ $fail = 0 ] && echo "all passed"
exit $fail
