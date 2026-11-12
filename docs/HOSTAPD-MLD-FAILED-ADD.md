# hostapd: a failed AP MLD ADD kills the whole `-g` process

Status: **fixed locally** (patch `board/gt-be98-mainline/patches/hostapd/0002-mld-failed-add-keeps-the-process.patch`,
in every image since img39 / RC4). **Still present upstream** (hostap `6d3d778`, 2026-11-10). **Not reported
upstream**: owner decision 2026-11-12, documented here only.

## Effect

With hostapd run as one process for every radio (global control interface, `-g`), one failed
`ADD bss_config=...` of an AP MLD crashes the process. Every access point it runs, on every radio, goes
down with it. On the GT-BE98 this was hit on silicon by the MLO bench arms (q126/q133): one MLD ADD took
every AP of the box down.

## The two crashes

Both are in the failure cleanup of `hostapd_add_iface()` (the global `ADD`), with other interfaces running
in the same process. Both reproduce on `mac80211_hwsim` with hostapd 2.12 and with upstream hostap
`6d3d778`, under ASan.

1. **AP MLD on a driver without MLO support** (`WPA_DRIVER_FLAGS2_MLO` unset; hwsim `mlo=0`), with a plain
   AP already running on the same wiphy.
   - `hostapd_driver_init()` fails ("MLD: Not supported by the driver") after `hapd_init()`, before any
     link is added.
   - The nl80211 driver context is shared with the running interface, so `hostapd_cleanup_driver()` takes
     the MLD link-removal path. `driver_nl80211_link_remove()` removes the BSS, then delivers
     `EVENT_MLD_INTERFACE_FREED` to a NULL context: SEGV in `wpa_supplicant_event()` (`drv_callbacks.c`).
   - Fix: clear `conf->mld_ap` on that failure, so the BSS is torn down as the plain BSS it still is
     (`hostapd/main.c`).
2. **A non-first MLD link the driver refuses** (`start_ap` returns `-EBUSY`).
   - The setup failure already removed the link from the MLD (`hostapd_mld_remove_link()`). Then
     `hostapd_add_iface()`'s cleanup (`hostapd_bss_link_deinit()`) removes it again, and `dl_list_del()` on
     the cleared node dereferences NULL.
   - Fix: make `hostapd_mld_remove_link()` a no-op for a BSS that is not on the list (`src/ap/hostapd.c`).

After the fix the ADD answers `FAIL`, and the process and its other interfaces keep running, including an
MLD's surviving first link.

## Reproduction and test

`package/gt-be98-os/test/hostapd-mld-hwsim-test.sh` (mac80211_hwsim, no hardware). It reproduces both
crashes on unpatched hostapd and checks that the patched one survives both ADDs.

## If it is ever reported upstream

The patch header is written as an upstream commit message, and the two fixes are independent. Re-check
against current hostap first: the line numbers in the patch are from hostapd 2.12.
