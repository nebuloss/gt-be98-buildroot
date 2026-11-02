#!/bin/sh
# shellcheck shell=busybox
# SPDX-License-Identifier: GPL-2.0
# Offline test of sbin/gt-be98-wifi-gen (no device, no root):
#   sh test/gt-be98-wifi-gen-test.sh [HOSTAPD_CONFCHECK]
# Runs the whole suite once per awk found (busybox awk = the box's, mawk,
# gawk; SH="busybox sh" runs the generator with the box's shell). With
# HOSTAPD_CONFCHECK (test/build-hostapd-confcheck.sh: hostapd's
# own parser and checks, from the OS's hostapd source), every generated
# config must also parse with hostapd. With WPA_CONFCHECK=
# (test/build-wpa-confcheck.sh: wpa_supplicant's own parser), every
# station config must parse with wpa_supplicant.
set -u
here=$(cd "$(dirname "$0")" && pwd)
G="$here/../src/sbin/gt-be98-wifi-gen"
CONFCHECK=${1:-${HOSTAPD_CONFCHECK:-}}
WPA_CONFCHECK=${WPA_CONFCHECK:-}
SH=${SH:-sh}
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
fail=0 n=0
check() {	# name expected actual
	n=$((n + 1))
	if [ "$2" = "$3" ]; then echo "ok   $1"; else echo "FAIL $1: want [$2] got [$3]"; fail=1; fi
}
# the radios' own addresses: RFC 7042 documentation MACs, consecutive like a board MAC block
M="2g=00:00:5e:00:53:a0 5gl=00:00:5e:00:53:a4 5gh=00:00:5e:00:53:a8 6g=00:00:5e:00:53:ac"
gen() {	# gen LIST [extra options]: output in $T/o, slots in $T/slots
	l=$1; shift
	$SH "$G" -n "$l" -o "$T/o" -s "$T/slots" -m "$M" "$@" 2> "$T/err"
}
plan_bss() { awk '$1 == "bss" { print $3, $4, $5, $6, $7, $8 }' "$T/o/plan"; }
# BSSID of ifname $1
bssid_of() { awk -v i="$1" '$1 == "bss" && $3 == i { print $7 }' "$T/o/plan"; }
has() { grep -qx "$2" "$T/o/sec-$1" && echo yes || echo no; }
conf_ok() {	# every generated config parses with hostapd (when available)
	[ -n "$CONFCHECK" ] || { echo "skip $1 (no hostapd-confcheck)"; return 0; }
	if "$CONFCHECK" "$T"/o/hostapd-*.conf "$T"/o/bss-*.conf > "$T/cc" 2>&1; then
		check "$1: hostapd parses $(grep -c '^OK' "$T/cc") configs" 0 0
	else
		check "$1: hostapd parses every config" ok "$(grep -E 'FAIL|rror' "$T/cc" | head -3 | tr '\n' ' ')"
	fi
}
# every BSSID once over all radios, none is another radio's own address
# unless it is that radio's anchor, the secondaries follow the firmware's
# mbss8 rule: one block per radio (octets 0-4 + octet 5 & 0xf8), a ucode
# index (octet 5 & 7) of their own, never the anchor's
bssid_rules() {
	check "$1: no BSSID twice" "" "$(awk '$1 == "bss" { print $7 }' "$T/o/plan" | sort | uniq -d | tr '\n' ' ')"
	check "$1: mbss8 rule" "" "$(echo "$M" | tr ' ' '\n' | awk -F= -v plan="$T/o/plan" '
		function h(x) { return index("0123456789abcdef", tolower(x)) - 1 }
		function byte(s) { return h(substr(s, 1, 1)) * 16 + h(substr(s, 2, 1)) }
		{ base[$1] = $2 }
		END {
			dev["2g"] = "bcawl3"; dev["5gl"] = "bcawl0"; dev["5gh"] = "bcawl1"; dev["6g"] = "bcawl2"
			for (b in base) bdev[dev[b]] = base[b]
			while ((getline l < plan) > 0) {
				split(l, f, " "); if (f[1] != "bss") continue
				m = bdev[f[2]]; a = f[7]; s = f[6]
				split(m, mo, ":"); split(a, ao, ":")
				if (s == 0) { if (a != m) print f[3] ":anchor!=radio"; continue }
				# 6 GHz: nontransmitted BSSIDs keep the anchor octet 0
				if (f[2] == "bcawl2") { if (ao[1] != mo[1]) print f[3] ":6g-octet0" }
				else if (byte(ao[1]) % 4 != 2) print f[3] ":not-LA/unicast"
				adj = (byte(mo[1]) == 96 && byte(mo[6]) % 15 == 0) ? 1 : 0
				if (f[2] != "bcawl2" && byte(ao[1]) != (96 + ((byte(mo[6]) + adj) % 15) * 8) + 2) print f[3] ":octet0"
				if (int(byte(ao[6]) / 8) != int(byte(mo[6]) / 8)) print f[3] ":block"
				if (byte(ao[6]) % 8 != (byte(mo[6]) + s) % 8) print f[3] ":index"
				if (byte(ao[6]) % 8 == byte(mo[6]) % 8) print f[3] ":anchor-index"
				if ((f[2], byte(ao[6]) % 8) in seen) print f[3] ":index-twice"
				seen[f[2], byte(ao[6]) % 8] = 1
				if (s < 1 || s > 7) print f[3] ":index-range"
				if (ao[2] ao[3] ao[4] ao[5] != mo[2] mo[3] mo[4] mo[5]) print f[3] ":octets1-4"
				for (r in bdev) if (a == bdev[r]) print f[3] ":radio-address"
			}
		}' | tr '\n' ' ')"
}

