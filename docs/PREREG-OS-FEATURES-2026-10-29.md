# Pre-registered box arms: OS features lane (2026-10-29)

Lane `os-features-2026-10-29` (gt-be98-buildroot and gt-be98-webui-go, same
branch name). Written before any run. The runnable script holds lab
addresses and is kept outside git (`osfeat-arms.sh`, next to the other
lanes' arm scripts on the orchestrator's machine). It prints one
`VERDICT-<arm>` line per arm. A reading it could not take prints `UNREAD`,
and an `UNREAD` is never scored as 0.

Clients: the two lab clients. "MT" is the MT7925 in its own netns. "RTL" is
the RTL8188 (2.4 GHz only) in its own netns. Both arms use a 2.4 GHz WPA2
network on `bcawl3`, the only band both clients have. Every network is
bridged to an unused VLAN on `rnr0`, so a client gets no address. The
endpoint is the supplicant's `wpa_state`, never a ping. The box's
`/etc/conf.d/gt-be98-wifi-ap` is saved first and restored at the end, and
so is the service state it started in.

## M: per-network `max_clients` (any mainline-os image)

The path under test: the UI's `max_clients` becomes `max_clients=N` in the
network list, then `max_num_sta=N` in the BSS section, rendered by
`gt-be98-wifi-gen` into both the radio config and the single-BSS config.

The mechanism, read from the code. hostapd 2.12 runs this driver as
FullMAC, so the firmware completes the 802.11 association by itself. Then
`hostapd_notif_assoc` calls `ap_sta_add`. When `num_sta >= max_num_sta` that
returns NULL, and hostapd calls `hostapd_drv_sta_disassoc(...,
WLAN_REASON_DISASSOC_AP_BUSY)`. That reaches open-wifi `.del_station` as
DEAUTHORIZE plus ioctl 201 with reason 5, which logs
`DELSTA: <mac> ... reason=5`. hostapd logs "no more room" only at debug
level, so the arm does not read it.

| phase | list | action | reading |
|---|---|---|---|
| PRE | no `max_clients` | `rc-service gt-be98-wifi start`; MT joins, then RTL | both `COMPLETED` within 45 s; `all_sta` = 2 |
| CAP | `max_clients=1` | `reload` (an anchor change restarts the radio); MT joins, then RTL is watched for 45 s | `max_num_sta=1` in `hostapd-bcawl3.conf` and `bss-bcawl3.conf` (2 lines); MT `COMPLETED`; the RTL states seen; `all_sta`; dmesg `DELSTA: <RTL> ... reason=5` count; MT disconnects; RTL association attempts |
| POST | `max_clients=2` | `reload`; both rejoin | both `COMPLETED` within 60 s |

- **PASS**: PRE has both clients. In CAP, RTL never reaches `COMPLETED`,
  `all_sta` = 1, there are 1 or more `DELSTA` reason=5 lines for RTL, and
  MT does not disconnect. POST has both clients again.
- **PASS-WITH-SIDE-EFFECT**: as PASS, but MT disconnected during CAP. This
  is the driver's one-client-record-per-radio bookkeeping, and it is a
  finding for the driver lane.
- **PASS-MECHANISM-UNREAD**: RTL was refused and POST passes, but no
  `DELSTA` reason=5 line appeared.
- **REFUTED**: during CAP, with `max_num_sta=1` rendered, RTL reaches
  `COMPLETED` or `all_sta` reaches 2 or more.
- **PARTIAL**: RTL was refused in CAP, but POST does not have both clients
  back, so the control failed.
- **VOID**: any of these:
  - PRE does not hold two clients (the bench, not the feature);
  - `max_num_sta=1` is not rendered twice;
  - MT does not join in CAP;
  - RTL never attempted an association;
  - any `Oops|BUG:|WARNING:|Call trace|DEATH[|FW TRAP|PRODUCER DEAD` line;
  - any line UNREAD.

Prediction: PASS or PASS-WITH-SIDE-EFFECT. RTL's supplicant keeps retrying,
so it should show repeated association attempts, each one ending in a
reason-5 disconnect.

## S: schedules (an image built from this branch or later)

