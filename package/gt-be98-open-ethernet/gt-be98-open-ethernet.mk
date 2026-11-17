################################################################################
#
# gt-be98-open-ethernet
#
################################################################################

# branch oe-eth-lan-2026-11-02 = console-stall-2026-10-26 (95657d5: netconsole
# be98pc bootcon handover 0510, panic nbcon flush 0511, Runner netpoll-safe TX
# lock; PCIe 0906) + the RTL8372 read-only monitor (driver/rtl8372, off by
# default), DT patch 0309 (the switch's SMI node at MDIO 29, no reset) and
# 0602-0604 (BCM6813 pinctrl: MDC/MDIO on pins 54/55, so the BCM84891L at 21
# and the switch's SMI answer; rnr3's PHY attach -19 root cause), 0605 (the
# RTL8372 RESET#, GPIO 14 active low, on the switch node: held in reset until
# rtl8372 binds) and 0703 (a flashless BCM8489x no longer has autoneg off);
# rtl8372.ko owns the switch's RESET# (the MDIO core resets PHY devices only)
# console-stall-2026-10-26 2026-11-03 b3ca337 (box-verified: W2 leak watch - per-radio injected-but-unaccounted counter + notice log; on top of 3ce4816)
# console-stall-2026-10-26 2026-11-04 816dc90 (RUNNER-G2: secondary BSS netdevs join the Runner WLAN radio,
#  provider ABI 4 attach_bss/detach_bss - pairs with open-wifi e0f00e1a; flowcache: an IPv4/IPv6 L2 entry always
#  gets the tcp_pure_ack key variant; on top of b3ca337)
# oe-mlo-0907-2026-11-09 2026-11-09 a9960de (= console-stall 1968937 + PCIe 0907: BCM6813 run-time
#  peer-to-peer inbound windows, brcm_pcie_p2p_window_open/_close exported for the open-wifi MLO BRIDGE
#  step; inert unless a driver calls them - no register write at probe or resume; no Kconfig change).
#  The kernel series changed: an existing output tree needs linux-dirclean.
# oe-rc7-2026-11-14 2026-11-14 6d922a8 (img47: flow table 16384 offloaded directions / NAT-C 65536 buckets as
#  stock; ip -s link counts Runner-forwarded frames from the MAC MIB; a shaped egress is no longer bypassed by
#  the offload (a WiFi-egress flow under a shaper stays offloaded through its netdev's qdisc); a routed flow
#  through a VLAN WAN is offloaded by default (q216); driver/runner only, no kernel series change; on top of
#  a9960de)
# oe-rtl8372-landing-2026-11-14 2026-11-14 9e797fd (9b2903b merge + the landing-result docs; = origin/main + oe-rc7 6d922a8 + the RTL8372 configurator:
#  driver/rtl8372 replays the stock bring-up and starts the PHY poller again once the LAN PHYs are up, so the four
#  2.5G LAN jacks link and forward (q245 LANDING PASS: port 6 at 1G, 20/20 pings, 2 cold loads). Only driver/rtl8372,
#  tools/rtl8372 and docs differ from 6d922a8: the kernel series is unchanged, no linux-dirclean needed.)
# oe-rtl8372-vlan-2026-11-16 2026-11-16 6b8ec0b (on 9e797fd: driver/rtl8372 per-jack native VLANs - sysfs
#  jack_profiles / jack_block / l2_lookup / jack_status, debugfs vlan + vlan_all, docs/rtl8372-vlan.md, a host test
#  under tests/; no module parameter; only driver/rtl8372, tests and docs differ: no linux-dirclean needed)
# oe-runner-e2e-vlan-2026-11-16 2026-11-16 6e0222d (on 6b8ec0b: driver/runner only - the bridge
#  learner offloads a jack <-> trunk flow, rnr1.V <-> rnr0.V with one VID over two Runner ports, as the tagged frame it
#  arrived as (tagged L2 key + empty command list); every other Ethernet <-> Ethernet 802.1Q case is counted in
#  `flows`; no module parameter; the kernel series is unchanged, no linux-dirclean needed)
# oe-runner-rx8023-2026-11-16 2026-11-16 645237a (on 6e0222d: driver/runner only - RUNNER-RX-TAG-8023: the
#  XLMAC RXERR mask no longer carries the tag-unaware 802.3 frame-length check, so VLAN-tagged LLC frames (real
#  BPDUs among them) reach the stack; dropstat rx_flr; no module parameter; kernel series unchanged)
# oe-rtl8372-vlan-tagged-2026-11-16 2026-11-16 befea83 (on main 17e5dfc = 645237a + the RUNNER-RX-TAG-8023 bench
#  writer: driver/rtl8372 per-jack TAGGED VIDs - jack_profiles "<n>=<native>+<t>,..", a jack with tagged VIDs a
#  tagged member of each and accept-all with the ingress filter on, jack_status tagged=; host test and docs; no
#  module parameter; only driver/rtl8372, tests and docs differ from 17e5dfc: no linux-dirclean needed)
# oe rtl8372-rldp-portoff 2026-11-17 8bc950f (on befea83: driver/rtl8372 only - the switch's RLDP loop
#  detection on the jacks (jack_status loop= loop_pair=, re-armed when jack_block frees a jack), sysfs
#  jack_disabled (a jack's PHY powered down), debugfs rtl8372/loop; host test tests/rtl8372-jack; no module
#  parameter; only driver/rtl8372, tests and docs differ from befea83: no linux-dirclean needed)
# oe-int-2026-11-17 2026-11-17 9880e99 (integration: = 8bc950f + merges of oe-gw-offload-g6b-2026-11-17
#  80b3b9f (Runner G6b: a routed flow through an 802.1Q device of a Runner port under a gateway bridge is
#  offloaded, tag popped / pushed) and oe-eth-ports-2026-11-17-r c851e63 (E3: core-7 TX_TASK_DS_0/1 r9 as
#  stock on every load; G3: rnr2 reports its UNIMAC MIB in ip -s link / ethtool -S); no conflicts; only
#  driver/runner, driver/rtl8372, tests, tools and docs differ from befea83: no linux-dirclean needed)
# oe-int-2026-11-17 2026-11-17 bc4801d (imgint2: 9880e99 + merges of oe-eth-ports-g2-2026-11-17 afb30c3 (G2:
#  EXT_CFG1 MAX_PKT_SIZE 10272 as stock, W0 q286 read 1536), oe-pppoe-offload-2026-11-17 4f1feca (RUNNER-PPPOE:
#  routed IPv4 over the PPPoE WAN offloaded, stock length op) and oe-b2-pop-2026-11-17 2af4780 (RUNNER-E2E-ONETAG:
#  bare port <-> trunk VLAN pop/push; 6 additive conflict hunks, both behaviours kept, 87b53b9) + the flow
#  check's PPPoE cut (bc4801d); only driver/runner, tests, tools and docs differ from 9880e99: no linux-dirclean)
# oe-int-2026-11-17 2026-11-17 ea41e01 (imgint3: bc4801d + rtl8372-rldp-portoff 6681199: RLDP's live state from
#  LOOPED_STATE 0x1090 (LOOP_STATE 0x108c is a latch, q290 B/U STICKY), LOOPPAIR's nibble = the port, the re-arm
#  removed; driver/rtl8372 only, no conflict; no linux-dirclean)
GT_BE98_OPEN_ETHERNET_VERSION = ea41e01ddceb1ed9b0db92b02f260383b1553baa
GT_BE98_OPEN_ETHERNET_SITE = git@github.com:nebuloss/gt-be98-open-ethernet.git
GT_BE98_OPEN_ETHERNET_SITE_METHOD = git
GT_BE98_OPEN_ETHERNET_LICENSE = GPL-2.0
GT_BE98_OPEN_ETHERNET_INSTALL_IMAGES = YES
GT_BE98_OPEN_ETHERNET_INSTALL_TARGET = YES

