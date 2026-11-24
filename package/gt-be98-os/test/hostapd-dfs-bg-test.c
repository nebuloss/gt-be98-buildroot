// SPDX-License-Identifier: GPL-2.0
/*
 * hostapd-dfs-bg-test: the background-radar channel selection of the OS's
 * hostapd (src/ap/dfs.c with board patches 0004 + 0005), driven on the host
 * with the 5 GHz-high channel table of the device in an ETSI country (DE):
 * 36-64 disabled (the other radio's half), 100-144 radar with 144 disabled,
 * 149-165 disabled. Linked against the objects of a host build of that tree
 * (build-hostapd-dfs-bg-test.sh) with the driver calls wrapped
 * (-Wl,--wrap): hostapd_start_dfs_cac (recorded; refused like nl80211 when a
 * piece is disabled), hostapd_switch_channel (recorded), hostapd_disable_iface
 * / hostapd_enable_iface (recorded: an AP stop).
 *
 *   hostapd-dfs-bg-test CONF      CONF = bcawl1 channel=100 VHT80,
 *                                 chanlist=100-112 132-136,
 *                                 enable_background_radar=1
 * The scenario of silicon arm dfs5gh-zw80 (W1 then W2), one check per line:
 *   S1 the AP starts on an available 100/80: the background chain is 132/40,
 *      never a block inside 100-112, never one over a disabled channel, and
 *      the AP's configured width stays 80 MHz;
 *   S2 its CAC completes; a radar on 100/80: one CSA, to 5660 at 40 MHz, no
 *      AP stop;
 *   S3 the NOP ends on 5500..5560: the chain clears 100/80 only once all four
 *      are usable; the firmware still holds the block out of service and the
 *      driver ends that CAC at once (silicon q352: dfs_ap_move -20 BADCHAN 51 s
 *      after cfg80211's NOP-FINISHED): the way back is retried (eloop timer,
 *      run here by hand) and the retry clears 100/80;
 *   S4 that CAC completes: one CSA back, to 5500 at 80 MHz, that passes
 *      hostapd_change_config_freq()'s old-frequency check (q400: refused, the
 *      AP restarted); 132/40 stays the standby (already available: no new CAC).
 * Exit 0 GREEN, 1 RED.
 */
#include "utils/includes.h"
#include "utils/common.h"
#include "common/ieee802_11_common.h"
#include "common/hw_features_common.h"
#include "drivers/driver.h"
#include "ap/hostapd.h"
#include "ap/ap_config.h"
#include "ap/dfs.h"
#include "config_file.h"
#include "utils/eloop.h"

static const struct wpa_driver_ops test_nl80211 = { .name = "nl80211", .desc = "name only" };
const struct wpa_driver_ops *const wpa_drivers[] = { &test_nl80211, NULL };

struct rec { int freq, bw, cf1, bg, refused; };
static struct rec cac[32], csa[16];
static int ncac, ncsa, nstop, bad;
static struct hostapd_hw_modes mode;
static struct hostapd_channel_data ch[40];

#define CHECK(c, ...) do { if (c) { printf("ok   "); } else { printf("RED  "); bad++; } printf(__VA_ARGS__); printf("\n"); } while (0)

static struct hostapd_channel_data *chan_of(int f)
{
	int i;

	for (i = 0; i < mode.num_channels; i++)
		if (ch[i].freq == f)
			return &ch[i];
	return NULL;
}

static int bw_of(int oper_chwidth, int sec)
{
	switch (oper_chwidth) {
	case CONF_OPER_CHWIDTH_80MHZ: return 80;
	case CONF_OPER_CHWIDTH_160MHZ: return 160;
	default: return sec ? 40 : 20;
	}
}

int __wrap_hostapd_start_dfs_cac(struct hostapd_iface *iface, enum hostapd_hw_mode m, int freq, int channel,
				 int ht, int vht, int he, bool eht, int sec, int oper_chwidth, int seg0, int seg1,
				 bool background);
