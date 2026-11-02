#!/bin/sh
# shellcheck shell=busybox
# SPDX-License-Identifier: GPL-2.0
# Offline test of sbin/gt-be98-leds on a fake sysfs (no device, no root):
#   sh test/gt-be98-leds-test.sh
set -u
here=$(cd "$(dirname "$0")" && pwd)
L="$here/../src/sbin/gt-be98-leds"
SH=${SH:-sh}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0 n=0
check() {
	n=$((n + 1))
	if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$2] got [$3]"; fail=1; fi
}
export GT_BE98_CONF="$T/conf" GT_BE98_LEDS_CONF="$T/conf" GT_BE98_LEDS="$T/leds" GT_BE98_SYSNET="$T/net" \
	GT_BE98_WIFI_LEDS="$T/wifi-leds"
# a LED class device as the kernel shows it; the netdev trigger's files
# appear once the trigger is set, here from the start
mkled() {	# name triggers...
	l=$1; shift
	mkdir -p "$T/leds/$l"
	echo "[none] $*" > "$T/leds/$l/trigger"; echo 0 > "$T/leds/$l/brightness"
	for f in device_name link tx rx; do : > "$T/leds/$l/$f"; done
}
mkdir -p "$T/net"
for d in bcawl0 bcawl1 bcawl2 bcawl3 rnr0; do mkdir -p "$T/net/$d/device"; done
run() { $SH "$L" "$@" 2>&1; }

# no LED class at all (today's kernel config)
check "status without a LED class" "no LED class ($T/leds absent: CONFIG_LEDS_CLASS)" "$(run status)"
check "apply without LEDs: exit 0, says so per radio" "0 4" "$(run apply > "$T/out"; echo "$? $(grep -c 'no LED' "$T/out")")"

# the driver registered a LED for bcawl3 and bcawl2 (parent = the radio's device)
mkled wlan-2g netdev timer default-on; mkled wlan-6g netdev; mkled wan netdev; mkled power default-on heartbeat
mkdir -p "$T/net/bcawl3/device/leds/wlan-2g" "$T/net/bcawl2/device/leds/wlan-6g"
: > "$T/conf"
run apply > "$T/out"; rc=$?
check "apply: the two radio LEDs on their netdevs, the others said absent" "0 netdev bcawl3 1 1 1 netdev bcawl2 2" \
	"$rc $(cat "$T/leds/wlan-2g/trigger") $(cat "$T/leds/wlan-2g/device_name") $(cat "$T/leds/wlan-2g/link") $(cat "$T/leds/wlan-2g/tx") $(cat "$T/leds/wlan-2g/rx") $(cat "$T/leds/wlan-6g/trigger") $(cat "$T/leds/wlan-6g/device_name") $(grep -c 'no LED' "$T/out")"
check "apply: LEDs not configured untouched" "[none] netdev|[none] default-on heartbeat" "$(cat "$T/leds/wan/trigger")|$(cat "$T/leds/power/trigger")"
printf 'LED_NETDEV="wan=rnr0"\nLED_TRIGGER="power=default-on missing=heartbeat"\n' > "$T/conf"
run apply > "$T/out"
check "LED_NETDEV / LED_TRIGGER; an absent LED is skipped" "netdev rnr0 default-on yes" \
	"$(cat "$T/leds/wan/trigger") $(cat "$T/leds/wan/device_name") $(cat "$T/leds/power/trigger") $(grep -q 'missing: not present' "$T/out" && echo yes || echo no)"
printf 'LED_TRIGGER="power=nosuch"\n' > "$T/conf"
check "a trigger the LED does not offer: refused, exit 1" "1 default-on" "$(run apply > /dev/null; echo "$? $(cat "$T/leds/power/trigger")")"
printf 'LED_TRIGGER="../../x=none"\n' > "$T/conf"
check "a LED name with a path: not used" "0" "$(run apply > /dev/null; echo $?)"
printf 'WIFI_LEDS="bcawl3"\nLEDS_OFF=1\n' > "$T/conf"
run apply > /dev/null
check "LEDS_OFF=1: every LED off, trigger none" "none 0 none 0 none 0" \
	"$(cat "$T/leds/wlan-2g/trigger") $(cat "$T/leds/wlan-2g/brightness") $(cat "$T/leds/power/trigger") $(cat "$T/leds/power/brightness") $(cat "$T/leds/wan/trigger") $(cat "$T/leds/wan/brightness")"
