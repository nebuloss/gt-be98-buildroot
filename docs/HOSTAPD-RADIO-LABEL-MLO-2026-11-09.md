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
