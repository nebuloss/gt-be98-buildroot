// SPDX-License-Identifier: GPL-2.0
/*
 * hostapd-link-sta-test: board patch 0006 (an MLD link disabled or removed keeps the MLD station), on the BUILD
 * host, linked against the objects of a host build of the OS's hostapd tree (build-hostapd-link-sta-test.sh) with
 * wpa_msg and ieee802_11_set_beacon wrapped (-Wl,--wrap). Two links of one AP MLD (link 0 = the association link,
 * link 1 = the link that goes), one MLD station with its link copy on link 1:
 *   S1 freeing link 1's stations (hostapd_free_stas, what `disable` and LINK_REMOVE's expiry run) emits NO
 *      AP-STA-DISCONNECTED and leaves the station on link 0;
 *   S2 freeing link 0's stations (the association link) still emits AP-STA-DISCONNECTED once;
 *   S3 hostapd_link_remove() exists outside CONFIG_TESTING_OPTIONS and arms the countdown (count kept).
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

static const struct wpa_driver_ops test_nl80211 = { .name = "nl80211", .desc = "name only" };
const struct wpa_driver_ops *const wpa_drivers[] = { &test_nl80211, NULL };

static int ndisc, bad;
#define CHECK(c, ...) do { if (c) { printf("ok   "); } else { printf("RED  "); bad++; } printf(__VA_ARGS__); printf("\n"); } while (0)

void __real_wpa_msg(void *ctx, int level, const char *fmt, ...);
void __wrap_wpa_msg(void *ctx, int level, const char *fmt, ...)
{
	char b[256];
	va_list ap;

	va_start(ap, fmt);
	vsnprintf(b, sizeof(b), fmt, ap);
	va_end(ap);
	if (os_strncmp(b, AP_STA_DISCONNECTED, os_strlen(AP_STA_DISCONNECTED)) == 0)
		ndisc++;
}

int __wrap_ieee802_11_set_beacon(struct hostapd_data *hapd)
{
	return 0;
}

int hostapd_link_remove(struct hostapd_data *hapd, u32 count);

int main(void)
{
	static struct hostapd_config iconf;
	static struct hostapd_bss_config bss;
	static struct hostapd_iface iface;
	static struct hostapd_data h[2];
	static struct hostapd_mld mld;
	const u8 addr[ETH_ALEN] = { 0x02, 0x00, 0x00, 0x00, 0x00, 0x01 };
	struct sta_info *s0, *s1;
	int i;

	if (eloop_init())
		return 1;
	bss.mld_ap = 1;
	bss.max_num_sta = 8;
	iconf.beacon_int = 100;
	iface.conf = &iconf;
	dl_list_init(&mld.links);
	for (i = 0; i < 2; i++) {
		h[i].conf = &bss;
		h[i].iconf = &iconf;
		h[i].iface = &iface;
		h[i].msg_ctx = &h[i];
		h[i].mld = &mld;
		h[i].mld_link_id = i;
		dl_list_add_tail(&mld.links, &h[i].link);
	}
	mld.num_links = 2;
	s0 = ap_sta_add(&h[0], addr);
	s1 = ap_sta_add(&h[1], addr);
	if (!s0 || !s1) {
		printf("RED  ap_sta_add failed\n");
		return 1;
	}
	s0->mld_info.mld_sta = true;
	s1->mld_info.mld_sta = true;
	s0->mld_assoc_link_id = 0;
	s1->mld_assoc_link_id = 0;
	s0->flags |= WLAN_STA_AUTH | WLAN_STA_ASSOC | WLAN_STA_AUTHORIZED;
	s1->flags |= WLAN_STA_AUTH | WLAN_STA_ASSOC | WLAN_STA_AUTHORIZED;

	ndisc = 0;
	hostapd_free_stas(&h[1]);
	CHECK(ndisc == 0, "S1 link 1's stations freed: %d AP-STA-DISCONNECTED (want 0: its association link remains)", ndisc);
	CHECK(h[0].num_sta == 1 && ap_get_sta(&h[0], addr), "S1 the station is still on link 0 (num_sta %d)", h[0].num_sta);

	ndisc = 0;
	hostapd_free_stas(&h[0]);
	CHECK(ndisc == 1, "S2 link 0 (the association link) freed: %d AP-STA-DISCONNECTED (want 1)", ndisc);

	CHECK(hostapd_link_remove(&h[1], 3) == 0 && h[1].eht_mld_link_removal_count == 3,
	      "S3 hostapd_link_remove outside CONFIG_TESTING_OPTIONS: count %u (want 3)", h[1].eht_mld_link_removal_count);
	eloop_destroy();
	printf("%s (%d red)\n", bad ? "RED" : "GREEN", bad);
	return bad ? 1 : 0;
}