suite() {
rm -rf "$T/o" "$T/slots"

# ---- 1. the three networks of the spec ----
cat > "$T/n1" <<'EOF'
# guest open/OWE on all bands, home WPA2/WPA3 on 2.4/5, iot WPA2 2.4 only
radio=5gl
channel=40
width=80
network=30
ssid=guest
security=open-owe
bands=2g 5gl 5gh 6g
vlan=30
isolate=1
network=10
ssid=home
security=psk2sae
passphrase=correct horse battery
bands=2g 5gl 5gh
vlan=10
network=20
ssid=iot
security=psk2
passphrase=iotpass123
bands=2g
vlan=20
EOF
gen "$T/n1"; check "3 nets: accepted" 0 $?
check "3 nets: BSSes" "bcawl3 0 30 0 00:00:5e:00:53:a0 brwifi30
bcawl3-1 1 10 1 b2:00:5e:00:53:a1 brwifi10
bcawl3-2 2 20 2 b2:00:5e:00:53:a2 brwifi20
bcawl0 0 30 0 00:00:5e:00:53:a4 brwifi30
bcawl0-1 1 10 1 d2:00:5e:00:53:a5 brwifi10
bcawl1 0 30 0 00:00:5e:00:53:a8 brwifi30
bcawl1-1 1 10 1 7a:00:5e:00:53:a9 brwifi10
bcawl2 0 30 0 00:00:5e:00:53:ac brwifi30" "$(plan_bss)"
check "3 nets: networks (id bridge vlan isolate)" "net 30 brwifi30 30 1
net 10 brwifi10 10 0
net 20 brwifi20 20 0" "$(grep '^net ' "$T/o/plan")"
bssid_rules "3 nets"
check "6g guest = OWE, PMF required" "yes yes yes no" \
	"$(has bcawl2 wpa_key_mgmt=OWE) $(has bcawl2 ieee80211w=2) $(has bcawl2 wpa=2) $(has bcawl2 wpa=0)"
check "2.4 guest = open" "yes" "$(has bcawl3 wpa=0)"
check "rnr=1 on 2.4/5, not 6" "yes yes yes no" \
	"$(has bcawl3 rnr=1) $(has bcawl0-1 rnr=1) $(has bcawl1 rnr=1) $(has bcawl2 rnr=1)"
check "home transition: PSK+SAE, PMF optional, H2E+HnP" "yes yes yes" \
	"$(has bcawl0-1 'wpa_key_mgmt=WPA-PSK SAE') $(has bcawl0-1 ieee80211w=1) $(has bcawl0-1 sae_pwe=2)"
check "isolate -> ap_isolate=1 (guest only)" "yes no" "$(has bcawl3 ap_isolate=1) $(has bcawl3-1 ap_isolate=1)"
check "wmm_enabled=1 everywhere" "" "$(for f in "$T"/o/sec-*; do grep -qx wmm_enabled=1 "$f" || echo "${f##*/}"; done)"
check "5gl radio lines (ch 40, 80 MHz)" "channel=40 ht_capab=[HT40-] vht_oper_chwidth=1 vht_oper_centr_freq_seg0_idx=42" \
	"$(grep -E '^(channel|ht_capab|vht_oper)' "$T/o/hdr-bcawl0" | tr '\n' ' ' | sed 's/ $//')"
check "6g radio lines" "op_class=131 channel=37 ieee80211ax=1" \
	"$(grep -E '^(op_class|channel|ieee80211ax)' "$T/o/hdr-bcawl2" | tr '\n' ' ' | sed 's/ $//')"
check "no country_code without -c" "" "$(grep -l country_code "$T"/o/hdr-* | tr '\n' ' ')"
check "radio conf: interface= then bss= in slot order" "interface=bcawl3 bss=bcawl3-1 bss=bcawl3-2" \
	"$(grep -E '^(interface|bss)=' "$T/o/hostapd-bcawl3.conf" | tr '\n' ' ' | sed 's/ $//')"
check "bss conf: its own interface=, radio lines, one section" "interface=bcawl3-2 hw_mode=g 1" \
	"$(grep -E '^(interface|bss)=' "$T/o/bss-bcawl3-2.conf") $(grep '^hw_mode' "$T/o/bss-bcawl3-2.conf") $(grep -c '^ssid=' "$T/o/bss-bcawl3-2.conf")"
check "configs 0600" "600" "$(stat -c %a "$T/o/hostapd-bcawl3.conf")"
conf_ok "3 nets"
gen "$T/n1" -c; check "country only with -c: none set" "" "$(grep -l country_code "$T"/o/hdr-* | tr '\n' ' ')"
sed -i '1i country=FR' "$T/n1"
gen "$T/n1" -c; check "-c + country: 2.4 d, 5 d+h" "country_code=FR ieee80211d=1 | country_code=FR ieee80211d=1 ieee80211h=1" \
	"$(grep -E '^(country_code|ieee80211[dh])' "$T/o/hdr-bcawl3" | tr '\n' ' ')| $(grep -E '^(country_code|ieee80211[dh])' "$T/o/hdr-bcawl0" | tr '\n' ' ' | sed 's/ $//')"
conf_ok "country"
gen "$T/n1"
check "slots remembered" "2g 0 30 0
2g 1 10 1
2g 2 20 2
5gl 0 30 0
5gl 1 10 1
5gh 0 30 0
5gh 1 10 1
6g 0 30 0" "$(grep -v '^#' "$T/slots")"

# ---- 2. WPA3 on 6 GHz: SAE only, H2E only, PMF required ----
sed 's/^bands=2g 5gl 5gh$/bands=2g 5gl 5gh 6g/' "$T/n1" > "$T/n2"
gen "$T/n2"; check "home on 6g: accepted" 0 $?
check "6g home: SAE, H2E only, PMF required, no PSK" "yes yes yes yes no" \
	"$(has bcawl2-1 wpa_key_mgmt=SAE) $(has bcawl2-1 sae_pwe=1) $(has bcawl2-1 ieee80211w=2) $(has bcawl2-1 sae_require_mfp=1) $(grep -q WPA-PSK "$T/o/sec-bcawl2-1" && echo yes || echo no)"
check "home keeps its slots/BSSIDs elsewhere" "b2:00:5e:00:53:a1 d2:00:5e:00:53:a5" "$(bssid_of bcawl3-1) $(bssid_of bcawl0-1)"
conf_ok "6g SAE"
# the instrument's negative control: hostapd must refuse WPA2 / no PMF on 6 GHz
if [ -n "$CONFCHECK" ]; then
	sed 's/^wpa_key_mgmt=SAE$/wpa_key_mgmt=WPA-PSK/' "$T/o/bss-bcawl2-1.conf" > "$T/bad1.conf"
	sed 's/^ieee80211w=2$/ieee80211w=1/' "$T/o/bss-bcawl2-1.conf" > "$T/bad2.conf"
	sed 's/^bssid=.*/bssid=zz/' "$T/o/bss-bcawl3-1.conf" > "$T/bad3.conf"
	check "hostapd refuses WPA2 on 6 GHz, PMF optional on 6 GHz, a bad bssid" "FAIL FAIL FAIL" \
		"$("$CONFCHECK" "$T/bad1.conf" "$T/bad2.conf" "$T/bad3.conf" 2>/dev/null | grep -E '^(OK|FAIL) ' | cut -d' ' -f1 | tr '\n' ' ' | sed 's/ $//')"
fi

# ---- 3. sticky slots: delete home, iot keeps slot 2 and its BSSID ----
gen "$T/n1"
awk '/^network=10$/ { skip = 1; next } /^network=/ { skip = 0 } !skip' "$T/n1" > "$T/n3"
gen "$T/n3"; check "delete home: accepted" 0 $?
check "iot keeps bcawl3-2 + BSSID" "bcawl3-2 2 20 2 b2:00:5e:00:53:a2 brwifi20" "$(plan_bss | grep ' 20 ')"
check "slot 1 now free on 2g" "" "$(plan_bss | grep '^bcawl3-1 ')"
check "home's bridge gone" "" "$(grep '^net 10 ' "$T/o/plan")"
printf 'network=40\nssid=cam\nsecurity=sae\npassphrase=camera-pass\nbands=2g 5gh\nvlan=40\n' >> "$T/n3"
gen "$T/n3"
check "new network takes the lowest free slot" "bcawl3-1 1 40 1 b2:00:5e:00:53:a1 brwifi40
bcawl1-1 1 40 1 7a:00:5e:00:53:a9 brwifi40" "$(plan_bss | grep ' 40 ')"
check "iot still slot 2" "bcawl3-2 2 20 2" "$(plan_bss | grep ' 20 ' | cut -d' ' -f1-4)"

# ---- 4. the anchor leaves: the lowest slot becomes the anchor ----
awk '/^network=30$/ { skip = 1; next } /^network=/ { skip = 0 } !skip' "$T/n3" > "$T/n4"
gen "$T/n4" -K 1 -N
check "-K 1: the promoted anchor keeps its index" "bcawl3 0 40 1 b2:00:5e:00:53:a1" "$(plan_bss | grep '^bcawl3 ' | cut -d' ' -f1-5)"
gen "$T/n4"; check "delete guest (anchor everywhere): accepted" 0 $?
check "2g: cam promoted to slot 0 = radio address; iot unchanged" "bcawl3 0 40 0 00:00:5e:00:53:a0 brwifi40
bcawl3-2 2 20 2 b2:00:5e:00:53:a2 brwifi20" "$(plan_bss | grep '^bcawl3')"
check "radios without networks are not rendered" "" "$(for f in "$T"/o/*bcawl[02].conf "$T"/o/*bcawl[02]-*.conf; do [ -e "$f" ] && echo "${f##*/}"; done)"
bssid_rules "after promotion"
conf_ok "promotion"

# ---- 5. refusals: nothing written to the slot file ----
cp "$T/slots" "$T/slots.keep"
refuse() {	# name list-file
	gen "$2"; r=$?
	check "refused: $1" "1 same" "$r $(cmp -s "$T/slots" "$T/slots.keep" && echo same || echo changed)"
}
net() { printf 'network=%s\nssid=%s\nsecurity=%s\npassphrase=%s\nbands=%s\nvlan=%s\n' "$@"; }
net 1 a psk2 password1 "2g 6g" 5 > "$T/r"; refuse "WPA2 on 6 GHz" "$T/r"
printf 'network=1\nssid=a\nsecurity=open\nbands=6g\nvlan=5\n' > "$T/r"; refuse "open on 6 GHz" "$T/r"
{ net 1 a sae password1 2g 5; net 2 b sae password2 2g 5; } > "$T/r"; refuse "one VLAN twice" "$T/r"
{ net 1 a sae password1 2g 5; net 2 a sae password2 2g 6; } > "$T/r"; refuse "one SSID twice" "$T/r"
net 1 a sae short 2g 5 > "$T/r"; refuse "passphrase < 8" "$T/r"
net 1 a sae "$(printf '%064d' 0)" 2g 5 > "$T/r"; refuse "SAE with a raw 64-hex PSK" "$T/r"
net 1 a sae password1 2g 0 > "$T/r"; refuse "VLAN 0" "$T/r"
net 1 a sae password1 "2g 7g" 5 > "$T/r"; refuse "unknown band" "$T/r"
{ net 1 a sae password1 2g 1; printf 'slot.2g=1\n'; net 2 b sae password2 2g 2; printf 'slot.2g=1\n'; } > "$T/r"; refuse "explicit slot twice" "$T/r"
{ net 1 a sae password1 2g 1; printf 'slot.2g=4\n'; } > "$T/r"; refuse "explicit slot >= cap" "$T/r"
{ printf 'radio=5gl\nchannel=100\n'; net 1 a sae password1 5gl 1; } > "$T/r"; refuse "5gl channel 100" "$T/r"
for cw in 6g:233:40 6g:225:80 6g:229:160 6g:233:320 6g:37:60 6g:37:640 5gl:36:160 5gh:100:320 2g:6:80 2g:6:160; do
	b=${cw%%:*}; c=${cw#*:}; w=${c#*:}; c=${c%%:*}
	{ printf 'radio=%s\nchannel=%s\nwidth=%s\n' "$b" "$c" "$w"; net 1 a sae password1 "$b" 1; } > "$T/r"; refuse "$b channel $c at $w MHz" "$T/r"
done
{ printf 'radio=6g\nchannel=233\nwidth=40\n'; net 1 a sae password1 6g 1; } > "$T/r"; gen "$T/r"
check "the width refusal says why" "yes" "$(grep -q 'radio 6g: channel 233 has no 40 MHz block' "$T/err" && echo yes || echo no)"
for i in 1 2 3 4 5; do net $i n$i sae password$i 2g $i; done > "$T/r"; refuse "5 networks on a 4-BSS radio" "$T/r"
check "the refusal says why" "yes" "$(grep -q 'at most 4 per radio' "$T/err" && echo yes || echo no)"
net 1 a sae password1 2g 5 | sed 's/^ssid=a$/ssid=0123456789abcdef0123456789abcdefX/' > "$T/r"; refuse "SSID of 33 bytes" "$T/r"
printf 'network=1\nssid=a\nsecurity=sae\npassphrase=password1\nbands=2g\nvlan=5\nfoo=1\n' > "$T/r"; refuse "unknown key" "$T/r"
check "a refused passphrase is not echoed" "no" "$(net 1 a sae short 2g 5 > "$T/r"; printf 'passphrase2=secret-x\n' >> "$T/r"; gen "$T/r"; grep -q secret-x "$T/err" && echo yes || echo no)"

# ---- 6. options ----
{ net 7 "caf$(printf '\303\251') wifi" sae password7 "2g 5gl" 7; printf 'hidden=1\nmax_clients=12\n'; } > "$T/o6"
rm -f "$T/slots"; gen "$T/o6"; check "options: accepted" 0 $?
check "UTF-8 SSID -> ssid2 hex" "ssid2=636166c3a92077696669" "$(grep '^ssid' "$T/o/sec-bcawl3")"
check "hidden, max_clients" "yes yes" "$(has bcawl3 ignore_broadcast_ssid=1) $(has bcawl0 max_num_sta=12)"
{ net 7 seen sae password7 "2g 5gl" 7; printf 'hidden=0\nisolate=0\n'; } > "$T/o6z"
rm -f "$T/slots"; gen "$T/o6z"; check "hidden=0 isolate=0: accepted" 0 $?
check "hidden=0 isolate=0 -> SSID broadcast, no isolation" "no no" "$(has bcawl3 ignore_broadcast_ssid=1) $(has bcawl3 ap_isolate=1)"
net 8 hex psk2 "$(printf '%064d' 7 | tr 0 a)" 2g 8 > "$T/o6b"
rm -f "$T/slots"; gen "$T/o6b"
check "WPA2 raw PSK -> wpa_psk" "yes" "$(grep -q '^wpa_psk=a\{63\}7$' "$T/o/sec-bcawl3" && echo yes || echo no)"
conf_ok "options"
{ net 1 a sae password1 "2g 5gh" 1; printf 'slot.2g=3\nmac.2g=5\n'; } > "$T/o6c"
rm -f "$T/slots"; gen "$T/o6c"
check "explicit slot/index (no anchor: promoted, index 0)" "bcawl3 0 1 0" "$(plan_bss | grep '^bcawl3' | cut -d' ' -f1-4)"
{ net 1 a sae password1 "2g" 1; printf 'slot.2g=0\n'; net 2 b sae password2 "2g" 2; printf 'slot.2g=3\nmac.2g=5\n'; } > "$T/o6d"
rm -f "$T/slots"; gen "$T/o6d"
check "explicit slot 3 + index 5" "bcawl3-3 3 2 5 b2:00:5e:00:53:a5" "$(plan_bss | grep ' 2 5 ' | cut -d' ' -f1-5)"
sed 's/^mac.2g=5$/mac.2g=8/' "$T/o6d" > "$T/o6d8"
rm -f "$T/slots"; gen "$T/o6d8"; check "explicit index 8 refused (mbss8: 1..7)" 1 $?
# a slot file of the old 4-bit rule: index 9 is reallocated, the slot kept
printf '2g 0 1 0\n2g 3 2 9\n' > "$T/slots"; sed '/^slot\./d; /^mac\./d' "$T/o6d" > "$T/o6f"; gen "$T/o6f"
check "old sticky index 9: reallocated to 1, slot 3 kept, said so" "0 bcawl3-3 3 2 1 b2:00:5e:00:53:a1 yes" \
	"$? $(plan_bss | grep '^bcawl3-3 ' | cut -d' ' -f1-5) $(grep -q 'outside 1..7' "$T/err" && echo yes || echo no)"
cp "$T/slots" "$T/slots.keep"; gen "$T/n1" -N
check "-N: slot file untouched, slots.new written" "same yes" \
	"$(cmp -s "$T/slots" "$T/slots.keep" && echo same || echo changed) $([ -s "$T/o/slots.new" ] && echo yes || echo no)"
{ cat "$T/n2"; printf 'radio=6g\nenabled=0\n'; } > "$T/o6e"
rm -f "$T/slots"; gen "$T/n2"; gen "$T/o6e"
check "radio disabled: not rendered, its slots kept" "none 6g 0 30 0" \
	"$(ls "$T/o/hostapd-bcawl2.conf" 2>/dev/null || echo none) $(grep '^6g 0 ' "$T/slots")"

# ---- 7. 8 BSS per radio (the firmware's mbss8), the four radios ----
: > "$T/s8x4"
for i in $(seq 1 8); do
	case $((i % 4)) in 0) s=sae ;; 1) s=psk2sae ;; 2) s=owe ;; 3) s=open-owe ;; esac
	if [ "$s" = owe ] || [ "$s" = open-owe ]; then
		printf 'network=%s\nssid=net%s\nsecurity=%s\nbands=2g 5gl 5gh 6g\nvlan=%s\n' $((100 + i)) "$i" "$s" $((100 + i))
	else net $((100 + i)) "net$i" "$s" "password$i" "2g 5gl 5gh 6g" $((100 + i)); fi >> "$T/s8x4"
