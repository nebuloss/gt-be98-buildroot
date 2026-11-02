// SPDX-License-Identifier: GPL-2.0
/*
 * wpa_supplicant-confcheck: parse wpa_supplicant configuration files with
 * wpa_supplicant's own parser (wpa_supplicant/config_file.c
 * wpa_config_read(), the same call wpa_supplicant makes at start and at
 * "wpa_cli reconfigure"), without a driver or a radio. Built as
 * wpa_supplicant's CONFIG_MAIN from a host build of the OS's wpa_supplicant
 * source (build-wpa-confcheck.sh).
 *
 *   wpa_supplicant-confcheck FILE...
 *       one line per file: OK <file> ctrl=<ctrl_interface> networks=<n>
 *       then per network: <ssid as text> key_mgmt=0x.. pmf=.. sae_pwe=..
 *       psk=<passphrase length|hex|-> sae_password=<length|->
 *       bssid=<set|-> scan_ssid=..      | FAIL <file>
 * Exit 0 iff every file parsed. A secret is never printed, only its length.
 */
#include "includes.h"
#include "common.h"
#include "config.h"

int main(int argc, char *argv[])
{
	int i, bad = 0;

	wpa_debug_level = MSG_ERROR;
	for (i = 1; i < argc; i++) {
		struct wpa_config *conf = wpa_config_read(argv[i], NULL, false, false);
		struct wpa_ssid *s;
		int n = 0;

		if (!conf) {
			printf("FAIL %s\n", argv[i]);
			bad = 1;
			continue;
		}
		for (s = conf->ssid; s; s = s->next)
			n++;
		printf("OK %s ctrl=%s networks=%d", argv[i],
		       conf->ctrl_interface ? conf->ctrl_interface : "-", n);
		for (s = conf->ssid; s; s = s->next) {
			printf(" %s key_mgmt=0x%x pmf=%d sae_pwe=%d psk=",
			       wpa_ssid_txt(s->ssid, s->ssid_len), s->key_mgmt,
			       (int) s->ieee80211w, s->sae_pwe);
			if (s->passphrase)
				printf("%zu", os_strlen(s->passphrase));
			else
				printf("%s", s->psk_set ? "hex" : "-");
			if (s->sae_password)
				printf(" sae_password=%zu", os_strlen(s->sae_password));
			else
				printf(" sae_password=-");
			printf(" bssid=%s scan_ssid=%d", s->bssid_set ? "set" : "-",
			       s->scan_ssid);
		}
		printf("\n");
		wpa_config_free(conf);
	}
	return bad;
}
