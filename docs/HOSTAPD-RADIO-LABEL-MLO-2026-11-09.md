# hostapd's per-radio label on a grouped (MLO) wiphy (design note, 2026-11-09)

Status: NOTE ONLY, no code changed. Nothing breaks today: every radio has its own wiphy. It matters the day the
product runs MLO on a grouped wiphy (open-wifi `phy_group`, lane mlo-prod).

## Finding (lane mlo-prod)

On a grouped wiphy every member radio reports the SAME phy name. hostapd 2.12 keys a radio ("iface") by the label
of `ADD bss_config=<label>:<file>`: `hostapd_interface_init_bss()` (`src/ap/hostapd.c` ~3450) looks for an existing
iface whose `phy` equals the label and, if one exists, APPENDS the config's BSS to it (only an AP MLD BSS,
`mld_ap`, gets a new iface regardless). So two radios ADDed with the same phy name become one iface: the second
radio's first BSS is treated as a further BSS of the first radio.

## The product today

`init.d/gt-be98-wifi` labels with the phy name, in both places:

- `unit_restart` (a radio's whole config): `phy=$(radio_phy "$d")` (`/sys/class/net/<dev>/phy80211/name`) ->
  `ADD bss_config=$phy:$c`;
- `unit_apply` (one further BSS): `ADD bss_config=$phy:$p`, the same phy read.

The second use RELIES on the merge: a further BSS must land in its radio's iface, and the label is how. So the
label must stay the same for all BSSes of one radio and differ between radios.

What else reads the label (hostapd 2.12): `STATUS` prints it as `phy=` (`src/ap/ctrl_iface_ap.c:823`), and
`hostapd.c:2164` fills an EMPTY label from the driver's radio name. No driver operation uses it (the nl80211
driver finds the wiphy from the interface). The web UI does not read `phy=` from STATUS.

## Fix (when MLO ships)

Label each radio by its primary netdev name (`bcawlN`), which is unique per radio and the same for all its BSSes:

- `unit_restart`: `ADD bss_config=$d:$c`; `unit_apply`: `ADD bss_config=$d:$p` (`radio_phy` stays, only to wait
  for the netdev; the phy name is no longer the key).
- A station radio's first AP runs on a virtual interface, but the label is still the radio netdev `$d`.
- The offline service test's fake hostapd groups by the label already: its expectations change from `phy<N>` to
  `bcawl<N>` (mechanical), plus one new case: two radios reporting the same phy name stay two ifaces.
- A driver re-probe (new wiphy name) no longer changes the label either (the netdev name is kept).
- AP MLD BSSes keep hostapd's own rule (a new iface per MLD link); how the service ADDs an MLD is mlo-prod's design.

Risk: none known for non-grouped wiphys (the label is a key, not a driver handle). To verify on the box when built:
`hostapd_cli -i <bss> status` shows `phy=bcawlN`, and per-BSS add/remove still lands in the right radio.

## Hazard 2 (lane mlo-prod, q126 1109-1800 cell C): one refused MLD ADD killed the hostapd process