done
# 6 GHz secondaries are nontransmitted BSSIDs of the anchor's block (10b4):
# with the consecutive board MACs the 6g block (..:a8-af) holds the 5gh
# radio's address (..:a8), so 8 on 6g cannot be: the 6g radio moves to its
# own block here (the board shape is tested in 10b4)
M0=$M; M="2g=00:00:5e:00:53:a0 5gl=00:00:5e:00:53:a4 5gh=00:00:5e:00:53:a8 6g=00:00:5e:00:53:b0"
rm -f "$T/slots"; gen "$T/s8x4" -C 8; check "8x4: accepted with -C 8" 0 $?
check "8x4: 32 BSSes" 32 "$(plan_bss | wc -l | tr -d ' ')"
check "8x4: slots 0..7 on every radio" "8 8 8 8" "$(for d in bcawl3 bcawl0 bcawl1 bcawl2; do plan_bss | awk -v d="$d" '$1 == d || index($1, d "-") == 1 { print $2 }' | sort -un | wc -l | tr -d ' '; done | tr '\n' ' ' | sed 's/ $//')"
check "8x4: ifnames bcawlN-1..7" "bcawl3-7" "$(plan_bss | awk '{ print $1 }' | grep -x 'bcawl3-7')"
# by hand: 6g radio ..:b0 (index 0), its nontransmitted BSSIDs ..:b1-b7, octet 0 kept
check "8x4: 6 GHz BSSIDs by hand (anchor ..:b0, nontransmitted ..:b1-b7)" \
	"00:00:5e:00:53:b0 00:00:5e:00:53:b1 00:00:5e:00:53:b2 00:00:5e:00:53:b3 00:00:5e:00:53:b4 00:00:5e:00:53:b5 00:00:5e:00:53:b6 00:00:5e:00:53:b7" \
	"$(awk '$1 == "bss" && $2 == "bcawl2" { print $7 }' "$T/o/plan" | sort | tr '\n' ' ' | sed 's/ $//')"
# by hand, 5gh radio ..:a8: prefix 0x60 + (0xa8 % 15) * 8 = 0x60 + 3 * 8 = 0x78, LA => 7a
check "8x4: 5gh secondaries keep the LA prefix (control)" "7a:00:5e:00:53:a9" "$(bssid_of bcawl1-1)"
bssid_rules "8x4"
check "8x4: 6g never WPA2/open" "" "$(grep -lE '^(wpa=0|wpa_key_mgmt=WPA-PSK.*)$' "$T"/o/sec-bcawl2* | tr '\n' ' ')"
conf_ok "8x4"
gen "$T/s8x4"; check "8 networks on a 4-BSS radio: refused" 1 $?
{ cat "$T/s8x4"; net 999 extra sae password9 2g 999; } > "$T/s9"
gen "$T/s9" -C 8; check "9th network on an 8-BSS radio: refused" 1 $?
gen "$T/s8x4" -C 9; check "-C 9 refused (mbss8)" 1 $?
# the board shape (6g ..:ac, 5gh ..:a8 in its block): 7 on 6g fit, the 8th is refused
M=$M0
gen "$T/s8x4" -C 8; check "board MACs: 8 on 6g refused (no free BSSID: ..:a8 is the 5gh radio)" "1 yes" \
	"$? $(grep -q 'radio 6g: no free BSSID' "$T/err" && echo yes || echo no)"
awk '/^network=108$/ { exit } { print }' "$T/s8x4" > "$T/s7"
rm -f "$T/slots"; gen "$T/s7" -C 8; check "board MACs: 7 on every radio: accepted, 7 on 6g" "0 7" "$? $(awk '$1 == "bss" && $2 == "bcawl2"' "$T/o/plan" | wc -l | tr -d ' ')"
bssid_rules "board MACs, 7 per radio"

# ---- 8. radios whose BSSIDs would collide under the rule ----
# 2g 60:..:00 (adj 1) and 5gl 02:..:01 get the same prefix 6a and block ..:00;
# 5gh's own address 6a:..:05 lies in that block too
M="2g=60:00:00:00:00:00 5gl=02:00:00:00:00:01 5gh=6a:00:00:00:00:05 6g=02:00:00:00:00:40"
for i in 1 2 3 4; do net $((200 + i)) "c$i" sae "password$i" "2g 5gl 5gh 6g" $((200 + i)); done > "$T/s4c"
rm -f "$T/slots"; gen "$T/s4c" -C 4; check "colliding bases, 4 networks: accepted" 0 $?
bssid_rules "colliding bases"
check "collisions were avoided, not ignored" "yes" "$(plan_bss | awk '$1 ~ /^bcawl0-/ && $4 != $2 { x = 1 } END { print x ? "yes" : "no" }')"
conf_ok "colliding bases"
for i in 1 2 3 4 5 6 7 8; do net $((200 + i)) "c$i" sae "password$i" "2g 5gl 5gh 6g" $((200 + i)); done > "$T/s8c"
rm -f "$T/slots"; gen "$T/s8c" -C 8
check "colliding bases, 8 networks: refused (7 free BSSIDs in the shared block)" "1 yes" "$? $(grep -q 'no free BSSID' "$T/err" && echo yes || echo no)"
M="2g=00:00:5e:00:53:a0 5gl=00:00:5e:00:53:a4 5gh=00:00:5e:00:53:a8 6g=00:00:5e:00:53:ac"