int __wrap_hostapd_start_dfs_cac(struct hostapd_iface *iface, enum hostapd_hw_mode m, int freq, int channel,
				 int ht, int vht, int he, bool eht, int sec, int oper_chwidth, int seg0, int seg1,
				 bool background)
{
	struct rec *r = &cac[ncac < 32 ? ncac++ : 31];
	int f, lo, hi;

	r->freq = freq;
	r->bw = bw_of(oper_chwidth, sec);
	r->cf1 = (oper_chwidth == CONF_OPER_CHWIDTH_USE_HT) ? freq + sec * 10 : 5000 + 5 * seg0;
	r->bg = background;
	lo = r->cf1 - r->bw / 2;
	hi = r->cf1 + r->bw / 2;
	for (f = lo + 10; f < hi; f += 20) {	/* nl80211: every piece enabled */
		struct hostapd_channel_data *c = chan_of(f);

		if (!c || (c->flag & HOSTAPD_CHAN_DISABLED)) {
			r->refused = 1;
			return -22;
		}
	}
	if (background)
		iface->radar_background.cac_started = 1;
	return 0;
}

/*
 * hostapd_switch_channel() is wrapped (no driver, no beacon), but its first
 * step is kept: hostapd_fill_csa_settings() -> hostapd_change_config_freq()
 * rebuilds the OLD frequency from iface->conf with hostapd_set_freq_params()
 * and refuses the switch (-1) when that is not a valid block (silicon q400:
 * the way back 132/40 -> 100/80 with conf = new channel + old width, "20/40
 * MHz: center segment 0 (=106) and center freq 1 (=5510) not in sync"). A
 * refused CSA is recorded (refused=1) and hostapd then restarts the AP.
 */
int __wrap_hostapd_switch_channel(struct hostapd_data *hapd, struct csa_settings *s);
int __wrap_hostapd_switch_channel(struct hostapd_data *hapd, struct csa_settings *s)
{
	struct rec *r = &csa[ncsa < 16 ? ncsa++ : 15];
	struct hostapd_config *conf = hapd->iconf;
	struct hostapd_freq_params old;

	r->freq = s->freq_params.freq;
	r->bw = s->freq_params.bandwidth;
	r->cf1 = s->freq_params.center_freq1;
	os_memset(&old, 0, sizeof(old));
	if (hostapd_set_freq_params(&old, conf->hw_mode, 5000 + 5 * conf->channel, conf->channel,
				    conf->enable_edmg, conf->edmg_channel, conf->ieee80211n,
				    conf->ieee80211ac, conf->ieee80211ax, conf->ieee80211be,
				    conf->secondary_channel, hostapd_get_oper_chwidth(conf),
				    hostapd_get_oper_centr_freq_seg0_idx(conf),
				    hostapd_get_oper_centr_freq_seg1_idx(conf), conf->vht_capab,
				    &mode.he_capab[IEEE80211_MODE_AP], &mode.eht_capab[IEEE80211_MODE_AP], 0)) {
		r->refused = 1;
		return -1;
	}
	return 0;
}

/* eloop is not running: timers are recorded and fired by the test */
static eloop_timeout_handler tmo_h;
static void *tmo_ctx;
static int ntmo;
int __wrap_eloop_register_timeout(unsigned int secs, unsigned int usecs, eloop_timeout_handler h, void *e, void *u);
int __wrap_eloop_register_timeout(unsigned int secs, unsigned int usecs, eloop_timeout_handler h, void *e, void *u)
{
	tmo_h = h;
	tmo_ctx = e;
	ntmo++;
	return 0;
}
int __wrap_eloop_cancel_timeout(eloop_timeout_handler h, void *e, void *u);
int __wrap_eloop_cancel_timeout(eloop_timeout_handler h, void *e, void *u)
{
	if (h == tmo_h)
		tmo_h = NULL;
	return 0;
}

