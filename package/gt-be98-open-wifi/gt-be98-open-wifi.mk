################################################################################
#
# gt-be98-open-wifi
#
################################################################################

# main 2026-11-03 49d3137a (box-verified: CB-NOTAIL beacon tail kept on a tail-less change_beacon, per-peer power-save answer counters, ledger triage; on top of 1341a24f)
# main 2026-11-02 1341a24f (box-verified: HE/EHT follow hostapd - he/eht features+enab sent to the firmware in the radio-down window; 6 GHz keeps HE)
# main 2026-10-30 71e8f7ce (box-verified 300 cycles: RMDOWN fix A - a remove-time control timeout makes no device access, an unanswered radio-down takes the dead-firmware unwind; on top of 09fbee8b)
# main 2026-10-30 09fbee8b (box-verified: airtime fairness follows hostapd (fw ATM percentages), bridged Wi-Fi->trunk frames offered to an ABI-3 Runner; on top of 9079dde9)
#  radio + later station no longer steals a client ring), Multi-AP backhaul map/dwds re-applied per connect)
# main 2026-11-03 18e96ed2 (box-verified: TX doorbells from a dirty-ring list instead of a full scan per run - 6 GHz Runner-offload CPU ratio 0.52; on top of 49d3137a)
# main 2026-11-04 e0f00e1a (box-verified: BSS0-MAC - the radio's first BSS takes hostapd's bssid= (custom
#  first-network MAC, the 6 GHz LA anchor block: 8 networks on 6 GHz, B0/B0s/B2 PASS); RUNNER-G2 client: secondary
#  BSS netdevs bind to their radio's Runner WLAN slot (provider ABI 4, needs open-ethernet 816dc90); on top of 18e96ed2)
# main 2026-11-09 eead8fbb (img38: INV-MLE, MLO R1/R3/R4 step 1, int-1109k (bcnprot, evt-defects, KEY-110 b),
#  TXPWR-AUTO, INV-C2C, BSSDEL, UAPSD; on top of cb1c8952)
# main 2026-11-10 b2a70da3 (img39: PUNCT (bench), CSA notices, INV-BCME-ERRNO, INV-6G-MBSSID-GUARD, RX-LOOKUP, MLO R4 step 2
#  (bench/group only); on top of eead8fbb)
# main 2026-11-11 24edcb68 (img40: INV-PAGER-RACE (shipped fix), ledger/docs; MLO R4 step 3 + R5 bench/group only;
#  on top of b2a70da3)
# main 2026-11-11 20ef74c9 (img42: RXPOLL-IDLE: bcawl_rxpoll/evwr sleep TASK_IDLE, box-verified idle load
#  4.0 -> 0.16; on top of 24edcb68)
# main 2026-11-13 4ec3bcd6 (img44: DFS-CAC-ABORT-WARN (shipped fix): a firmware CAC abort inside hostapd's
#  radar-detection start no longer WARNs in cfg80211 and leaves the 5 GHz radio without an AP; MLO R5-2 v3-r3
#  bench/group only; on top of 20ef74c9)
# main 2026-11-13 7c78601a (img47: WMM-EDCA: hostapd's EDCA parameters (tx_queue_* / wmm_ac_*) reach the
#  firmware, box-verified q212/q217; INV-RECOVERY rebind give-up and trap-poll fixes, active only when
#  radio_rebind > 0 (default stays 0); MLO r5-3 bench/group only; on top of 4ec3bcd6)
# main 2026-11-15 5378a951 (img48/RC8: WPS PBC (a9df21e0: probe-request event 44 to hostapd; overlap
#  detection probabilistic, documented UNTESTED) + 802.11k/v (BSS-transition / action frames to and from
#  hostapd, box-verified q249: BTM moved the client in 2 s; neighbour report blocked on fw RM-cap); on top
#  of 7c78601a)
# main 2026-11-15 2456cda8 (RC9: DFS5GH-BAND: each 5 GHz radio advertises only its own half (dom0 5150-5350,
#  dom3 5470-5895), so a post-radar firmware move can no longer land the 5 GHz-high AP on channel 36;
#  box-verified q258 (CTL moved to 5180, FIX back up in band at 5580); on top of 5378a951)
# om-int-2026-11-17 2026-11-17 6f86ecab (imgint2: main 55013e13 (802.11k option (b): rrm moved to Phase D, the
#  Neighbor Report bit not sent; box-verified q287) + om-dfs-owner-2026-11-17 be929950 (DFS-OWNER: one owner of
#  the move after an in-service radar, hostapd CSA owns it; box-verified q289) + the ledger row RUNNER-E2E-ONETAG
#  (doc-only); no module parameter added)
# om-int-2026-11-17 2026-11-17 8c565b68 (imgint4: 6f86ecab + the index regeneration e9d3da38 + om-rebind-ch40 69384cb3
#  (radio_rebind's default named in one place, the G4 V2 move declaration; no behaviour change, default still 0)
#  + the RUNNER-L3-FDB ledger rows c17d40ac (doc-only))
# om-mesh-int-2026-11-17 2026-11-17 6dbad8c1 (imgmesh1: om-int 8c565b68 + om-mesh-bh-2026-11-17 9aa121bc (MESH-BH: the
#  4-address link on a secondary BSS, its AP_VLAN back-pressure, the leave the firmware is owed; no module parameter))
# om-mesh-int-2026-11-17 2026-11-17 83cb2973 (imgint5: + om-mesh-bh bca7f518: R2 at address-set (the AP_VLAN parent chosen
#  again when hostapd sets the MAC), R6 (a bound AP_VLAN's group frames on the link's own ring, 4-address))
# om-mesh-int-2026-11-17 2026-11-17 8137daeb (imgint5b: 83cb2973 + om-int 74526e96 = om-rebind-ch40 7c216637 (ledger) +
#  om-rebind-flip-r 67b5c4b6: radio_rebind DEFAULT 1 (INV-RECOVERY; q296 rebind-ch40-arm-r2 PASS both cells, 6/6))
# om-mesh-int-2026-11-17 2026-11-17 4040667a (imgint7: 8137daeb (radio_rebind=1 kept) + om-mesh-bh a65722d4: the MESH-G1 ledger
#  AND the bench knob band5_full (class B: bench build only, folded to 0 in the shipped ko) with its census / declared rows)
# om-dfs5gh-bgcac-r2-2026-11-19 2026-11-19 0a7588d3 (imgint12b: main 38e7be78 + ZW-ETSI: background CAC in ETSI on the 5 GHz-high
#  radio, the timer-wheel abort fix; gates GREEN 0a7588d3 vs 38e7be78, 36 shipped params unchanged; q336 BG PASS with its bench ko)
GT_BE98_OPEN_WIFI_VERSION = 0a7588d3150c033b4daad39570fb0206ae1cbab8
GT_BE98_OPEN_WIFI_SITE = git@github.com:nebuloss/gt-be98-open-wifi.git
GT_BE98_OPEN_WIFI_SITE_METHOD = git
GT_BE98_OPEN_WIFI_LICENSE = GPL-2.0-only
GT_BE98_OPEN_WIFI_MODULE_SUBDIRS = driver

ifeq ($(BR2_PACKAGE_GT_BE98_OPEN_WIFI_BENCH),y)
GT_BE98_OPEN_WIFI_MODULE_MAKE_OPTS = BCA_BENCH_CFLAGS=-DBCA_BENCH_PARAMS
endif

# bca_barpeek.ko (bench builds only) is a reverse-engineering tool: never ship
# (removed after the kernel-module install, in a target-finalize hook)
define GT_BE98_OPEN_WIFI_REMOVE_BARPEEK
	find $(TARGET_DIR)/lib/modules -name bca_barpeek.ko -delete
endef
GT_BE98_OPEN_WIFI_TARGET_FINALIZE_HOOKS += GT_BE98_OPEN_WIFI_REMOVE_BARPEEK

$(eval $(kernel-module))
$(eval $(generic-package))