# ---- 9. Enterprise (802.1X, external RADIUS): RFC 5737/3849 addresses ----
eap() {	# eap ID SSID SECURITY BANDS VLAN SERVER SECRET [extra lines]
	printf 'network=%s\nssid=%s\nsecurity=%s\nbands=%s\nvlan=%s\nradius_server=%s\nradius_secret=%s\n' \
		"$1" "$2" "$3" "$4" "$5" "$6" "$7"
	[ $# -gt 7 ] && printf '%s\n' "$8"
	return 0
}
{
	eap 50 corp2 wpa2-eap "2g 5gl" 50 192.0.2.10 'rad-secret 50'
	eap 51 corp3 wpa3-eap "5gh 6g" 51 2001:db8::10 rad-secret-51 'radius_port=11812'
	eap 52 corpt wpa2-wpa3-eap "2g 5gl 5gh 6g" 52 192.0.2.10 rad-secret-52 'radius_acct_server=192.0.2.11'
	printf 'radius_acct_port=11813\n'
} > "$T/e1"
rm -f "$T/slots"; gen "$T/e1"; check "enterprise: accepted" 0 $?
check "wpa2-eap: WPA-EAP, no PMF, 802.1X to the server" \
	"yes no yes yes yes yes no no" \
	"$(has bcawl3 wpa_key_mgmt=WPA-EAP) $(grep -q '^ieee80211w=' "$T/o/sec-bcawl3" && echo yes || echo no) $(has bcawl3 ieee8021x=1) $(has bcawl3 auth_server_addr=192.0.2.10) $(has bcawl3 auth_server_port=1812) $(has bcawl3 'auth_server_shared_secret=rad-secret 50') $(grep -q '^acct_server' "$T/o/sec-bcawl3" && echo yes || echo no) $(grep -qE '^wpa_(passphrase|psk)=' "$T/o/sec-bcawl3" && echo yes || echo no)"
check "wpa3-eap: WPA-EAP-SHA256, PMF required, IPv6 server, port" "yes yes yes yes" \
	"$(has bcawl1 wpa_key_mgmt=WPA-EAP-SHA256) $(has bcawl1 ieee80211w=2) $(has bcawl1 auth_server_addr=2001:db8::10) $(has bcawl1 auth_server_port=11812)"
check "wpa2-wpa3-eap: both AKMs, PMF optional (2.4/5 GHz)" "yes yes yes yes" \
	"$(has bcawl3-1 'wpa_key_mgmt=WPA-EAP WPA-EAP-SHA256') $(has bcawl3-1 ieee80211w=1) $(has bcawl0-1 'wpa_key_mgmt=WPA-EAP WPA-EAP-SHA256') $(has bcawl1-1 ieee80211w=1)"
check "wpa2-wpa3-eap on 6 GHz: WPA3-Enterprise only, PMF required" "yes yes no" \
	"$(has bcawl2-1 wpa_key_mgmt=WPA-EAP-SHA256) $(has bcawl2-1 ieee80211w=2) $(has bcawl2-1 ieee80211w=1)"
check "accounting: own port, secret defaults to radius_secret" "yes yes yes" \
	"$(has bcawl3-1 acct_server_addr=192.0.2.11) $(has bcawl3-1 acct_server_port=11813) $(has bcawl3-1 acct_server_shared_secret=rad-secret-52)"
check "RADIUS secrets only in 0600 files" "" \
	"$(for f in "$T"/o/*; do grep -q rad-secret "$f" && [ "$(stat -c %a "$f")" != 600 ] && echo "${f##*/}"; done)"
check "secrets not in the plan" "no" "$(grep -q rad-secret "$T/o/plan" && echo yes || echo no)"
conf_ok "enterprise"
if [ -n "$CONFCHECK" ]; then
	"$CONFCHECK" "$T/o/bss-bcawl3.conf" "$T/o/bss-bcawl1.conf" "$T/o/bss-bcawl3-1.conf" > "$T/cc" 2>&1
	# akm bits (src/common/defs.h): IEEE8021X 0x1, IEEE8021X_SHA256 0x80
	check "hostapd reads the AKM/PMF the generator meant" "akm=0x1/mfp=0 akm=0x80/mfp=2 akm=0x81/mfp=1" \
		"$(grep -o 'akm=0x[0-9a-f]*/mfp=[0-9]' "$T/cc" | tr '\n' ' ' | sed 's/ $//')"
	# negative controls: hostapd must refuse 802.1X with no server, PMF
	# optional on 6 GHz, and an unparsable server address
	sed '/^auth_server_addr=/d' "$T/o/bss-bcawl3.conf" > "$T/bad4.conf"
	sed 's/^ieee80211w=2$/ieee80211w=1/' "$T/o/bss-bcawl2.conf" > "$T/bad5.conf"
	sed 's/^auth_server_addr=.*/auth_server_addr=radius.example/' "$T/o/bss-bcawl3.conf" > "$T/bad6.conf"
	check "hostapd refuses 802.1X without a server, PMF optional on 6 GHz, a host name" "FAIL FAIL FAIL" \
		"$("$CONFCHECK" "$T/bad4.conf" "$T/bad5.conf" "$T/bad6.conf" 2>/dev/null | grep -E '^(OK|FAIL) ' | cut -d' ' -f1 | tr '\n' ' ' | sed 's/ $//')"
fi
cp "$T/slots" "$T/slots.keep"
refuse1() {	# name, then the eap() args
	nm=$1; shift; eap "$@" > "$T/r"; refuse "$nm" "$T/r"
}
refuse1 "wpa2-eap on 6 GHz" 1 a wpa2-eap "5gl 6g" 5 192.0.2.10 secret1
refuse1 "eap without radius_server" 1 a wpa3-eap 2g 5 "" secret1
refuse1 "eap without radius_secret" 1 a wpa3-eap 2g 5 192.0.2.10 ""
refuse1 "eap with a host name" 1 a wpa3-eap 2g 5 radius.example secret1
refuse1 "eap with 0.0.0.0" 1 a wpa3-eap 2g 5 0.0.0.0 secret1
refuse1 "eap with a multicast server" 1 a wpa3-eap 2g 5 224.0.0.1 secret1
refuse1 "eap with an IPv6 multicast server" 1 a wpa3-eap 2g 5 ff02::1 secret1
refuse1 "eap with an IPv6 link-local server" 1 a wpa3-eap 2g 5 fe80::1 secret1
refuse1 "eap with a bad IPv6 address" 1 a wpa3-eap 2g 5 2001:db8::1::2 secret1
refuse1 "eap with a leading-zero octet" 1 a wpa3-eap 2g 5 192.0.2.010 secret1
refuse1 "radius_port 0" 1 a wpa3-eap 2g 5 192.0.2.10 secret1 radius_port=0
refuse1 "radius_port 65536" 1 a wpa3-eap 2g 5 192.0.2.10 secret1 radius_port=65536
refuse1 "eap with a passphrase" 1 a wpa3-eap 2g 5 192.0.2.10 secret1 passphrase=password1
refuse1 "accounting port without server" 1 a wpa3-eap 2g 5 192.0.2.10 secret1 radius_acct_port=1813
refuse1 "secret with a trailing space" 1 a wpa3-eap 2g 5 192.0.2.10 'secret1 '
refuse1 "secret of 129 characters" 1 a wpa3-eap 2g 5 192.0.2.10 "$(printf '%0129d' 0)"
{ net 1 a sae password1 2g 5; printf 'radius_server=192.0.2.10\n'; } > "$T/r"; refuse "radius_* on an SAE network" "$T/r"
eap 1 a wpa3-eap 2g 5 radius.example 'Very-Secret-X' > "$T/r"; printf 'radius_acct_secret=Acct-Secret-Y \n' >> "$T/r"; gen "$T/r"
check "a refused list never echoes a RADIUS secret" "1 no" \
	"$? $(grep -qE 'Very-Secret-X|Acct-Secret-Y' "$T/err" && echo yes || echo no)"
eap 1 a wpa3-eap 2g 5 192.0.2.10 'Very-Secret-X' > "$T/r"; gen "$T/r"
check "an accepted list never prints a RADIUS secret" "0 " "$? $(cat "$T/err")"

# ---- 10. max_clients, both ways (the awk string-truth trap: a key cut out
# of a line is a string, "0" is true; every numeric key is stored as v + 0) ----
cp "$T/slots" "$T/slots.keep"
{ net 1 a sae password1 "2g 5gl" 1; printf 'max_clients=1\n'; net 2 b sae password2 "2g" 2; } > "$T/m1"
rm -f "$T/slots"; gen "$T/m1"; check "max_clients=1: accepted" 0 $?
check "max_clients=1 -> max_num_sta=1 on both of its BSSes, none on the other network" "yes yes no" \
	"$(has bcawl3 max_num_sta=1) $(has bcawl0 max_num_sta=1) $(grep -q '^max_num_sta' "$T/o/sec-bcawl3-1" && echo yes || echo no)"
check "max_clients=1 also in the single-BSS config (ADD bss_config)" "1" "$(grep -c '^max_num_sta=1$' "$T/o/bss-bcawl0.conf")"
{ net 1 a sae password1 2g 1; printf 'max_clients=2007\n'; } > "$T/m2"
rm -f "$T/slots"; gen "$T/m2"; check "max_clients=2007 (the limit) -> max_num_sta=2007" "0 yes" "$? $(has bcawl3 max_num_sta=2007)"
conf_ok "max_clients"
for v in 0 2008 012 x -1; do
	{ net 1 a sae password1 2g 1; printf 'max_clients=%s\n' "$v"; } > "$T/r"; refuse "max_clients=$v" "$T/r"
done

# ---- 10b. airtime policy (hostapd CONFIG_AIRTIME_POLICY) ----
hdr_has() { grep -qx "$2" "$T/o/hdr-$1" && echo yes || echo no; }
{ printf 'radio=2g\nairtime=1\n'; net 1 a sae password1 "2g 5gl" 1
  printf 'airtime_sta_weight=02:00:5E:00:53:01 768\nairtime_sta_weight=02:00:5e:00:53:02 256\n'; } > "$T/a1"
rm -f "$T/slots"; gen "$T/a1"; check "airtime=1 + two station weights: accepted" 0 $?
check "airtime=1 -> airtime_mode=1 on that radio only" "yes no" "$(hdr_has bcawl3 airtime_mode=1) $(grep -q '^airtime_mode' "$T/o/hdr-bcawl0" && echo yes || echo no)"
check "station weights rendered (MAC lower case), in order" "airtime_sta_weight=02:00:5e:00:53:01 768|airtime_sta_weight=02:00:5e:00:53:02 256" \
	"$(grep '^airtime_sta_weight=' "$T/o/sec-bcawl3" | tr '\n' '|' | sed 's/|$//')"
check "no airtime line on the radio whose airtime is off" "" "$(grep '^airtime' "$T/o/sec-bcawl0")"
check "airtime=1 without airtime_weight: no airtime_bss_weight" "no" "$(grep -q '^airtime_bss_weight' "$T/o/sec-bcawl3" && echo yes || echo no)"
check "the single-BSS config carries the mode and the weights" "1 2" \
	"$(grep -c '^airtime_mode=1$' "$T/o/bss-bcawl3.conf") $(grep -c '^airtime_sta_weight=' "$T/o/bss-bcawl3.conf")"
conf_ok "airtime static"
# the string-truth trap, both ways: airtime=0 and airtime_limit=0 must render NOTHING
{ printf 'radio=2g\nairtime=0\n'; net 1 a sae password1 2g 1; printf 'airtime_weight=5\nairtime_limit=0\n'; } > "$T/a0"
rm -f "$T/slots"; gen "$T/a0"; check "airtime=0: accepted" 0 $?
check "airtime=0 -> no airtime_mode, no airtime_* in the section" "no " \
	"$(hdr_has bcawl3 airtime_mode=0) $(grep '^airtime' "$T/o/sec-bcawl3" "$T/o/hdr-bcawl3")"
{ printf 'radio=2g\nairtime=3\n'; net 1 a sae password1 2g 1; printf 'airtime_weight=3\nairtime_limit=1\n'
  net 2 b sae password2 2g 2; printf 'airtime_limit=0\n'; } > "$T/a3"
rm -f "$T/slots"; gen "$T/a3"; check "airtime=3, two networks: accepted" 0 $?
check "airtime=3 -> airtime_mode=3" "yes" "$(hdr_has bcawl3 airtime_mode=3)"
check "airtime_weight=3 airtime_limit=1 -> bss weight 3, limited" "yes yes" "$(has bcawl3 airtime_bss_weight=3) $(has bcawl3 airtime_bss_limit=1)"
check "airtime_limit=0 -> not limited; no weight given -> airtime_bss_weight=1 (needed in 2|3)" "no yes" \
	"$(has bcawl3-1 airtime_bss_limit=1) $(has bcawl3-1 airtime_bss_weight=1)"
conf_ok "airtime limit"
rm -f "$T/slots"; gen "$T/a0"	# the refusals below compare the slot file with this one-network state
for v in 4 -1 x 01; do
	{ printf 'radio=2g\nairtime=%s\n' "$v"; net 1 a sae password1 2g 1; } > "$T/r"; refuse "airtime=$v" "$T/r"
done
for v in 0 1001 x 07; do
	{ net 1 a sae password1 2g 1; printf 'airtime_weight=%s\n' "$v"; } > "$T/r"; refuse "airtime_weight=$v" "$T/r"
done
{ net 1 a sae password1 2g 1; printf 'airtime_limit=2\n'; } > "$T/r"; refuse "airtime_limit=2" "$T/r"
for v in "02:00:5e:00:53:01" "02:00:5e:00:53:01 0" "02:00:5e:00:53:01 65536" "03:00:5e:00:53:01 5" "02:00:5e:00:53 5" "02:00:5e:00:53:01 5 6"; do
	{ net 1 a sae password1 2g 1; printf 'airtime_sta_weight=%s\n' "$v"; } > "$T/r"; refuse "airtime_sta_weight=$v" "$T/r"
done
{ net 1 a sae password1 2g 1; printf 'airtime_sta_weight=02:00:5e:00:53:01 5\nairtime_sta_weight=02:00:5E:00:53:01 6\n'; } > "$T/r"
refuse "one station weighted twice" "$T/r"
{ net 1 a sae password1 2g 1; i=0; while [ $i -lt 65 ]; do printf 'airtime_sta_weight=02:00:5e:00:%02x:%02x 5\n' $((i / 256)) $((i % 256)); i=$((i + 1)); done; } > "$T/r"
refuse "65 station weights in one network" "$T/r"

# ---- 10b2. OWE: no PMKSA caching (open-wifi ledger FSEC-N2) ----
{ printf 'network=1\nssid=o\nsecurity=owe\nbands=2g 6g\nvlan=1\n'
  printf 'network=2\nssid=oo\nsecurity=open-owe\nbands=2g 6g\nvlan=2\n'
  net 3 s sae password3 "2g 6g" 3; net 4 p psk2 password4 2g 4; } > "$T/ow"
rm -f "$T/slots"; gen "$T/ow"; check "owe, open-owe, sae, psk2: accepted" 0 $?
ifo() { awk -v n="$1" -v d="$2" '$1 == "bss" && $5 == n && $2 == d { print $3 }' "$T/o/plan"; }
check "OWE (2g, 6g) and open-owe on 6 GHz (OWE there): disable_pmksa_caching=1" "yes yes yes" \
	"$(has "$(ifo 1 bcawl3)" disable_pmksa_caching=1) $(has "$(ifo 1 bcawl2)" disable_pmksa_caching=1) $(has "$(ifo 2 bcawl2)" disable_pmksa_caching=1)"
check "open-owe on 2.4 GHz (open), SAE, WPA2: no disable_pmksa_caching" "" \
	"$(grep -l '^disable_pmksa_caching' "$T/o/sec-$(ifo 2 bcawl3)" "$T/o/sec-$(ifo 3 bcawl3)" "$T/o/sec-$(ifo 3 bcawl2)" "$T/o/sec-$(ifo 4 bcawl3)" 2>/dev/null)"
check "the single-BSS config of an OWE BSS carries it too" 1 "$(grep -c '^disable_pmksa_caching=1$' "$T/o/bss-$(ifo 1 bcawl2).conf")"
conf_ok "owe pmksa"

# ---- 10b3. DFS channels need the country (IEEE 802.11h); soak 1102-1259:
# 5gh ch100 without a country never started ----
{ printf 'radio=5gh\nchannel=100\nwidth=20\n'; net 1 a sae password1 "5gl 5gh" 1; } > "$T/d0"
rm -f "$T/slots"; gen "$T/d0" -c; check "5gh ch100, no country: accepted, warned, no ieee80211h" "0 yes no" \
	"$? $(grep -q '5gh: channel 100 is a DFS (radar) channel and the list has no country=' "$T/err" && echo yes || echo no) $(hdr_has bcawl1 ieee80211h=1)"
check "5gl ch36 (not DFS): no warning" "no" "$(grep -q '5gl: channel 36 is a DFS' "$T/err" && echo yes || echo no)"
{ printf 'country=DE\nradio=5gh\nchannel=100\nwidth=20\n'; net 1 a sae password1 "5gl 5gh" 1; } > "$T/d1"
rm -f "$T/slots"; gen "$T/d1" -c; check "5gh ch100 + country=DE + -c: no warning; country_code, 11d, 11h on 5gh" "0 no yes yes yes" \
	"$? $(grep -q 'DFS (radar)' "$T/err" && echo yes || echo no) $(hdr_has bcawl1 country_code=DE) $(hdr_has bcawl1 ieee80211d=1) $(hdr_has bcawl1 ieee80211h=1)"
conf_ok "5gh ch100 DFS with country"
if [ -n "$CONFCHECK" ]; then
	sed '/^\(country_code\|ieee80211d\)=/d' "$T/o/hostapd-bcawl1.conf" > "$T/d1-no11d.conf"
	"$CONFCHECK" "$T/d1-no11d.conf" > "$T/d1cc" 2>&1
	check "control: hostapd refuses ieee80211h without 11d/country (why the country is required)" "1 yes" \
		"$(grep -c '^FAIL ' "$T/d1cc") $(grep -q '802.11h without' "$T/d1cc" && echo yes || echo no)"
fi
rm -f "$T/slots"; gen "$T/d1"; check "country=DE without -c (no regdb): warned" "0 yes" \
	"$? $(grep -q '5gh: channel 100 is a DFS (radar) channel and the regulatory database is not loaded' "$T/err" && echo yes || echo no)"
{ printf 'radio=5gh\nchannel=100\nmonitor=1\n'; net 1 a sae password1 "5gl 5gh" 1; } > "$T/d2"
rm -f "$T/slots"; gen "$T/d2" -c; check "a monitor on ch100: no DFS warning" "no" "$(grep -q 'DFS (radar)' "$T/err" && echo yes || echo no)"

# ---- 10b4. 6 GHz secondaries = the anchor's nontransmitted BSSIDs (soak
# 1102-1500: OWE on bcawl2-1 unreachable) ----
{ net 1 s sae password1 "5gl 6g" 1; printf 'network=2\nssid=o\nsecurity=owe\nbands=5gl 6g\nvlan=2\n'; } > "$T/m6"
rm -f "$T/slots"; gen "$T/m6"; check "sae + owe on 5gl and 6g: accepted" 0 $?
check "6g: anchor = radio address, the OWE secondary = radio octets 0-4, index 1 (00:00:5e:00:53:ad)" "00:00:5e:00:53:ac 00:00:5e:00:53:ad" \
	"$(bssid_of bcawl2) $(bssid_of bcawl2-1)"
check "5gl (control): the secondary keeps the LA-prefixed block (octet 0 != the radio's)" "yes" \
	"$([ "$(bssid_of bcawl0-1 | cut -d: -f1)" != 00 ] && [ "$(bssid_of bcawl0-1 | cut -d: -f2-5)" = 00:5e:00:53 ] && echo yes || echo no)"
check "6g: the secondary's section carries that bssid=" "yes" "$(has bcawl2-1 bssid=00:00:5e:00:53:ad)"
bssid_rules "6g nontransmitted"
# a 6g index that would land on another radio's address is skipped (5gl = :a4 is
# in the 6g block only if the blocks overlap; here: 6g radio :a8, 5gl radio :ac)
M0=$M; M="2g=00:00:5e:00:53:a0 5gl=00:00:5e:00:53:ac 5gh=00:00:5e:00:53:a4 6g=00:00:5e:00:53:a8"
{ for i in 1 2 3 4 5; do net $i n$i sae password$i 6g $i; done; } > "$T/m6b"
rm -f "$T/slots"; gen "$T/m6b" -C 8; check "6g radio :a8, 5gl radio :ac in its block: 5 BSSes, none on :ac" "0 5 no" \
	"$? $(awk '$1 == "bss" && $2 == "bcawl2"' "$T/o/plan" | wc -l | tr -d ' ') $(awk '$1 == "bss" { print $7 }' "$T/o/plan" | grep -qx 00:00:5e:00:53:ac && echo yes || echo no)"
bssid_rules "6g block shared with a radio"
M=$M0
conf_ok "6g nontransmitted"

# ---- 10c. radio features: HE (ax=), TWT responder (twt=), zero-wait DFS
# (zwdfs=), monitor (monitor=), LED (led=) ----
# HE/EHT (ax=, be=): default both on, every radio; each off both ways
{ printf 'radio=2g\nax=1\nradio=5gl\nchannel=36\nwidth=80\nradio=5gh\nchannel=100\nwidth=40\n'
  net 1 a sae password1 "2g 5gl 5gh" 1; } > "$T/x1"
rm -f "$T/slots"; gen "$T/x1"; check "ax=1 on 2g, no ax key on 5gl/5gh: accepted" 0 $?
check "default: ieee80211ax=1 and ieee80211be=1 on 2g, 5gl and 5gh, once each" "1 1 1 1 1 1" \
	"$(for d in bcawl3 bcawl0 bcawl1; do grep -c '^ieee80211ax=1$' "$T/o/hdr-$d"; grep -c '^ieee80211be=1$' "$T/o/hdr-$d"; done | tr '\n' ' ' | sed 's/ $//')"
check "5gl EHT at 80 MHz: eht_oper width/centre = the VHT ones (1/42); 5gh at 40: eht_oper_chwidth=0, no centre" "yes yes yes no" \
	"$(hdr_has bcawl0 eht_oper_chwidth=1) $(hdr_has bcawl0 eht_oper_centr_freq_seg0_idx=42) $(hdr_has bcawl1 eht_oper_chwidth=0) $(grep -q '^eht_oper_centr' "$T/o/hdr-bcawl1" && echo yes || echo no)"
check "2g EHT at 20 MHz: no operation width lines" "" "$(grep -E '^(he|eht)_oper' "$T/o/hdr-bcawl3")"
{ printf 'radio=2g\nax=1\nbe=0\nwidth=40\nradio=5gl\nax=0\nchannel=36\nwidth=80\nradio=5gh\nax=1\nbe=1\nchannel=100\nwidth=80\n'
  net 1 a sae password1 "2g 5gl 5gh" 1; } > "$T/xb"
rm -f "$T/slots"; gen "$T/xb"; check "2g ax=1 be=0 (40 MHz), 5gl ax=0 (be follows), 5gh ax=1 be=1: accepted" 0 $?
check "be=0 (a string \"0\"): 2g HE without EHT; ax=0: 5gl neither, nor any he/eht_oper line; 5gh both" "1 0 0 0 - 1 1" \
	"$(grep -c '^ieee80211ax=1$' "$T/o/hdr-bcawl3") $(grep -c '^ieee80211be' "$T/o/hdr-bcawl3") $(grep -c '^ieee80211ax' "$T/o/hdr-bcawl0") $(grep -c '^ieee80211be' "$T/o/hdr-bcawl0") -$(grep -E '^(he|eht)_oper' "$T/o/hdr-bcawl0") $(grep -c '^ieee80211ax=1$' "$T/o/hdr-bcawl1") $(grep -c '^ieee80211be=1$' "$T/o/hdr-bcawl1")"
check "ax=0: still VHT 80 (vht_oper_chwidth=1, centre 42)" "yes yes" "$(hdr_has bcawl0 vht_oper_chwidth=1) $(hdr_has bcawl0 vht_oper_centr_freq_seg0_idx=42)"
conf_ok "ax/be off"
if [ -n "$CONFCHECK" ]; then
	"$CONFCHECK" "$T"/o/hostapd-*.conf > "$T/ccb" 2>/dev/null
	check "hostapd reads 5gl ax=0 as HE/EHT off, 5gh as EHT 80 MHz centre 106" "be=0/ be=1/1/106" \
		"$(grep 'hostapd-bcawl0.conf' "$T/ccb" | grep -o 'be=0/') $(grep 'hostapd-bcawl1.conf' "$T/ccb" | grep -o 'be=1/1/106')"
fi
rm -f "$T/slots"; gen "$T/x1"	# back to the default list
check "5gl HE at 80 MHz: HE width/centre = the VHT ones (36 -> 42)" "yes yes" \
	"$(hdr_has bcawl0 he_oper_chwidth=1) $(hdr_has bcawl0 he_oper_centr_freq_seg0_idx=42)"
check "no he_twt_responder line by default (hostapd's own default: on)" "" "$(grep -h '^he_twt_responder' "$T"/o/hdr-*)"
check "default led=1 on every radio of -d, in band order" "led 2g bcawl3 1|led 5gl bcawl0 1|led 5gh bcawl1 1|led 6g bcawl2 1" \
	"$(grep '^led ' "$T/o/plan" | tr '\n' '|' | sed 's/|$//')"
check "no monitor line without monitor=1" "" "$(grep '^monitor ' "$T/o/plan")"
conf_ok "ax"
{ printf 'radio=5gh\nchannel=100\nwidth=40\n'; net 1 a sae password1 5gh 1; } > "$T/x2"
rm -f "$T/slots"; gen "$T/x2"; check "5gh HE at 40 MHz: he_oper_chwidth=0, no HE centre" "yes no" \
	"$(hdr_has bcawl1 he_oper_chwidth=0) $(grep -q '^he_oper_centr' "$T/o/hdr-bcawl1" && echo yes || echo no)"
{ printf 'radio=6g\nax=1\ntwt=0\nradio=2g\ntwt=1\nradio=5gl\ntwt=0\n'; net 1 a sae password1 "2g 5gl 6g" 1; } > "$T/x3"
rm -f "$T/slots"; gen "$T/x3"; check "6g ax=1 (implicit anyway) + twt on three radios: accepted" 0 $?
check "6g: one ieee80211ax=1 line" 1 "$(grep -c '^ieee80211ax=1$' "$T/o/hdr-bcawl2")"
check "twt=0 -> he_twt_responder=0 (6g, 5gl); twt=1 -> no line (2g)" "yes yes no" \
	"$(hdr_has bcawl2 he_twt_responder=0) $(hdr_has bcawl0 he_twt_responder=0) $(grep -q '^he_twt_responder' "$T/o/hdr-bcawl3" && echo yes || echo no)"
check "the single-BSS config carries he_twt_responder=0 too" 1 "$(grep -c '^he_twt_responder=0$' "$T/o/bss-bcawl2.conf")"
conf_ok "twt"
{ printf 'radio=5gl\nzwdfs=1\nchannel=52\nwidth=80\nradio=5gh\nzwdfs=0\n'; net 1 a sae password1 "5gl 5gh" 1; } > "$T/x4"
rm -f "$T/slots"; gen "$T/x4"; check "zwdfs=1 on 5gl, zwdfs=0 on 5gh: accepted" 0 $?
check "zwdfs=1 -> enable_background_radar=1 on 5gl only (zwdfs=0: none)" "yes no" \
	"$(hdr_has bcawl0 enable_background_radar=1) $(grep -q '^enable_background_radar' "$T/o/hdr-bcawl1" && echo yes || echo no)"
gen "$T/x4" -c; conf_ok "zwdfs"
# monitor: the radio carries no BSS, its networks keep their slots
{ net 1 a sae password1 "2g 5gh" 1; net 2 b sae password2 5gh 2; } > "$T/x5"
rm -f "$T/slots"; gen "$T/x5"; check "monitor control: 5gh carries two BSSes" "bcawl1 bcawl1-1" \
	"$(awk '$1 == "bss" && $2 == "bcawl1" { print $3 }' "$T/o/plan" | tr '\n' ' ' | sed 's/ $//')"
{ printf 'radio=5gh\nmonitor=1\nchannel=149\nwidth=80\n'; cat "$T/x5"; } > "$T/x6"
gen "$T/x6"; check "monitor=1 on 5gh: accepted, warned" "0 yes" "$? $(grep -q '5gh (bcawl1) is a monitor' "$T/err" && echo yes || echo no)"
check "monitor=1: no BSS and no config on bcawl1, 2g untouched" "- none bcawl3" \
	"-$(awk '$1 == "bss" && $2 == "bcawl1"' "$T/o/plan") $(ls "$T"/o/*bcawl1* 2>/dev/null || echo none) $(awk '$1 == "bss" { print $3 }' "$T/o/plan" | tr '\n' ' ' | sed 's/ $//')"
check "monitor line: 5gh bcawl1 149 (5745 MHz) at 80, centre 155 (5775 MHz)" "monitor 5gh bcawl1 5745 80 5775" "$(grep '^monitor ' "$T/o/plan")"
check "monitor=1: the 5gh slots are kept" "5gh 0 1 0|5gh 1 2 1" "$(grep '^5gh ' "$T/slots" | tr '\n' '|' | sed 's/|$//')"
gen "$T/x5"; check "monitor off again: the same two BSSes" "bcawl1 bcawl1-1" \
	"$(awk '$1 == "bss" && $2 == "bcawl1" { print $3 }' "$T/o/plan" | tr '\n' ' ' | sed 's/ $//')"
{ printf 'radio=5gh\nmonitor=0\n'; cat "$T/x5"; } > "$T/x7"
gen "$T/x7"; check "monitor=0 (a string \"0\"): BSSes rendered, no monitor line" "2 0" \
	"$(awk '$1 == "bss" && $2 == "bcawl1"' "$T/o/plan" | wc -l | tr -d ' ') $(grep -c '^monitor ' "$T/o/plan")"
mon() {	# band channel width -> the monitor line
	printf 'radio=%s\nmonitor=1\nchannel=%s\nwidth=%s\n' "$1" "$2" "$3" > "$T/xm"; net 1 a sae password1 2g 1 >> "$T/xm"
	rm -f "$T/slots"; [ "$1" = 2g ] && { printf 'radio=%s\nmonitor=1\nchannel=%s\nwidth=%s\n' "$1" "$2" "$3"; net 1 a sae password1 5gl 1; } > "$T/xm"
	gen "$T/xm" && grep '^monitor ' "$T/o/plan"
}
check "monitor freq/centre: 2g 6/40, 2g 11/40, 5gl 40/40, 6g 37/320, 6g 5/20" \
	"monitor 2g bcawl3 2437 40 2447|monitor 2g bcawl3 2462 40 2452|monitor 5gl bcawl0 5200 40 5190|monitor 6g bcawl2 6135 320 6105|monitor 6g bcawl2 5975 20 5975" \
	"$({ mon 2g 6 40; mon 2g 11 40; mon 5gl 40 40; mon 6g 37 320; mon 6g 5 20; } | tr '\n' '|' | sed 's/|$//')"
{ printf 'radio=5gh\nmonitor=1\nenabled=0\n'; net 1 a sae password1 5gh 1; } > "$T/x8"
rm -f "$T/slots"; gen "$T/x8"; check "monitor=1 with enabled=0: no monitor" "0 0" "$? $(grep -c '^monitor ' "$T/o/plan")"
{ printf 'radio=2g\nled=0\nradio=6g\nled=1\n'; net 1 a sae password1 2g 1; } > "$T/x9"
rm -f "$T/slots"; gen "$T/x9"; check "led=0 on 2g (a string \"0\"), led=1 on 6g" "led 2g bcawl3 0|led 6g bcawl2 1" \
	"$(grep -E '^led (2g|6g) ' "$T/o/plan" | tr '\n' '|' | sed 's/|$//')"
rm -f "$T/slots"; gen "$T/x9"; cp "$T/slots.keep" "$T/slots.keep0"; cp "$T/slots" "$T/slots.keep"	# refuse() compares with this state
for kv in 'radio=6g ax=0' 'radio=2g ax=2' 'radio=5gl be=2' 'radio=5gl twt=x' 'radio=2g zwdfs=1' 'radio=6g zwdfs=1' 'radio=5gl zwdfs=01' \
	'radio=5gh monitor=yes' 'radio=2g led=2'; do
	{ printf '%s\n%s\n' "${kv%% *}" "${kv#* }"; net 1 a sae password1 2g 1; } > "$T/r"; refuse "$kv" "$T/r"
done
{ net 1 a sae password1 2g 1; printf 'twt=1\n'; } > "$T/r"; refuse "network twt=1 (TWT is radio-wide)" "$T/r"
{ printf 'radio=5gl\nax=0\nbe=1\n'; net 1 a sae password1 2g 1; } > "$T/r"; refuse "be=1 with ax=0 (EHT needs HE)" "$T/r"
{ printf 'radio=6g\nbe=0\nchannel=37\nwidth=320\n'; net 1 a sae password1 6g 1; } > "$T/r"; refuse "6g be=0 at 320 MHz" "$T/r"
mv "$T/slots.keep0" "$T/slots.keep"

# ---- 11. -F: what the generator supports ----
check "-F: exit 0 without -n/-o" 0 "$($SH "$G" -F > "$T/feat" 2>&1; echo $?)"
check "-F: schedule and max_clients on, 6g up to 320 MHz, twt/wds not yet" \
	"feature schedule 1|feature max_clients 1|width 6g 20 40 80 160 320|width 5gl 20 40 80|feature twt 0|feature wds 0|feature width320 1" \
	"$(for k in 'feature schedule ' 'feature max_clients ' 'width 6g ' 'width 5gl ' 'feature twt ' 'feature wds ' 'feature width320 '; do grep "^$k" "$T/feat"; done | tr '\n' '|' | sed 's/|$//')"
check "-F: the radio features he, eht, twt_responder, zwdfs, monitor, led" \
	"feature he 1|feature eht 1|feature twt_responder 1|feature zwdfs 1|feature monitor 1|feature led 1|" \
	"$(for k in he eht twt_responder zwdfs monitor led; do grep "^feature $k " "$T/feat"; done | tr '\n' '|')"
check "-F: feature airtime 1" "feature airtime 1" "$(grep '^feature airtime' "$T/feat")"
check "-F: station and routed networks, the station security modes" "feature station 1|feature routed 1|station_security psk2 sae" \
	"$(grep -E '^(feature (station|routed)|station_security) ' "$T/feat" | tr '\n' '|' | sed 's/|$//')"
check "-F: the security list is the one the checks take" "open owe open-owe psk2 psk2sae sae wpa2-eap wpa3-eap wpa2-wpa3-eap" \
	"$(sed -n 's/^security //p' "$T/feat")"
# the manifest both ways: every band x width the generator accepts on the
# band's default channel is listed by -F, and nothing else
cp "$T/slots" "$T/slots.f"	# restored after 11b (the refusals below compare to it)
for b in 2g 5gl 5gh 6g; do
	listed=$(sed -n "s/^width $b //p" "$T/feat")
	took=''
	for w in 20 40 60 80 160 320; do
		{ printf 'radio=%s\nwidth=%s\n' "$b" "$w"; net 1 a sae password1 "$b" 1; } > "$T/r"
		rm -f "$T/slots"; gen "$T/r" && took="$took $w"
	done
	check "-F: width $b lists exactly what the generator accepts" "$listed" "${took# }"
done

# ---- 11b. 6 GHz widths: op_class + HE/EHT centre indices ----
# expected values by hand from 802.11ax Annex E / 802.11be (op_class 131-134,
# 137; blocks from channel 1; 320-1 centres 31/95/159 first, else 320-2 191)
w6() {	# channel width [be] -> the 6g radio lines after channel=
	{ printf 'radio=6g\nchannel=%s\nwidth=%s\n%s' "$1" "$2" "${3:+be=$3
}"; net 1 a sae password1 6g 1; } > "$T/w6"
	rm -f "$T/slots"; gen "$T/w6" || { echo refused; return; }
	grep -E '^(op_class|he_oper|ieee80211be|eht_oper)' "$T/o/hdr-bcawl2" | tr '\n' ' ' | sed 's/ $//'
}
for t in \
	"37 20|op_class=131" \
	"37 40|op_class=132 he_oper_chwidth=0 he_oper_centr_freq_seg0_idx=35" \
	"37 80|op_class=133 he_oper_chwidth=1 he_oper_centr_freq_seg0_idx=39" \
	"37 160|op_class=134 he_oper_chwidth=2 he_oper_centr_freq_seg0_idx=47" \
	"37 320|op_class=137 he_oper_chwidth=2 he_oper_centr_freq_seg0_idx=47 ieee80211be=1 eht_oper_chwidth=9 eht_oper_centr_freq_seg0_idx=31" \
	"33 160|op_class=134 he_oper_chwidth=2 he_oper_centr_freq_seg0_idx=47" \
	"33 320|op_class=137 he_oper_chwidth=2 he_oper_centr_freq_seg0_idx=47 ieee80211be=1 eht_oper_chwidth=9 eht_oper_centr_freq_seg0_idx=31" \
	"1 40|op_class=132 he_oper_chwidth=0 he_oper_centr_freq_seg0_idx=3" \
	"5 80|op_class=133 he_oper_chwidth=1 he_oper_centr_freq_seg0_idx=7" \
	"1 320|op_class=137 he_oper_chwidth=2 he_oper_centr_freq_seg0_idx=15 ieee80211be=1 eht_oper_chwidth=9 eht_oper_centr_freq_seg0_idx=31" \
	"65 320|op_class=137 he_oper_chwidth=2 he_oper_centr_freq_seg0_idx=79 ieee80211be=1 eht_oper_chwidth=9 eht_oper_centr_freq_seg0_idx=95" \
	"189 320|op_class=137 he_oper_chwidth=2 he_oper_centr_freq_seg0_idx=175 ieee80211be=1 eht_oper_chwidth=9 eht_oper_centr_freq_seg0_idx=159" \
	"193 320|op_class=137 he_oper_chwidth=2 he_oper_centr_freq_seg0_idx=207 ieee80211be=1 eht_oper_chwidth=9 eht_oper_centr_freq_seg0_idx=191" \
	"221 320|op_class=137 he_oper_chwidth=2 he_oper_centr_freq_seg0_idx=207 ieee80211be=1 eht_oper_chwidth=9 eht_oper_centr_freq_seg0_idx=191" \
	"213 80|op_class=133 he_oper_chwidth=1 he_oper_centr_freq_seg0_idx=215" \
	"229 40|op_class=132 he_oper_chwidth=0 he_oper_centr_freq_seg0_idx=227" \
	"233 20|op_class=131" \
	"225 80|refused"; do
	# the table is HE-only (be=0); by default (be=1) the EHT lines follow
	# the HE ones below 320 MHz (the same centre), at 20 MHz only be=1
	he=${t#*|}; cw=${t%%|*}
	case "$he" in
	refused|*ieee80211be*) eht=$he ;;
	op_class=131) eht="$he ieee80211be=1" ;;
	*) eht="$he ieee80211be=1 $(echo "$he" | sed 's/.*he_oper_chwidth=\([0-9]*\) he_oper_centr_freq_seg0_idx=\([0-9]*\).*/eht_oper_chwidth=\1 eht_oper_centr_freq_seg0_idx=\2/')" ;;
	esac
	check "6g ch $cw MHz (default be=1)" "$eht" "$(w6 $cw)"
	case "$cw" in *320) check "6g ch $cw MHz be=0: refused" refused "$(w6 $cw 0)" ;;
	*) check "6g ch $cw MHz be=0" "$he" "$(w6 $cw 0)" ;; esac
