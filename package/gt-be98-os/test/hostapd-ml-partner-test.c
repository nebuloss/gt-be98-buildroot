// SPDX-License-Identifier: GPL-2.0
/*
 * hostapd-ml-partner-test: board patch 0007 (an AP MLD link that is NOT its interface's first BSS), on the BUILD host,
 * linked against the objects of a host build of the OS's hostapd tree (build-hostapd-ml-partner-test.sh) with wpa_msg
 * and ieee802_11_set_beacon wrapped. Two interfaces, as the OS writes them (one config per radio, the plain primary
 * first, the AP MLD link as a later bss=):
 *   iface0: bss[0] = AP MLD link 0 (the association link)
 *   iface1: bss[0] = a plain BSS, bss[1] = AP MLD link 1
 * One ML station (associated on link 0, links 0 and 1) with its partner copy on link 1, and a plain station on iface1's
 * plain BSS.
 *   S1 the driver reports the ML station's leave on link 0 (hostapd_notif_disassoc): its copy on link 1 (bss[1]) is
 *      freed too, and the plain BSS's station is untouched;
 *   S2 the rejoin: the next association's partner-link check (ieee802_11.c, "MLD: link: Station already exists") finds
 *      no station on link 1 — ap_get_sta(link 1, the MLD address) is NULL — and a new partner copy can be added;
 *   S3 an AP-initiated deauthentication of the ML station (ap_sta_deauthenticate on link 0, what hostapd_cli
 *      DEAUTHENTICATE runs) reaches link 1's copy (its ASSOC flag cleared by ap_sta_handle_deauthenticate), not only the
 *      association link's;
 *   S4 the rejoin right after it: link 1's copy is still there (hostapd keeps a deauthenticated station for
 *      AP_MAX_INACTIVITY_AFTER_DEAUTH), and the new association's link processing (ieee80211_ml_process_link on link 1,
 *      the origin being the re-associated station) frees it instead of refusing ("MLD: link: Station already exists",
 *      q472) and adds the new link station (no Multi-Link element in this unit: the link processing stops after
 *      ap_sta_add, which is the step the refusal blocked).
 * Exit 0 GREEN, 1 RED.
 */
#include "utils/includes.h"
#include "utils/common.h"
#include "utils/eloop.h"
#include "common/wpa_ctrl.h"
#include "drivers/driver.h"
#include "ap/hostapd.h"
#include "ap/ap_config.h"
#include "ap/sta_info.h"
#include "ap/ieee802_11.h"

static const struct wpa_driver_ops test_nl80211 = { .name = "nl80211", .desc = "name only" };
const struct wpa_driver_ops *const wpa_drivers[] = { &test_nl80211, NULL };

static int bad, nexists;
#define CHECK(c, ...) do { if (c) { printf("ok   "); } else { printf("RED  "); bad++; } printf(__VA_ARGS__); printf("\n"); } while (0)

void __real_wpa_msg(void *ctx, int level, const char *fmt, ...);
void __wrap_wpa_msg(void *ctx, int level, const char *fmt, ...)
{
}

void __real_wpa_printf(int level, const char *fmt, ...);
void __wrap_wpa_printf(int level, const char *fmt, ...)
{
	if (os_strstr(fmt, "Station already exists"))
		nexists++;
}

int __wrap_ieee802_11_set_beacon(struct hostapd_data *hapd)
{
	return 0;
}

static struct sta_info *ml_sta(struct hostapd_data *h, const u8 *addr)
{
	struct sta_info *s = ap_sta_add(h, addr);

	if (!s)
		return NULL;
	s->mld_info.mld_sta = true;
	s->mld_assoc_link_id = 0;
	s->aid = 1;
	s->mld_info.links[0].valid = 1;
	s->mld_info.links[1].valid = 1;
	s->flags |= WLAN_STA_AUTH | WLAN_STA_ASSOC;
	return s;
}

