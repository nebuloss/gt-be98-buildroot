// SPDX-License-Identifier: GPL-2.0
/*
 * hostapd-confcheck: parse hostapd configuration files with hostapd's own
 * parser and checks (hostapd/config_file.c hostapd_config_read(), which
 * ends in hostapd_set_security_params() + hostapd_config_check(conf, 1),
 * the full check incl. the 6 GHz rules of hostapd_config_check_bss_6g()),
 * without a driver or a radio. Linked against the objects of a host build of
 * the OS's hostapd source (build-hostapd-confcheck.sh); the driver list is
 * replaced by a name-only "nl80211" so that driver=nl80211 parses.
 *
 *   hostapd-confcheck FILE...   one line per file: OK <file> <bss> ... | FAIL
 * Exit 0 iff every file parsed.
 */
#include "utils/includes.h"
#include "utils/common.h"
#include "drivers/driver.h"
#include "ap/ap_config.h"
#include "config_file.h"

static const struct wpa_driver_ops confcheck_nl80211 = {
	.name = "nl80211",
	.desc = "name only (hostapd-confcheck)",
};

const struct wpa_driver_ops *const wpa_drivers[] = {
	&confcheck_nl80211,
	NULL
};

int main(int argc, char *argv[])
{
	int i, bad = 0;
	size_t j;

	for (i = 1; i < argc; i++) {
		struct hostapd_config *conf = hostapd_config_read(argv[i]);

		if (!conf) {
			printf("FAIL %s\n", argv[i]);
			bad = 1;
			continue;
		}
		printf("OK %s", argv[i]);
		for (j = 0; j < conf->num_bss; j++) {
			struct hostapd_bss_config *b = conf->bss[j];

			printf(" %s/" MACSTR "/%s/wpa=%d/akm=0x%x/mfp=%d/pwe=%d",
			       b->iface, MAC2STR(b->bssid),
			       b->bridge[0] ? b->bridge : "-", b->wpa,
			       b->wpa_key_mgmt, b->ieee80211w, b->sae_pwe);
		}
		printf(" op_class=%u channel=%u\n", conf->op_class, conf->channel);
		hostapd_config_free(conf);
	}
	return bad;
}