GT_BE98_OPEN_ETHERNET_PATCH_DIR = $(GT_BE98_OPEN_ETHERNET_DIR)/kernel-patches/mainline
# kernel-patches/mainline/README, "Apply order"
GT_BE98_OPEN_ETHERNET_SERIES = series.pmb series series.phy series.phylink \
	series.postcode series.usb series.mdio series.mdio-debug series.rxfcs \
	series.mpm series.pcie

GT_BE98_OPEN_ETHERNET_MODULE_SUBDIRS =
ifeq ($(BR2_PACKAGE_GT_BE98_OPEN_ETHERNET_RUNNER),y)
GT_BE98_OPEN_ETHERNET_MODULE_SUBDIRS += driver/runner
endif
# the RTL8372 LAN switch read-only monitor (off by default)
ifeq ($(BR2_PACKAGE_GT_BE98_OPEN_ETHERNET_RTL8372),y)
GT_BE98_OPEN_ETHERNET_MODULE_SUBDIRS += driver/rtl8372
endif
ifneq ($(strip $(GT_BE98_OPEN_ETHERNET_MODULE_SUBDIRS)),)
$(eval $(kernel-module))
endif

# tools/mainline-boot for post-image.sh: mkbootfs.py (FIT), the board dts
# wrapper and the config fragments / command line gen-linux-config.sh uses.
define GT_BE98_OPEN_ETHERNET_INSTALL_IMAGES_CMDS
	mkdir -p $(HOST_DIR)/share/gt-be98-mainline
	rm -rf $(HOST_DIR)/share/gt-be98-mainline/mainline-boot
	cp -a $(@D)/tools/mainline-boot $(HOST_DIR)/share/gt-be98-mainline/mainline-boot
	echo $(GT_BE98_OPEN_ETHERNET_VERSION) > \
		$(HOST_DIR)/share/gt-be98-mainline/open-ethernet.version