**What the log shows** (`C-hapd-full.txt`; hostapd 2.12, `-g` + ADD, the product's launch shape):

1. `ADD bss_config=bcawl3:/run/a2-plain.conf`: a plain BSS on bcawl3, running.
2. `ADD bss_config=mld0a:/run/a2-mla.conf`: an AP MLD first link, on the grouped wiphy (one wiphy for the radios).
3. `hostapd/main.c:373` `hostapd_driver_init`: the driver does not advertise MLO (`WPA_DRIVER_FLAGS2_MLO`, from
   `NL80211_ATTR_MLO_SUPPORT`) -> "MLD: Not supported by the driver", return -1. This check runs AFTER
   `hapd->driver->hapd_init()` has succeeded, and on the grouped wiphy the new BSS was attached to bcawl3's
   driver context.
4. Cleanup (`hostapd_deinit_driver`): "Teardown AP(mld0) link 0", "remove link: Link not found", "No more links
   remaining, so remove interface", "Not the first BSS - remove it", "Teardown AP(mld0) - device_ap_sme=1",
   "Unsubscribe mgmt frames ... (AP teardown (dev SME))" — and the log ENDS there. No terminate/deinit lines
   follow: the process did not exit through eloop (terminate_on_error is 0 with `-g`); it died. The plain BSS on
   bcawl3 went with it.

**Why it matters for the product:** the product runs ONE hostapd for every radio (§ the failure-isolation note).
One MLD config ADDed on a driver/wiphy without MLO support therefore takes every network of every radio down —
the very class the supervised restart does not cover (the watcher reloads a dead hostapd at most 3 times per
10 min; a list that re-ADDs the MLD kills it again each time, and then it is left dead and reported).

**Gate (when MLO ships, generator + service):**
- The generator renders an MLD (`mld_ap=1`) section only when the service passes the radios whose driver
  advertises MLO (like `-B` for beacon protection): never by default. -F says `feature mld 0|1`.
- The service reads the capability per wiphy before rendering: the nl80211 attribute
  `NL80211_ATTR_MLO_SUPPORT` (cfg80211 `WIPHY_FLAG_SUPPORTS_MLO`). ⚠Whether `iw phy <phy> info` prints it on the
  OS's iw is UNREAD; if it does not, the source is the wiphy dump read another way (a small nl80211 reader, or a
  driver-exported flag) — to settle with mlo-prod before MLO ships.
- An MLD unit is its own ADD unit (label: the MLD name), so its failure is recorded against it, not a radio.
- Keep hostapd's own refusal as the second line of defence only: in 2.12 that refusal is what kills the process.

**Upstream (hostapd 2.12) — a bug worth reporting, evidence level stated:** a configuration error detected in
`hostapd_driver_init` (MLO not supported by the driver) is reported AFTER the driver context is set up and,
on a wiphy whose context is shared with a running interface, its cleanup takes the running interface down and
the process dies instead of failing that ADD alone. Proven: the order of the check (source, main.c:302 hapd_init,
:371 the MLO check), the sequence and the abrupt end of the log. NOT proven: the exact fault (no core, no
backtrace; a use-after-free in the shared-context teardown is the hypothesis). Not checked: hostapd's current
upstream tree (whether the check moved before hapd_init or into config validation). A reproduction without this
hardware for the report: mac80211_hwsim with MLO support off (its `mlo` module parameter), `hostapd -g`, ADD a
plain BSS, then ADD an `mld_ap=1` config on the same phy.

## Design rules for the MLO launcher (lane mlo-prod's finding, 11-10: nothing to build until MLO ships)

hostapd 2.12 dies whenever an MLD link ADD fails inside a running `-g` hostapd: a non-first link the driver refuses
(R4s2: `APSTA-JOIN -ENETDOWN` on a radio with no running primary), or any MLD on a driver without MLO (hazard 2).
Every network of the process goes with it. Rules the generator + service must follow:

1. **Primaries first.** Start (ADD and wait for ENABLED) the primary BSS of every radio an MLD has a link on,
   before any link ADD of that MLD.
2. **No link on a radio without a running primary.** If a link radio's primary is not ENABLED (failed, given up,
   scheduled off, monitor, station-only), that MLD is not ADDed at all — reported, never tried.
3. **Capability gate.** Every MLD ADD is gated on the driver's MLO capability per wiphy (hazard 2's gate).
4. **Supervision.** A hostapd that dies during/after an MLD ADD is an MLD-CONFIG failure, not a radio failure: the
   reload that restarts the process must NOT ADD that MLD again (record it, e.g. `$STATE/failed/mld-<name>`, given up
   at once — one try, not three: each try kills every network). The bounded-retry budget of a radio (3 per config)
   does not apply to MLDs; a new MLD config (checksum) gets one new try.
5. **Order of a reload:** plain radios and their BSSes first (as today), MLDs last, each MLD in its own ADD unit
   (label = the MLD name), so a failure is attributed to it.