done
# every 6 GHz channel x width: accepted iff the band has the block
# (59 channels; blocks: 29 x 40, 14 x 80, 7 x 160, 56 channels under 320);
# EHT only at 320; with hostapd, its own reading of every config
mkdir -p "$T/w6all"; rm -f "$T"/w6all/*
acc=''
for w in 20 40 80 160 320; do
	k=0
	c=1; while [ $c -le 233 ]; do
		{ printf 'radio=6g\nchannel=%s\nwidth=%s\n' "$c" "$w"; net 1 a sae password1 6g 1; } > "$T/w6"
		rm -f "$T/slots"
		if gen "$T/w6"; then
			k=$((k + 1)); cp "$T/o/hostapd-bcawl2.conf" "$T/w6all/c$c-w$w.conf"
		fi
		c=$((c + 4))
	done
	acc="$acc $w:$k"
done
check "6g: channels accepted per width" "20:59 40:58 80:56 160:56 320:56" "${acc# }"
check "6g: ieee80211be=1 in every config by default (285), eht_oper_chwidth=9 at 320 only (56)" "285 56 0" \
	"$(grep -l '^ieee80211be=1$' "$T"/w6all/*.conf | wc -l | tr -d ' ') $(grep -l '^eht_oper_chwidth=9$' "$T"/w6all/*.conf | grep -c 'w320\.conf$') $(grep -l '^eht_oper_chwidth=9$' "$T"/w6all/*.conf | grep -vc 'w320\.conf$')"
# hostapd reads the width from the op_class AND from the centre index it puts
# on the air (bw6=<op_class MHz>/<centre index MHz>/<index>): both must be
# the asked width, and the primary channel inside the block; at 320 the HE
# half (he=2/<idx>) must be the 160 MHz block of the primary
bw6_bad() {	# confcheck output on stdin -> one line per config that fails
	awk '/^OK / {
		f = $2; sub(/.*\/c/, "", f); split(f, cw, /-w|\.conf/); ch = cw[1] + 0; w = cw[2] + 0
		bw = ""; he = ""
		for (i = 3; i <= NF; i++) { if ($i ~ /^bw6=/) bw = substr($i, 5); if ($i ~ /^he=/) he = substr($i, 4) }
		if (split(bw, p, "/") != 3) { print "c" ch "/" w ": no bw6"; next }
		half = w / 10 - 2; d = ch - p[3]; if (d < 0) d = -d
		if (p[1] + 0 != w || p[2] + 0 != w || d > half) { print "c" ch "/" w ": " bw; next }
		if (w == 320) {
			split(he, h, "/"); d = ch - h[2]; if (d < 0) d = -d
			if (h[1] + 0 != 2 || d > 14) print "c" ch "/320: he " he
		}
	} /^FAIL / { print $0 }'
}
if [ -n "$CONFCHECK" ]; then
	"$CONFCHECK" "$T"/w6all/*.conf > "$T/cc6" 2>/dev/null
	check "hostapd parses the 285 6 GHz channel x width configs" "285 0" "$(grep -c '^OK ' "$T/cc6") $(grep -c '^FAIL ' "$T/cc6")"
	check "hostapd reads each at its width, primary inside the block" "" "$(bw6_bad < "$T/cc6" | head -5 | tr '\n' ' ')"
	# the instrument's negative controls: EHT off at 320 (hostapd then runs
	# the HE 160 index), an 80 MHz config with the 160 index, a primary
	# outside its block: each must be flagged
	mkdir -p "$T/w6bad"; rm -f "$T"/w6bad/*
	sed '/^ieee80211be=1$/d' "$T/w6all/c37-w320.conf" > "$T/w6bad/c37-w320.conf"
	# (be=1: hostapd reads the EHT centre, so both indices get the 160 one)
	sed 's/^\(he\|eht\)_oper_centr_freq_seg0_idx=39$/\1_oper_centr_freq_seg0_idx=47/' "$T/w6all/c37-w80.conf" > "$T/w6bad/c37-w80.conf"
	sed 's/^channel=37$/channel=53/' "$T/w6all/c37-w80.conf" > "$T/w6bad/c53-w80.conf"
	# only the EHT centre wrong: hostapd must read it (be=1 takes the width from it)
	sed 's/^eht_oper_centr_freq_seg0_idx=39$/eht_oper_centr_freq_seg0_idx=47/' "$T/w6all/c37-w80.conf" > "$T/w6bad/c37-w80e.conf"
	check "negative controls: no EHT at 320, a 160 index at 80 (HE+EHT, EHT alone), a primary off its block: 4 flagged" 4 \
		"$("$CONFCHECK" "$T"/w6bad/*.conf 2>/dev/null | bw6_bad | wc -l | tr -d ' ')"
else
	echo "skip hostapd 6 GHz width reading (no hostapd-confcheck)"
fi
cp "$T/slots.f" "$T/slots"
# net 1 always on (2g); net 2 weekdays 08-18 (2g 5gl); net 3 on 5gh, whose
# radio runs 22:00-06:00 every day
{
	printf 'radio=5gh\nschedule=daily@22:00-06:00\n'
	net 1 always sae password1 2g 1
	net 2 office sae password2 "2g 5gl" 2; printf 'schedule=weekdays@08:00-18:00\n'
	net 3 night sae password3 5gh 3
} > "$T/s1"
q() { $SH "$G" -n "$T/s1" -Q "$@" 2> "$T/err" | tr '\n' ' ' | sed 's/ $//'; }
check "-Q without -T: every schedule on" "net 2 on radio 5gh on" "$(q)"
check "-Q Mon 09:00" "net 2 on radio 5gh off" "$(q -T '1 09:00')"
check "-Q Mon 07:59 (before the window)" "net 2 off radio 5gh off" "$(q -T '1 07:59')"
check "-Q Mon 08:00 (start inclusive)" "net 2 on" "$(q -T '1 08:00' | cut -d' ' -f1-3)"
check "-Q Mon 18:00 (end exclusive)" "net 2 off" "$(q -T '1 18:00' | cut -d' ' -f1-3)"
check "-Q Sat 09:00 (weekdays only)" "net 2 off" "$(q -T '6 09:00' | cut -d' ' -f1-3)"
check "-Q past midnight: Tue 23:00 on, Wed 05:59 on, Wed 06:00 off, Mon 05:00 on (from Sunday)" "on on off on" \
	"$(for t in '2 23:00' '3 05:59' '3 06:00' '1 05:00'; do q -T "$t" | awk '{ print $NF }'; done | tr '\n' ' ' | sed 's/ $//')"
{ net 1 a sae password1 2g 1; printf 'schedule=fri-mon@10:00-11:00, wed@22:00-02:00\n'; } > "$T/s2"
check "-Q day range wraps (fri-mon), a day's window runs into the next day only" "on on off on on off off" \
	"$(for t in '7 10:30' '1 10:59' '2 10:30' '3 23:00' '4 01:59' '4 02:00' '3 01:00'; do $SH "$G" -n "$T/s2" -Q -T "$t" | awk '{ print $NF }'; done | tr '\n' ' ' | sed 's/ $//')"
rm -rf "$T/qo"; cp "$T/slots" "$T/slots.q" 2>/dev/null || : > "$T/slots.q"; cp "$T/slots.q" "$T/slots.q0"
$SH "$G" -n "$T/s1" -Q -T '1 09:00' -o "$T/qo" -s "$T/slots.q" -m "$M" > /dev/null 2>&1
check "-Q writes nothing (no OUTDIR, slot file untouched)" "no same" "$([ -e "$T/qo" ] && echo yes || echo no) $(cmp -s "$T/slots.q" "$T/slots.q0" && echo same || echo changed)"
for v in 'mon@25:00-26:00' 'xyz@08:00-09:00' 'mon@08:00-08:00' 'mon-mon@08:00-09:00' 'mon@8:00-09:00' \
	'mon@24:00-02:00' 'Mon@08:00-09:00' 'mon08:00-09:00' 'mon@08:00' 'mon@08:00-09:00-10:00' 'tue-wed-thu@08:00-09:00'; do
	{ net 1 a sae password1 2g 1; printf 'schedule=%s\n' "$v"; } > "$T/r"; refuse "schedule=$v" "$T/r"
done
{ printf 'radio=2g\nschedule=daily\n'; net 1 a sae password1 2g 1; } > "$T/r"; refuse "radio schedule=daily (no time)" "$T/r"
check "a refused schedule is named" "yes" "$(grep -q 'schedule=daily refused' "$T/err" && echo yes || echo no)"
$SH "$G" -n "$T/s1" -Q -T '8 09:00' > /dev/null 2>&1; check "-T weekday 8 refused" 1 $?
$SH "$G" -n "$T/s1" -Q -T '1 24:00' > /dev/null 2>&1; check "-T 24:00 refused" 1 $?
{ net 1 a sae password1 2g 1; printf 'schedule=\n'; } > "$T/r"
rm -f "$T/slots"; gen "$T/r" -T '1 03:00'; check "schedule= (empty): always on, no sched line" "0 bcawl3 " "$? $(plan_bss | cut -d' ' -f1) $(cat "$T/o/sched")"

# render: all on first (sticky slots), then office off on a Saturday
rm -f "$T/slots"; gen "$T/s1"; check "s1 without -T: accepted" 0 $?
check "s1 all on: office 2g slot 1, 5gl anchor; night on 5gh" "bcawl3 0 1 0 bcawl3-1 1 2 1 bcawl0 0 2 0 bcawl1 0 3 0" \
	"$(plan_bss | cut -d' ' -f1-4 | tr '\n' ' ' | sed 's/ $//')"
check "sched file = the -Q state" "net 2 on radio 5gh on" "$(tr '\n' ' ' < "$T/o/sched" | sed 's/ $//')"
b_office=$(bssid_of bcawl3-1)
gen "$T/s1" -T '6 12:00'; check "Sat 12:00: accepted" 0 $?
check "Sat 12:00: office and the 5gh radio not rendered, always kept" "bcawl3 0 1 0" "$(plan_bss | cut -d' ' -f1-4 | tr '\n' ' ' | sed 's/ $//')"
check "Sat 12:00: no config for the 5gl/5gh radios" "none" "$(ls "$T"/o/hostapd-bcawl0.conf "$T"/o/hostapd-bcawl1.conf 2>/dev/null || echo none)"
check "Sat 12:00: office's bridge not in the plan" "" "$(grep '^net 2 ' "$T/o/plan")"
check "Sat 12:00: sched file" "net 2 off radio 5gh off" "$(tr '\n' ' ' < "$T/o/sched" | sed 's/ $//')"
check "Sat 12:00: every slot remembered (office's 2g slot 1 and 5gl anchor, night's 5gh)" "2g 0 1 0|2g 1 2 1|5gl 0 2 0|5gh 0 3 0" \
	"$(grep -v '^#' "$T/slots" | tr '\n' '|' | sed 's/|$//')"
# a network added while office is off does not take office's slot or BSSID index
{ cat "$T/s1"; net 4 added sae password4 2g 4; } > "$T/s1b"
gen "$T/s1b" -T '6 12:00'
check "added while office is off: slot 2, index 2 (office's 1 kept)" "bcawl3-2 2 4 2" "$(plan_bss | grep ' 4 ' | cut -d' ' -f1-4)"
gen "$T/s1b" -T '1 12:00'
check "office back on Monday: same slot and BSSID" "bcawl3-1 1 2 1 $b_office" "$(plan_bss | grep '^bcawl3-1 ' | cut -d' ' -f1-4) $(bssid_of bcawl3-1)"
bssid_rules "schedules"
conf_ok "schedules"
# the anchor scheduled off while another network runs: promotion (one restart)
{ net 1 a sae password1 2g 1; printf 'schedule=daily@08:00-20:00\n'; net 2 b sae password2 2g 2; } > "$T/s3"
rm -f "$T/slots"; gen "$T/s3"; gen "$T/s3" -T '3 21:00'
check "anchor off at night: b promoted to slot 0 (radio address)" "bcawl3 0 2 0" "$(plan_bss | cut -d' ' -f1-4)"
# the limit counts the networks that are off
for i in 1 2 3 4 5; do net $i n$i sae password$i 2g $i; [ $i = 5 ] && printf 'schedule=mon@08:00-09:00\n'; done > "$T/r"
gen "$T/r" -T '2 12:00'; check "5 networks on a 4-BSS radio, one scheduled off: still refused" "1 yes" "$? $(grep -q 'at most 4 per radio' "$T/err" && echo yes || echo no)"

# ---- 12. station (Wi-Fi uplink) and routed networks ----
sta_ok() {	# every station config parses with wpa_supplicant (when available)
	[ -n "$WPA_CONFCHECK" ] || { echo "skip $1 (no wpa_supplicant-confcheck)"; return 0; }
	if "$WPA_CONFCHECK" "$T"/o/sta-*.conf > "$T/wc" 2>&1; then
		check "$1: wpa_supplicant parses: $2" "$2" "$(sed 's#^OK [^ ]* ##' "$T/wc" | tr '\n' '|' | sed 's/|$//')"
	else
		check "$1: wpa_supplicant parses every config" ok "$(tr '\n' ' ' < "$T/wc")"
	fi
}
stab() { printf 'station=%s\n' "$1"; shift; for kv in "$@"; do printf '%s\n' "$kv"; done; }
rm -f "$T/slots"
{ net 1 a sae password1 "2g 5gl" 1; } > "$T/st0"
gen "$T/st0"
check "station control: AP-only, network 1 is the 5gl anchor" "bcawl0 0 1 0" "$(plan_bss | grep '^bcawl0 ' | cut -d' ' -f1-4)"
{ printf 'radio=5gl\nchannel=36\nwidth=80\n'; stab 5gl ssid=up-link security=psk2 'passphrase=pass"word with space'
  net 1 a sae password1 "2g 5gl" 1
  printf 'network=50\nssid=rep\nsecurity=sae\npassphrase=password5\nbands=5gl\nrouted=192.168.50.1/24\n'; } > "$T/st1"
gen "$T/st1"; check "station + routed: accepted" 0 $?
check "station: network 1 leaves slot 0 (warned), slot 1, index 1" "bcawl0-1 1 1 1 yes" \
	"$(plan_bss | grep '^bcawl0-1 ' | cut -d' ' -f1-4) $(grep -q 'remembered slot 0 on 5gl not available' "$T/err" && echo yes || echo no)"
check "station: no BSS on the radio netdev, routed network on slot 2" "bcawl0-2 2 50 2|" \
	"$(plan_bss | grep '^bcawl0-2 ' | cut -d' ' -f1-4)|$(plan_bss | grep '^bcawl0 ')"
check "station: radio line names the first BSS, the config starts there" "bcawl0-1 interface=bcawl0-1 no" \
	"$(awk '$1 == "radio" && $3 == "bcawl0" { print $6 }' "$T/o/plan") $(grep '^interface=' "$T/o/hostapd-bcawl0.conf") $(grep -q '^bss=bcawl0-1$' "$T/o/hostapd-bcawl0.conf" && echo yes || echo no)"
check "station: plan line (band dev conf sum first)" "5gl bcawl0 $T/o/sta-bcawl0.conf 64 bcawl0-1" \
	"$(awk '$1 == "station" { print $2, $3, $4, length($5), $6 }' "$T/o/plan")"
check "routed: a routed line, no net line, the VLAN network unchanged" "routed 50 brwifi50 192.168.50.1/24 0|net 1 brwifi1 1 0" \
	"$(grep -E '^(routed|net) ' "$T/o/plan" | sort -r | tr '\n' '|' | sed 's/|$//')"
check "station config: 0600, hex ssid, the passphrase quoted, WPA2-PSK CCMP" \
	"-rw-------|	ssid=75702d6c696e6b|	psk=\"pass\"word with space\"|	key_mgmt=WPA-PSK|	pairwise=CCMP|	scan_ssid=1|ctrl_interface=/run/wpa_supplicant" \
	"$(ls -l "$T/o/sta-bcawl0.conf" | cut -c1-10)|$(grep '^	ssid=' "$T/o/sta-bcawl0.conf")|$(grep '^	psk=' "$T/o/sta-bcawl0.conf")|$(grep '^	key_mgmt=' "$T/o/sta-bcawl0.conf")|$(grep '^	pairwise=' "$T/o/sta-bcawl0.conf")|$(grep '^	scan_ssid=' "$T/o/sta-bcawl0.conf")|$(grep '^ctrl_interface=' "$T/o/sta-bcawl0.conf")"
bssid_rules "station"
conf_ok "station"
sta_ok "station psk2" "ctrl=/run/wpa_supplicant networks=1 up-link key_mgmt=0x2 pmf=0 sae_pwe=4 psk=20 sae_password=- bssid=- scan_ssid=1"
# -U: the radio follows the uplink, the width only as far as a block holds it
gen "$T/st1" -U "5gl=5260"
check "-U 5260: channel 52, 80 MHz kept (centre 58), warned" "channel=52 vht_oper_centr_freq_seg0_idx=58 yes" \
	"$(grep -E '^(channel|vht_oper_centr_freq_seg0_idx)=' "$T/o/hostapd-bcawl0.conf" | tr '\n' ' ')$(grep -q 'channel 52 (the station uplink, 5260 MHz) instead of 36' "$T/err" && echo yes || echo no)"
gen "$T/st1" -U "5gl=5500"
check "-U 5500 (not a 5gl channel): ignored, warned" "channel=36 yes" \
	"$(grep '^channel=' "$T/o/hostapd-bcawl0.conf") $(grep -q '5500 MHz, not a channel of this radio' "$T/err" && echo yes || echo no)"
gen "$T/st1" -U "2g=2437"
check "-U on a radio without a station: ignored" "channel=6" "$(grep '^channel=' "$T/o/hostapd-bcawl3.conf")"
gen "$T/st1" -U "5gl=5258"
check "-U 5258 (between channels): ignored" "channel=36" "$(grep '^channel=' "$T/o/hostapd-bcawl0.conf")"
{ printf 'radio=2g\nwidth=40\n'; stab 2g ssid=up security=sae passphrase=saepassword1 bssid=02:00:5E:00:53:01; net 1 a sae password1 2g 1; } > "$T/st2"
rm -f "$T/slots"; gen "$T/st2" -U "2g=2462"
check "2g station, -U 2462: channel 11, HT40-" "channel=11 ht_capab=[HT40-]" "$(grep -E '^(channel|ht_capab)=' "$T/o/hostapd-bcawl3.conf" | tr '\n' ' ' | sed 's/ $//')"
check "SAE station: SAE, PMF required, H2E/HnP, hex password, bssid lower-cased" \
	"	bssid=02:00:5e:00:53:01|	key_mgmt=SAE|	ieee80211w=2|	sae_pwe=2|	sae_password=73616570617373776f726431|no-psk" \
	"$(grep -E '^	(key_mgmt|ieee80211w|sae_pwe|sae_password|bssid)=' "$T/o/sta-bcawl3.conf" | tr '\n' '|')$(grep -q 'psk=' "$T/o/sta-bcawl3.conf" && echo psk || echo no-psk)"
sta_ok "station sae" "ctrl=/run/wpa_supplicant networks=1 up key_mgmt=0x400 pmf=2 sae_pwe=2 psk=- sae_password=12 bssid=set scan_ssid=1"
conf_ok "station 2g"
# a station with no network: no network block (it only scans); no AP on its radio
{ stab 6g; net 1 a sae password1 2g 1; } > "$T/st3"
rm -f "$T/slots"; gen "$T/st3"; check "6g station, no ssid: accepted" 0 $?
check "6g station, no ssid: no network block, no AP on 6g, first = -" "0 - none" \
	"$(grep -c 'network=' "$T/o/sta-bcawl2.conf") $(awk '$1 == "station" { print $6 }' "$T/o/plan") $(ls "$T/o/hostapd-bcawl2.conf" 2>/dev/null || echo none)"
sta_ok "station scan-only" "ctrl=/run/wpa_supplicant networks=0"
# -X: the control directory
gen "$T/st3" -X /run/wpa-x
check "-X: ctrl_interface" "ctrl_interface=/run/wpa-x" "$(grep '^ctrl_interface=' "$T/o/sta-bcawl2.conf")"
gen "$T/st3" -X relative; check "-X relative: refused" 1 $?
# enabled=0: settings kept, the radio is AP-only again (network 1 back to the anchor)
rm -f "$T/slots"; gen "$T/st1"
{ printf 'radio=5gl\nchannel=36\nwidth=80\n'; stab 5gl enabled=0 ssid=up-link security=psk2 passphrase=password1
  net 1 a sae password1 "2g 5gl" 1
  printf 'network=50\nssid=rep\nsecurity=sae\npassphrase=password5\nbands=5gl\nrouted=192.168.50.1/24\n'; } > "$T/st4"
gen "$T/st4"
check "enabled=0: no station line, no config, network 1 promoted to the anchor" "0 none bcawl0 0 1 0" \
	"$(grep -c '^station ' "$T/o/plan") $(ls "$T/o/sta-bcawl0.conf" 2>/dev/null || echo none) $(plan_bss | grep '^bcawl0 ' | cut -d' ' -f1-4)"
# the limit: a station radio carries one network less
rm -f "$T/slots"
{ stab 2g; for i in 1 2 3 4; do net $i n$i sae password$i 2g $i; done; } > "$T/r"
gen "$T/r"; check "station radio, 4 networks, -C 4: refused (at most 3)" "1 yes" "$? $(grep -q 'at most 3 per radio (its station takes one of 4)' "$T/err" && echo yes || echo no)"
gen "$T/r" -C 5; check "station radio, 4 networks, -C 5: accepted, slots 1-4" "0 bcawl3-1 bcawl3-2 bcawl3-3 bcawl3-4" "$? $(plan_bss | cut -d' ' -f1 | tr '\n' ' ' | sed 's/ $//')"
bssid_rules "station 4 networks"
{ stab 2g; net 1 a sae password1 2g 1; printf 'slot.2g=0\n'; } > "$T/r"
rm -f "$T/slots"; gen "$T/r"; check "slot.2g=0 on a station radio: refused" "1 yes" "$? $(grep -q 'slot.2g=0 is the station' "$T/err" && echo yes || echo no)"
# refusals (the slot file never rewritten); no secret in any message
gen "$T/st1"; cp "$T/slots" "$T/slots.st"
stref() {	# name expected-message list-lines...
	nm=$1; msg=$2; shift 2
	printf '%s\n' "$@" > "$T/r"
	gen "$T/r"
	check "refused: $nm" "1 yes no" "$? $(grep -qF "$msg" "$T/err" && echo yes || echo no) $(grep -qE 'SECRETpass|sec"r#et' "$T/err" && echo leak || echo no)"
}
N1='network=1|ssid=a|security=sae|passphrase=password1|bands=2g|vlan=1'
nl() { echo "$1" | tr '|' '\n'; }
stref "two station blocks" "one station= block only" station=2g station=5gl $(nl "$N1")
stref "psk2 with both a quote and #" 'both a double quote and #' station=2g ssid=x security=psk2 'passphrase=sec"r#et-1' $(nl "$N1")
stref "6g station psk2" "6 GHz needs WPA3 (security=sae)" station=6g ssid=x security=psk2 passphrase=SECRETpass $(nl "$N1")
stref "station security owe" "security must be psk2 or sae" station=2g ssid=x security=owe $(nl "$N1")
stref "short station passphrase" "8-63 printable" station=2g ssid=x security=sae passphrase=short $(nl "$N1")
stref "passphrase without ssid" "without an ssid" station=2g passphrase=SECRETpass $(nl "$N1")
stref "multicast bssid" "a unicast MAC address" station=2g ssid=x security=sae passphrase=SECRETpass bssid=01:00:5e:00:00:01 $(nl "$N1")
stref "station unknown key (value not echoed)" "station 2g: unknown key psk" station=2g ssid=x psk=SECRETpass $(nl "$N1")
stref "routed without a station" "routed= needs a station= uplink" network=1 ssid=a security=sae passphrase=password1 bands=2g routed=192.168.50.1/24
stref "routed and vlan" "exclude each other" station=2g network=1 ssid=a security=sae passphrase=password1 bands=2g vlan=5 routed=192.168.50.1/24
stref "routed not the first host" "the first host of a private subnet" station=2g network=1 ssid=a security=sae passphrase=password1 bands=2g routed=192.168.50.254/24
stref "routed public" "the first host of a private subnet" station=2g network=1 ssid=a security=sae passphrase=password1 bands=2g routed=8.8.8.1/24
stref "routed /12 (prefix 16..30)" "the first host of a private subnet" station=2g network=1 ssid=a security=sae passphrase=password1 bands=2g routed=172.16.0.1/12
stref "routed /31" "the first host of a private subnet" station=2g network=1 ssid=a security=sae passphrase=password1 bands=2g routed=192.168.50.1/31
stref "routed overlap" "overlaps network 1" station=2g network=1 ssid=a security=sae passphrase=password1 bands=2g routed=10.1.0.1/16 \
	network=2 ssid=b security=sae passphrase=password2 bands=2g routed=10.1.4.1/24
stref "neither vlan nor routed" "vlan 1..4094 is required (or routed=)" station=2g network=1 ssid=a security=sae passphrase=password1 bands=2g
check "refusals: the slot file untouched" "" "$(cmp "$T/slots" "$T/slots.st" 2>&1)"
{ stab 2g; nl 'network=1|ssid=a|security=sae|passphrase=password1|bands=2g|routed=172.31.0.1/16'; } > "$T/r"
gen "$T/r"; check "routed 172.31.0.1/16: accepted" "0 routed 1 brwifi1 172.31.0.1/16 0" "$? $(grep '^routed ' "$T/o/plan")"
}

for a in "busybox awk" mawk gawk; do
	# shellcheck disable=SC2086 # "busybox awk": command + applet
	set -- $a
	command -v "$1" > /dev/null 2>&1 || { echo "skip awk=$a (absent)"; continue; }
	[ "$1" = busybox ] && ! busybox awk 'BEGIN{}' 2>/dev/null && { echo "skip busybox (no awk applet)"; continue; }
	mkdir -p "$T/bin"
	printf '#!/bin/sh\nexec %s "$@"\n' "$a" > "$T/bin/awk"; chmod +x "$T/bin/awk"
	echo "== awk: $a"
	PATH="$T/bin:$PATH" suite
done
[ $n -gt 0 ] || { echo "FAIL: no awk ran"; fail=1; }
if [ $fail = 0 ]; then echo "ALL OK ($n checks)"; else echo "FAILED"; fi
exit $fail