int __wrap_hostapd_disable_iface(struct hostapd_iface *iface);
int __wrap_hostapd_disable_iface(struct hostapd_iface *iface) { nstop++; return 0; }
int __wrap_hostapd_enable_iface(struct hostapd_iface *iface);
int __wrap_hostapd_enable_iface(struct hostapd_iface *iface) { return 0; }

static void set_dfs(int lo, int hi, int state)
{
	int f;

	for (f = lo; f <= hi; f += 20) {
		struct hostapd_channel_data *c = chan_of(f);

		if (c && (c->flag & HOSTAPD_CHAN_RADAR))
			c->flag = (c->flag & ~HOSTAPD_CHAN_DFS_MASK) | state;
	}
}

/* the switch notified (what hostapd_event_ch_switch() writes) */
static void notify(struct hostapd_iface *iface, int freq, int bw, int cf1)
{
	iface->freq = freq;
	iface->conf->channel = (freq - 5000) / 5;
	iface->conf->secondary_channel = bw >= 40 ? 1 : 0;
	hostapd_set_oper_chwidth(iface->conf, bw == 80 ? CONF_OPER_CHWIDTH_80MHZ : CONF_OPER_CHWIDTH_USE_HT);
	hostapd_set_oper_centr_freq_seg0_idx(iface->conf, (cf1 - 5000) / 5);
}

static int bg_inside(int lo, int hi, int from)
{
	int i;

	for (i = from; i < ncac; i++)
		if (cac[i].bg && cac[i].cf1 - cac[i].bw / 2 < hi && lo < cac[i].cf1 + cac[i].bw / 2)
			return 1;
	return 0;
}

