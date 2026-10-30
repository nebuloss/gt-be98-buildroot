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
 *   hostapd-confcheck FILE...   one line per file: OK <file> <bss> ...
 *                               op_class= channel= he= be= [bw6= freq=] | FAIL
 * Exit 0 iff every file parsed.
 */
#include "utils/includes.h"
#include "utils/common.h"
#include "common/ieee802_11_common.h"
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
		printf(" op_class=%u channel=%u", conf->op_class, conf->channel);
#ifdef CONFIG_IEEE80211AX
		/*
		 * 6 GHz width, as hostapd itself reads it (setup_interface2():
		 * the op_class sets he/eht_oper_chwidth; hostapd_set_freq_params()
		 * takes the bandwidth from the segment 0 centre index):
		 * bw6=<op_class bandwidth>/<bandwidth of the centre index>/<that
		 * index>, -1 = an index hostapd refuses. The checks of the
		 * generator's own centre arithmetic are hostapd's, not ours.
		 */
		printf(" he=%d/%u", conf->he_oper_chwidth,
		       conf->he_oper_centr_freq_seg0_idx);
#ifdef CONFIG_IEEE80211BE
		printf(" be=%d/%d/%u", conf->ieee80211be, conf->eht_oper_chwidth,
		       conf->eht_oper_centr_freq_seg0_idx);
#endif /* CONFIG_IEEE80211BE */
		if (is_6ghz_op_class(conf->op_class)) {
			u8 seg0;
			int bw;

			hostapd_set_oper_chwidth(conf,
				op_class_to_ch_width(conf->op_class));
			seg0 = hostapd_get_oper_centr_freq_seg0_idx(conf);
			if (!seg0)
				seg0 = conf->channel;
			bw = center_idx_to_bw_6ghz(seg0);
			printf(" bw6=%d/%d/%u freq=%d",
			       op_class_to_bandwidth(conf->op_class),
			       bw < 0 ? -1 : 20 << bw, seg0,
			       ieee80211_chan_to_freq(NULL, conf->op_class,
						      conf->channel));
		}
#endif /* CONFIG_IEEE80211AX */
		printf("\n");
		hostapd_config_free(conf);
	}
	return bad;
}
