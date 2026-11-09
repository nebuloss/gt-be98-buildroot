# One radio failing must not take the others down: how the OS runs hostapd (design note, 2026-11-09)

Status: ANALYSIS ONLY, no code changed by this note. Asked by the orchestrator after lane mlo-prod's R4s2 run
(1109-1631), where one interface failing setup took every interface of the hostapd process down.

## 1. Facts

**The product does not pass configuration files on hostapd's command line.** `init.d/gt-be98-wifi`
`hap_daemon_start` (line ~398) runs ONE process for all four radios with only its global control socket:

    hostapd -B -P /run/hostapd-wifi.pid -t -f /var/log/hostapd.log -g /run/hostapd-global [HOSTAPD_ARGS]

and adds each radio with `ADD bss_config=<phy>:<radio config>` (`unit_restart`, line ~524), each further BSS
with `ADD bss_config=<phy>:<bss config>`, and removes with `REMOVE <ifname>`.

**hostapd 2.12** (the OS's tree, `hostapd-2.12`):

- `hostapd/main.c:1088` `interfaces.terminate_on_error = interfaces.count;` — `count` is the number of
  configuration files given on the command line. With `-g` only it is **0**.
- `src/ap/hostapd.c:2357, 2874, 2920`: an interface whose setup fails calls `eloop_terminate()` (the whole
  process exits) **only if `terminate_on_error` is non-zero**; `:2845` decrements it as each command-line
  interface completes.
- `hostapd_add_iface()` (`:3904`, the control interface's ADD) never sets it.

⇒ The `eloop_terminate()` path seen in R4s2 is the ARM's own launch: `logs/prereg/mlo-prod-r4s2-arm.sh` starts
`hostapd -t -d -f ... /run/r4s2-plain.conf /run/r4s2-mla.conf /run/r4s2-mlb.conf` (three files: terminate_on_error
= 3), so link B's refused start (`APSTA-JOIN[bsscfg 1]: REFUSED -ENETDOWN`) ended the process and with it the
plain AP on bcawl3. The product's start path cannot take that branch. [Derived from the source; the product path
was not re-run with an induced failure.]

**What the product DOES do with a failing radio** (terminate_on_error = 0):

- *Synchronous* failure (config parse, driver init, a setup that completes inside the ADD): ADD answers FAIL,
  `hap_ok` logs `eerror "hostapd: ADD ...: FAIL"`, the radio is not recorded as applied, the service's rc is 1,
  the next start/reload tries again; the other radios are untouched (their units are applied independently).
- *Asynchronous* failure — the usual case on the product: every radio carries `country_code` (with the regdb),
  so setup waits in COUNTRY_UPDATE, then DFS CAC / HT scan / the driver's start_ap: the ADD has already answered
  OK, and the failure later leaves the interface **in hostapd's list in state DISABLED** (`AP-DISABLED` in
  hostapd.log; `hostapd_interface_setup_failure_handler` only acts when a `setup_complete_cb` is set, which the
  ADD path does not). The other radios are untouched.
  **Gap:** the service never notices. On the next reload `unit_apply` finds the interface in INTERFACES
  (line ~547) and the unit unchanged (line ~554: "unchanged"), so a DISABLED radio is **never retried**, and it
  is reported only passively: `rc-service gt-be98-wifi status` prints its state, the web UI's radio row shows
  hostapd's state (APLiveStatus), hostapd.log has the reason.
- MLO: an AP MLD is one hostapd object across the link interfaces of several radios; a failed link deinits the
  MLD. Whether a plain BSS on the same radio as a failed link survives under ADD (no terminate) is NOT read —
  R4s2's teardown of bcawl3 happened on the terminate path, which does not answer it.