int main(void)
{
	static struct hapd_interfaces ifs;
	static struct hostapd_iface *ifp[2];
	static struct hostapd_iface if0, if1;
	static struct hostapd_config ic0, ic1;
	static struct hostapd_bss_config mldc, plainc;
	static struct hostapd_data l0, l1, pl;
	static struct hostapd_data *b0[1], *b1[2];
	static struct hostapd_mld mld;
	const u8 maddr[ETH_ALEN] = { 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 };
	const u8 paddr[ETH_ALEN] = { 0x02, 0x00, 0x00, 0x00, 0x00, 0x02 };
	struct sta_info *s0, *s1, *sp;

	if (eloop_init())
		return 1;
	mldc.mld_ap = 1;
	mldc.max_num_sta = 8;
	os_strlcpy(mldc.iface, "mld0", sizeof(mldc.iface));
	plainc.max_num_sta = 8;
	os_strlcpy(plainc.iface, "bcawl1", sizeof(plainc.iface));
	ic0.beacon_int = ic1.beacon_int = 100;
	if0.conf = &ic0; if1.conf = &ic1;
	if0.interfaces = if1.interfaces = &ifs;
	b0[0] = &l0; b1[0] = &pl; b1[1] = &l1;
	if0.bss = b0; if0.num_bss = 1;
	if1.bss = b1; if1.num_bss = 2;
	ifp[0] = &if0; ifp[1] = &if1;
	ifs.iface = ifp; ifs.count = 2;
	dl_list_init(&mld.links);
	l0.conf = &mldc; l0.iconf = &ic0; l0.iface = &if0; l0.msg_ctx = &l0; l0.mld = &mld; l0.mld_link_id = 0;
	l1.conf = &mldc; l1.iconf = &ic1; l1.iface = &if1; l1.msg_ctx = &l1; l1.mld = &mld; l1.mld_link_id = 1;
	pl.conf = &plainc; pl.iconf = &ic1; pl.iface = &if1; pl.msg_ctx = &pl;
	dl_list_add_tail(&mld.links, &l0.link);
	dl_list_add_tail(&mld.links, &l1.link);
	mld.num_links = 2;

	s0 = ml_sta(&l0, maddr);
	s1 = ml_sta(&l1, maddr);
	sp = ap_sta_add(&pl, paddr);
	if (!s0 || !s1 || !sp) {
		printf("RED  setup: ap_sta_add failed\n");
		return 1;
	}
	printf("=== S1 the ML station's leave reported on its association link (link 0, iface0 bss[0])\n");
	hostapd_notif_disassoc(&l0, maddr);
	CHECK(!ap_get_sta(&l0, maddr), "S1a the association link's station is freed");
	CHECK(!ap_get_sta(&l1, maddr), "S1b its copy on link 1 (iface1 bss[1]) is freed too");
	CHECK(ap_get_sta(&pl, paddr) != NULL, "S1c the plain BSS's station (iface1 bss[0]) is untouched");

	printf("=== S2 the rejoin\n");
	CHECK(!ap_get_sta(&l1, maddr), "S2a the partner-link check finds no station on link 1 (no \"Station already exists\")");
	s0 = ml_sta(&l0, maddr);
	s1 = ml_sta(&l1, maddr);
	CHECK(s0 && s1, "S2b the station and its link-1 copy are added again");

	printf("=== S3 an AP-initiated deauthentication of the ML station\n");
	if (s0 && s1) {
		ap_sta_deauthenticate(&l0, s0, WLAN_REASON_UNSPECIFIED);
		CHECK(!(s1->flags & WLAN_STA_ASSOC), "S3a link 1's copy is deauthenticated too (ASSOC cleared)");
		CHECK(!(s0->flags & WLAN_STA_ASSOC), "S3b the association link's station is deauthenticated");

		printf("=== S4 the rejoin right after the AP-initiated deauthentication\n");
		CHECK(ap_get_sta(&l1, maddr) == s1, "S4a link 1's deauthenticated copy is still kept (its removal timer)");
		{
			bool sb = false;
			struct sta_info *n;
			int ne = nexists;

			s1->listen_interval = 77;	/* marks the stale copy (a new station starts at 0) */
			s0->flags |= WLAN_STA_AUTH | WLAN_STA_ASSOC;	/* the station associated again on link 0 */
			(void)ieee80211_ml_process_link(&l1, s0, &s0->mld_info.links[1], NULL, 0,
							LINK_PARSE_ASSOC, true, &sb);
			n = ap_get_sta(&l1, maddr);
			CHECK(nexists == ne, "S4b the new association is not refused (no \"Station already exists\")");
			CHECK(n != NULL && n->listen_interval != 77,
			      "S4c link 1 has the NEW association's station (the stale copy is gone)");
		}
	}
	printf("%s: %d failure(s)\n", bad ? "RED" : "GREEN", bad);
	return bad ? 1 : 0;
}