Two networks on 2.4 GHz:
- A (always on). RTL joins it.
- B (`schedule=daily@<now-1min>-<E>`), where E is the next minute boundary
  at least 3 min ahead. MT joins it.

`WIFI_SCHED_TZ` is empty, so the window is in UTC. B is the second BSS
(`bcawl3-1`), so removing it is a per-BSS `REMOVE` and must leave A
untouched.

1. Start. `/run/gt-be98-wifi/gen/sched` = `net 912 on`, `bcawl3-1` is in
   the hostapd INTERFACES list, the scheduler daemon is alive, and both
   clients are `COMPLETED`.
2. The window ends. Poll every 2 s until E + 120 s. Record the time at
   which `bcawl3-1` has left INTERFACES and the sched file reads `off`.
   Record A's client disconnects.
3. Reopen. Rewrite only the list with a 30-minute window and do not reload.
   The daemon must bring B back by itself. Record the time until
   `bcawl3-1` is back, B's BSSID (the plan's) against the one in step 1,
   and MT's rejoin.

- **PASS**: B is off within 90 s of E. RTL on A has 0 disconnects. B is
  back within 130 s of the reopen, with the same BSSID. MT rejoins B.
- **PASS-WITH-SIDE-EFFECT**: as PASS, but adding B back disconnected A's
  client.
- **REFUTED**: any of these:
  - B is still up at E + 120 s, or goes off later than 90 s after E;
  - removing B disconnects A's client;
  - B is not back within 130 s;
  - B comes back with another BSSID.
- **PARTIAL**: B is back with the same BSSID, but MT does not rejoin.
- **VOID**: any of these:
  - the image has no `gt-be98-wifi-sched`, or `gt-be98-wifi-gen -F` lacks
    `feature schedule 1`;
  - chrony's leap status is not `Normal`. Schedules are then off by
    design, and the unsynchronised path is unit-tested only;
  - the start state is wrong;
  - any bad dmesg line.

Prediction: B goes off 2 to 70 s after E. That is one tick at the next
minute boundary plus the per-BSS `REMOVE`. B comes back within 60 to 75 s
of the reopen, with the same BSSID, because the slot and index are kept
while off.

## L: LED inventory (read only, any image)

This arm reads:
- `/sys/class/leds`, and for each LED its `max_brightness`, trigger and
  device;
- `/sys/class/net/bcawl*/device/leds`;
- the count of `*led*` nodes in `/proc/device-tree`;
- `CONFIG_LEDS_{CLASS,GPIO,TRIGGER_NETDEV}` in `/proc/config.gz`;
- `gt-be98-leds status`.

It writes nothing. Predictions:
- On an image from this branch, the LED class is present and empty. There
  are no `device/leds` under the radios, and no LED node in the board DT.
- On an older image, there is no LED class.

Any LED that does exist is a new fact. The Wi-Fi LEDs are expected to stay
absent until the driver registers a LED class device per radio. On stock
they are GPIO 12 of each radio chip, run by the firmware (`wl ledbh 12 7`).

**VERDICT-L** is `READ (LED class present)` or `READ (no LED class)`. The
inventory is in the log.

## Not pre-registered (needs other lanes)

- **Wi-Fi LEDs blinking**: these need the open-wifi driver to register a
  `led_classdev` per radio, with the radio's PCI device as parent. On that
  LED, brightness maps to iovar `ledbh 12 0|1`. Best is a netdev-trigger
  hardware offload to behaviour 7 (WL_LED_WI1), so that a blink is not a
  firmware ioctl. Then `gt-be98-leds` sets the netdev trigger and the arm is
  "radio up = LED on, traffic = blink, `offloaded` = 1".
- **SoC LEDs** (power 50, LAN 1, 10G 47, WAN 17/43, AFC 48, active low):
  these need `gpio-leds` nodes in the board DT (open-ethernet `dts/`), with
  the pinmux checked on silicon first.
- **TWT / WDS**: the UI and API hooks exist, but the generator's `-F`
  reports them as 0. They have no arm until a lane implements the generator
  keys.
- **6 GHz 40/80/160/320 MHz**: implemented by lane `os-6gwidth-2026-10-30`
  (`width 6g 20 40 80 160 320`, `feature width320 1`); its box arm is
  pre-registered with that lane's report, outside this repo.
