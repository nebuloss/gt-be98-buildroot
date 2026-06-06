# M4 staging notes (2026-06-06)

- rootfs-remove.list / rootfs-rename.list / envrams-wrapper are the br-0033
  batch-1 inputs, parked after the failed trial.
- **DO NOT re-apply `envrams-wrapper` + the envrams rename**: prime suspect
  for the br-0033 MAC-derivation failure. During that boot the device fell
  back to the Broadcom BSP default base MAC (20:CF:30:00:00:00) and WROTE it
  into nvram (et0macaddr/label_mac/lan_hwaddr) with a commit — it survived
  the rollback to br-0032 and broke the DHCP reservation (lease moved
  10.0.0.8 → 10.0.0.95). Repaired 2026-06-06 by restoring the three vars
  from the 2026-06-05 nvram backup + commit + reboot (factory base MAC also
  intact in CFEROM BaseMacAddr as reference). envrams stays UNTOUCHED in the
  image; its retirement remains firewall/kill-based (webui already does
  this), NOT wrapper-based.
- Future slices: ≤5 removals each, one subsystem per slice, breadcrumbs
  (br-0034+) mandatory before any slice trial.

---
M4 CLOSURE (2026-06-06): all batch-1 file removals adopted via six ≤5-path
slices (br-0035..br-0040, each gate 20/20). rootfs-remove.list (cumulative,
in board/gt-be98/) is the live source of truth; this staging dir is
historical. rootfs-rename.list here (envrams rename) and envrams-wrapper
remain BANNED — by elimination they are the br-0033 root cause (see
flash-journal root-cause section). Do not re-apply.