int main(int argc, char *argv[])
{
	struct hostapd_config *conf;
	struct hostapd_iface *iface;
	struct hostapd_data *hapd;
	int f, n = 0, c0;

	if (argc != 2)
		return 2;
	wpa_debug_level = MSG_ERROR;
	conf = hostapd_config_read(argv[1]);
	if (!conf) {
		printf("RED  the conf does not parse\n");
		return 1;
	}
	{
		static const int chans[] = { 36, 40, 44, 48, 52, 56, 60, 64, 100, 104, 108, 112, 116, 120, 124,
					     128, 132, 136, 140, 144, 149, 153, 157, 161, 165 };
		unsigned int k;

		for (k = 0; k < ARRAY_SIZE(chans); k++) {
			struct hostapd_channel_data *c = &ch[n++];

			c->chan = chans[k];
			c->freq = 5000 + 5 * chans[k];
			c->allowed_bw = HOSTAPD_CHAN_WIDTH_20 | HOSTAPD_CHAN_WIDTH_40P | HOSTAPD_CHAN_WIDTH_40M |
					HOSTAPD_CHAN_WIDTH_80 | HOSTAPD_CHAN_WIDTH_160;
			c->max_tx_power = 20;
			if (chans[k] >= 100 && chans[k] <= 144)
				c->flag = HOSTAPD_CHAN_RADAR | HOSTAPD_CHAN_DFS_USABLE;
			/* 5gl's half; 144 and 149-165 are disabled in DE (q289's channel list) */
			if (chans[k] < 100 || chans[k] >= 144)
				c->flag |= HOSTAPD_CHAN_DISABLED;
		}
	}
	mode.mode = HOSTAPD_MODE_IEEE80211A;
	mode.channels = ch;
	mode.num_channels = n;
	mode.vht_capab = VHT_CAP_SUPP_CHAN_WIDTH_160MHZ;
	mode.ht_capab = HT_CAP_INFO_SUPP_CHANNEL_WIDTH_SET;

	iface = hostapd_alloc_iface();
	hapd = os_zalloc(sizeof(*hapd));
	iface->conf = conf;
	iface->num_bss = 1;
	iface->bss = os_calloc(1, sizeof(hapd));
	iface->bss[0] = hapd;
	hapd->iface = iface;
	hapd->iconf = conf;
	hapd->conf = conf->bss[0];
	hapd->msg_ctx = hapd;
	iface->current_mode = &mode;
	iface->freq = 5500;
	iface->drv_flags2 = WPA_DRIVER_FLAGS2_RADAR_BACKGROUND;
	iface->dfs_domain = HOSTAPD_DFS_REGION_ETSI;
	iface->state = HAPD_IFACE_ENABLED;	/* the AP is up (the checks below run in service) */

	/* S1: the main CAC on 100/80 is done (cfg80211 holds 100-112 available) */
	set_dfs(5500, 5560, HOSTAPD_CHAN_DFS_AVAILABLE);
	CHECK(hostapd_handle_dfs(iface) == 1, "S1 hostapd_handle_dfs on an available 100/80 continues the setup");
	CHECK(ncac >= 1 && cac[ncac - 1].bg && !cac[ncac - 1].refused && cac[ncac - 1].freq == 5660 &&
	      cac[ncac - 1].bw == 40 && cac[ncac - 1].cf1 == 5670,
	      "S1 the background chain is 132/40 (last CAC request: %d MHz bw %d cf1 %d%s)",
	      ncac ? cac[ncac - 1].freq : 0, ncac ? cac[ncac - 1].bw : 0, ncac ? cac[ncac - 1].cf1 : 0,
	      ncac && cac[ncac - 1].refused ? ", REFUSED" : "");
	CHECK(!bg_inside(5490, 5570, 0), "S1 no background CAC request inside the AP's 100/80 block (5490-5570)");
	{
		int i, r = 0;

		for (i = 0; i < ncac; i++)
			r += cac[i].refused;
		CHECK(r == 0, "S1 no background CAC request over a disabled channel (%d refused)", r);
	}
	CHECK(hostapd_get_oper_chwidth(conf) == CONF_OPER_CHWIDTH_80MHZ && conf->channel == 100,
	      "S1 the AP's configured width is still 80 MHz on 100 (width %d channel %d)",
	      hostapd_get_oper_chwidth(conf), conf->channel);
	CHECK(iface->radar_background.channel == 132, "S1 the chain's channel is 132 (%d)", iface->radar_background.channel);

	/* S2: the standby's CAC completes, then a radar on 100/80 */
	hostapd_dfs_complete_cac(iface, 1, 5660, 1, 1, CHAN_WIDTH_40, 5670, 0);
	CHECK(iface->radar_background.cac_started == 0 && ncsa == 0, "S2 the standby's CAC completed, no switch yet");
	set_dfs(5500, 5560, HOSTAPD_CHAN_DFS_UNAVAILABLE);	/* cfg80211's NOP, as the kernel reports it */
	c0 = ncac;
	hostapd_dfs_radar_detected(iface, 5500, 1, 1, CHAN_WIDTH_80, 5530, 0);
	CHECK(ncsa == 1 && csa[0].freq == 5660 && csa[0].bw == 40 && csa[0].cf1 == 5670 && !csa[0].refused,
	      "S2 one CSA after the radar, to 5660 at 40 MHz (%d CSA, %d MHz bw %d cf1 %d%s)", ncsa,
	      ncsa ? csa[0].freq : 0, ncsa ? csa[0].bw : 0, ncsa ? csa[0].cf1 : 0,
	      ncsa && csa[0].refused ? ", REFUSED by the old-frequency check" : "");
	CHECK(nstop == 0, "S2 the AP was not stopped (%d disable/enable)", nstop);
	CHECK(!bg_inside(5490, 5570, c0), "S2 no background CAC on the NOP channels 5500-5560 during the NOP");
	CHECK(conf->channel == 100 && hostapd_get_oper_chwidth(conf) == CONF_OPER_CHWIDTH_80MHZ,
	      "S2 until the switch is notified the AP keeps its running channel in the conf (channel %d width %d)",
	      conf->channel, hostapd_get_oper_chwidth(conf));
	if (ncsa)
		notify(iface, 5660, 40, 5670);

	/* S3: the NOP ends piece by piece (cfg80211 sends one event per channel) */
	c0 = ncac;
	for (f = 5500; f <= 5560; f += 20) {
		hostapd_dfs_nop_finished(iface, f, 0, 0, CHAN_WIDTH_20_NOHT, f, 0);
		if (f < 5560)
			CHECK(!bg_inside(5490, 5570, c0), "S3 after NOP-FINISHED %d alone: no CAC of 100/80 yet", f);
	}
	CHECK(ncac > c0 && cac[ncac - 1].bg && cac[ncac - 1].freq == 5500 && cac[ncac - 1].bw == 80 &&
	      cac[ncac - 1].cf1 == 5530 && iface->radar_background.upgrade,
	      "S3 after the last NOP-FINISHED: a background CAC of 100/80, marked the way back (%d MHz bw %d cf1 %d upgrade %d)",
	      ncac ? cac[ncac - 1].freq : 0, ncac ? cac[ncac - 1].bw : 0, ncac ? cac[ncac - 1].cf1 : 0,
	      iface->radar_background.upgrade);
	/* S3b q352: the firmware's own out-of-service period outlasts cfg80211's: the driver ends it */
	c0 = ncac;
	hostapd_dfs_complete_cac(iface, 0, 5500, 0, 0, CHAN_WIDTH_80, 5530, 0);
	CHECK(ncac == c0 && ncsa == 1, "S3b the way-back CAC ended by the driver: no new request at once, no switch (%d new, %d CSA)",
	      ncac - c0, ncsa);
	CHECK(tmo_h != NULL, "S3b the way back is retried later (a timer is registered: %d registered)", ntmo);
	if (tmo_h) {
		eloop_timeout_handler h = tmo_h;

		tmo_h = NULL;
		h(tmo_ctx, NULL);	/* the timer fires: the firmware's period is over */
	}
	CHECK(ncac > c0 && cac[ncac - 1].bg && cac[ncac - 1].freq == 5500 && cac[ncac - 1].bw == 80 &&
	      iface->radar_background.upgrade,
	      "S3b the retry asks for 100/80 again, marked the way back (%d MHz bw %d upgrade %d)",
	      ncac ? cac[ncac - 1].freq : 0, ncac ? cac[ncac - 1].bw : 0, iface->radar_background.upgrade);

	/* S4: that CAC completes: switch back */
	c0 = ncac;
	hostapd_dfs_complete_cac(iface, 1, 5500, 1, 1, CHAN_WIDTH_80, 5530, 0);
	CHECK(ncsa == 2 && csa[1].freq == 5500 && csa[1].bw == 80 && csa[1].cf1 == 5530 && !csa[1].refused,
	      "S4 one CSA back, to 5500 at 80 MHz (%d CSA, %d MHz bw %d cf1 %d%s)", ncsa,
	      ncsa > 1 ? csa[1].freq : 0, ncsa > 1 ? csa[1].bw : 0, ncsa > 1 ? csa[1].cf1 : 0,
	      ncsa > 1 && csa[1].refused ? ", REFUSED by the old-frequency check (q400)" : "");
	CHECK(ncsa < 2 || (conf->channel == 132 && hostapd_get_oper_chwidth(conf) == CONF_OPER_CHWIDTH_USE_HT),
	      "S4 until the switch is notified the AP keeps its running channel in the conf (channel %d width %d)",
	      conf->channel, hostapd_get_oper_chwidth(conf));
	if (ncsa > 1 && !csa[1].refused)
		notify(iface, 5500, 80, 5530);
	CHECK(nstop == 0, "S4 the AP was never stopped (%d disable/enable)", nstop);
	CHECK(iface->radar_background.channel == 132 && iface->radar_background.cac_started == 0 && ncac == c0,
	      "S4 132/40 is the standby again, already available: no new CAC (chain %d, cac_started %d, new CACs %d)",
	      iface->radar_background.channel, iface->radar_background.cac_started, ncac - c0);
	printf("%s: %d violation(s)\n", bad ? "RED" : "GREEN", bad);
	return bad ? 1 : 0;
}