**Stock** (the vendor tree's prebuilt `targets/96813GW/fs/sbin/rc`, read by its strings, not run): one Broadcom hostapd (2.10 +
impl103 patches) **per radio**, `hostapd %s %s &` with `/tmp/wl%d_hapd.conf` ("Running hostapd instance using %s
configuration", "kill hostapd instance %d for %s"), so each process has terminate_on_error = 1 but its blast
radius is one radio; rc checks it ("check hostapd status timeout [%s] - FAILED") and the watchdog/debug_monitor
respawns a dead one (the respawn this tree's stock-era patch 0035 gates). Stock has no 6 GHz co-located RNR
built by hostapd and ships MLO off.

## 2. Options

| option | isolates a failed radio | cost / risk |
|---|---|---|
| **A. one hostapd per radio** (stock's shape) | yes, also against a hostapd crash | loses what ONE process gives: hostapd builds the 6 GHz Reduced Neighbor Report from the interfaces of its own process (`rnr=1` on 2.4/5 GHz BSSes, the product default), and an AP MLD (MLO) must have all its links in one process. Four processes, four ctrl dirs, four PID/restart paths in the service. A regression of two shipped features to fix a failure mode the product does not have. |
| **B. global ctrl + ADD** (the product today) | yes for setup failures (terminate_on_error = 0) | none new. Does not cover a hostapd CRASH (one process: every radio goes; the service restarts the process on the next start/reload — no watcher does it today) |
| **C. the service supervises** | adds the missing half of B: detect, report, retry a DISABLED radio | must tell a FAILED radio from one still starting (COUNTRY_UPDATE, DFS with a 600 s weather CAC, HT_SCAN, ACS, NO_IR waiting for a regulatory update); a blind retry loop could hide a real refusal — so bounded and reported |

## 3. Recommendation

**Keep B, add C. Do not split the process (A).**

1. `unit_apply`: a radio hostapd lists but whose first interface is `DISABLED` is NOT "unchanged": record it
   as failed and restart it alone (`unit_restart`, the path a re-probe already uses), at most 3 times per
   (radio, config checksum) with backoff (e.g. 30 s, 2 min, 10 min); then leave it DISABLED and say so. States
   COUNTRY_UPDATE, DFS, HT_SCAN, ACS and NO_IR are "starting", never failed.
2. A watcher pass (fold into `gt-be98-wifi-reprobe`, which already polls the radios every 2 s and runs the
   debounced reload; rename it to a radio health daemon): reads each applied radio's hostapd state; a radio
   DISABLED for 10 s is due for the bounded restart of 1; a dead hostapd process is due for a service reload
   (which restarts the process — today only the next manual reload does).
3. Report, never hide: one syslog line per failure naming the radio, the state, and the last hostapd.log lines
   of that interface (`AP-DISABLED`, "Interface initialization failed", the driver's refusal); a state file
   `$STATE/failed/<dev>` (reason + tries) that `status` prints as an error and the web UI turns into a warning
   ("radio X failed to start: <reason>; retried N times"). A config error never reaches this path (it fails the
   ADD synchronously, or is refused by the generator before).
4. Lab tooling: arms that start hostapd themselves with configuration files on the command line inherit
   terminate_on_error and so report a failure mode the product does not have. Arms meant to read product
   behaviour should start hostapd with `-g` and ADD (as `gt-be98-wifi` does) or go through the service.
5. MLO (mlo-prod): put an AP MLD's link configs in their own ADD units so a failed MLD is removed and retried
   without touching the plain BSSes; first read on the box whether, with terminate_on_error = 0, a failed link
   still deinits the plain BSS sharing its radio (the open question of §1).

Root-cause note: the R4s2 outage of bcawl3 has two causes — the driver's `-ENETDOWN` refusal of link B (mlo-prod's,
its own fix) and the arm's command-line launch. Neither is a defect of the product's start path; the product's
defect is the silent, never-retried DISABLED radio of §1, which items 1-3 fix.

Predictions for the arm that should accompany the fix (not written yet): on an image with 1-3, a radio forced to
fail asynchronously (e.g. a 5gh DFS channel with no country, or the driver refusing start_ap via a bench knob) ends
DISABLED with a `failed/<dev>` record and exactly 3 restarts, every other radio ENABLED throughout, its clients
uninterrupted; on today's image the same radio stays DISABLED with 0 restarts and no error from `status`'s exit
code.