printf 'LEDS_OFF=x\nWIFI_LEDS="bcawl3; reboot"\n' > "$T/conf"
check "malformed settings: LEDS_OFF refused (not off), WIFI_LEDS refused (none)" "0 0" "$(run apply > "$T/out"; echo "$? $(grep -c 'no LED' "$T/out")")"
# led=0 of a radio in the Wi-Fi network list (gt-be98-wifi's state file)
# (the fake trigger file keeps only the last word written: fresh LEDs)
mkled wlan-2g netdev timer default-on; mkled wlan-6g netdev
: > "$T/conf"; run apply > /dev/null
printf '# written by gt-be98-wifi\nWIFI_LEDS_OFF="bcawl3"\n' > "$T/wifi-leds"
echo 1 > "$T/leds/wlan-2g/brightness"
run apply > "$T/out"; rc=$?
check "WIFI_LEDS_OFF=bcawl3: its LED off, bcawl2's still on its netdev" "0 none 0 netdev bcawl2 yes" \
	"$rc $(cat "$T/leds/wlan-2g/trigger") $(cat "$T/leds/wlan-2g/brightness") $(cat "$T/leds/wlan-6g/trigger") $(cat "$T/leds/wlan-6g/device_name") $(grep -q 'wlan-2g: off (bcawl3: led=0' "$T/out" && echo yes || echo no)"
printf 'WIFI_LEDS_OFF=""\n' > "$T/wifi-leds"
mkled wlan-2g netdev timer default-on
run apply > /dev/null
check "WIFI_LEDS_OFF empty again: bcawl3's LED back on its netdev" "netdev bcawl3" "$(cat "$T/leds/wlan-2g/trigger") $(cat "$T/leds/wlan-2g/device_name")"
printf 'WIFI_LEDS_OFF="bcawl3; reboot"\n' > "$T/wifi-leds"
run apply > /dev/null
check "a malformed WIFI_LEDS_OFF is ignored (LED stays on its netdev)" "netdev" "$(cat "$T/leds/wlan-2g/trigger")"
rm -f "$T/wifi-leds"
# the radio's LED by the driver's name (bca<PCI domain>::wlan) when the netdev's
# device/leds does not list it; control: without uevent, not found
mkled bca1::wlan netdev; mkdir -p "$T/net/bcawl1/device"
printf 'DRIVER=bca_pcie_ipc\nPCI_SLOT_NAME=0003:01:00.0\n' > "$T/net/bcawl1/device/uevent"
mkled bca3::wlan netdev
: > "$T/conf"; run apply > "$T/out"
check "bcawl1 (PCI domain 3): its LED found by name bca3::wlan, put on its netdev; bca1::wlan untouched" "netdev bcawl1 [none] netdev" \
	"$(cat "$T/leds/bca3::wlan/trigger") $(cat "$T/leds/bca3::wlan/device_name") $(cat "$T/leds/bca1::wlan/trigger")"
printf 'WIFI_LEDS_OFF="bcawl1"\n' > "$T/wifi-leds"; echo 1 > "$T/leds/bca3::wlan/brightness"
run apply > /dev/null
check "led=0 reaches the LED found by name" "none 0" "$(cat "$T/leds/bca3::wlan/trigger") $(cat "$T/leds/bca3::wlan/brightness")"
rm -f "$T/wifi-leds" "$T/net/bcawl1/device/uevent"; mkled bca3::wlan netdev
run apply > "$T/out"
check "control: no uevent -> no LED found for bcawl1" "[none] netdev yes" "$(cat "$T/leds/bca3::wlan/trigger") $(grep -q 'bcawl1: no LED' "$T/out" && echo yes || echo no)"
check "usage: exit 2" 2 "$(run bogus > /dev/null; echo $?)"

if [ $fail = 0 ]; then echo "ALL OK ($n checks)"; else echo "FAILED"; fi
exit $fail