endef

$(eval $(generic-package))

# The kernel patch series. The kernel is patched after this package is
# extracted (an order-only prerequisite: Buildroot's PATCH_DEPENDENCIES cannot
# be set from an external tree, linux.mk is parsed first), then every series
# file is applied in README order with Buildroot's apply-patches.sh.
ifeq ($(BR2_PACKAGE_GT_BE98_OPEN_ETHERNET_KERNEL_PATCHES),y)
$(LINUX_TARGET_PATCH): | gt-be98-open-ethernet-extract

# apply-patches.sh applies a directory's own "series" file and ignores any
# file pattern, and kernel-patches/mainline/series is only one of the
# lists: so build a directory with one combined series (README order) and
# links to the patches, and let apply-patches.sh apply that (patch -F0).
GT_BE98_KSERIES_DIR = $(BUILD_DIR)/gt-be98-kernel-series
define GT_BE98_LINUX_APPLY_SERIES
	@$(call MESSAGE,"Applying the GT-BE98 kernel series ($(GT_BE98_OPEN_ETHERNET_VERSION))")
	$(Q)rm -rf $(GT_BE98_KSERIES_DIR) && mkdir -p $(GT_BE98_KSERIES_DIR)
	$(Q)set -e; for s in $(GT_BE98_OPEN_ETHERNET_SERIES); do \
		f=$(GT_BE98_OPEN_ETHERNET_PATCH_DIR)/$$s; \
		test -f $$f || { echo "missing $$f"; exit 1; }; \
		for p in `grep -Ev '^(#|$$)' $$f | cut -d' ' -f1`; do \
			ln -s $(GT_BE98_OPEN_ETHERNET_PATCH_DIR)/$$p $(GT_BE98_KSERIES_DIR)/$$p; \
			echo $$p >> $(GT_BE98_KSERIES_DIR)/series; \
		done; \
	done
	$(Q)echo "GT-BE98 kernel series: `wc -l < $(GT_BE98_KSERIES_DIR)/series` patches"
	$(APPLY_PATCHES) $(@D) $(GT_BE98_KSERIES_DIR)
endef
LINUX_POST_PATCH_HOOKS += GT_BE98_LINUX_APPLY_SERIES
endif
