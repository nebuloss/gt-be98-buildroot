# GT-BE98 mainline OS 1.0-rc15 - release notes

Date: 2026-11-26 · Status: **release candidate 15**, tagged `gt-be98-rc15`.

Evidence is named by the orchestrator's queue (`qNNN`). The run directories
stay on the orchestrator's machine and are not in this repository. Every
number comes with the run that measured it, and "not measured" never means
0. Lab image `imgint16a` is the lab-mode build of the RC15 sources (same
commits, lab keys). The release images below are the `RELEASE=1` build of
those sources.

RC15 is a **defect-fix release** on top of RC14. It changes one thing:

- **Fix: disconnecting a WPA3 (or any PMF) client now works.** In RC14,
  when the access point disconnected a client on a network with protected
  management frames (every WPA3 network, and WPA2 when the client uses PMF),
  the disconnect frame went out unprotected. The client ignored it, as the
  standard requires, and stayed associated while the box had already
  forgotten it: kicking a client from the web UI, band steering, a
  session timeout or a password change did not reach that client, which
  then saw a silent outage until it gave up by itself. The client now
  receives the disconnect, leaves, and reconnects normally (within about
  0.7 s in the tests below).

## Images

| File | sha256 |
|---|---|
| `rootfs.squashfs` | `095fc1cb3d14f074e9c449d5f245cc5a0ba13c06f7b711e98cc18f5282dbda29` |
| `ml-bootfs.itb` | `268229b68410896d69400f816ddc33ee05edf45fb4f4af61e6b435d7ca26274d` |

Build id (DT): `20261126T085532Z-159c0d883129-rw-jffs`

Built with `RELEASE=1` (`ml-bootfs.info`: `release mode: yes`) from
`br-rc15-r-2026-11-26` `84e8b77`. Later commits of that branch change only
`docs/`.

- **Release check:** `release-check.sh` returned PASS (selftest 21/21) with RC7's lab-pattern list.
- **Lab control:** the lab image imgint16a fails the same check with 15 findings, as it should.
- **Exact-pattern list:** finds only the lab public key, as in RC7–RC14.
- **Modules against the tested lab image (imgint16a)**, by the release
  recipe's section gate (`kocmp.py`):
  - `rtl8372.ko` is byte-identical (`7010af97`).
  - `bca_pcie_ipc.ko` (release `1d83f4d2`, lab `050c7070`): 34 of 37
    sections byte-identical.
  - `bcm4916-runner.ko` (release `95b09b77`, lab `c000a45b`): 38 of 41
    sections byte-identical.
  - In both, every code and relocation section is identical, `.rodata` is
    identical once the build-path prefix is swapped, `.symtab` differs only
    in `.rodata` symbol values, and the build-id follows.
- **Against RC14's release image**, file by file (1757 entries each): the
  Wi-Fi module and `/etc/gt-be98-release` (the change), and otherwise only
  build metadata. BusyBox, OpenSSL and socat carry their build time; perf,
  lsof, gawkbug and the libstdc++ gdb script carry the release build
  directory's name; `libdw` and the Runner module differ in their 20-byte
  build-id; chrony in a few bytes, consistent with its NTP era being taken
  from the build time (not confirmed further).

**These images are a TEST build.** Their `SSH_AUTHORIZED_KEYS` is the
lab's public key, so they are never handed over. A hand-over build is the
same sources with the recipient's keys, checked again with
`release-check.sh`. The images contain no SSH host keys, no web UI
password and no rootfs URL. They contain proprietary vendor firmware, so
they are handed over privately and never published (`docs/RELEASE-BUILD.md`).

Lab image imgint16a: `rootfs.squashfs`
`a864c298382f8d0e7ccaa1f9ebf496f35ea77db5126530b8a71d4334cd71f493`, build id
`20261125T200241Z-97eeb5b6a0b5-rw-jffs`. File by file (1764 entries each),
imgint16a differs from RC14's lab image imgint15a in exactly:
- the Wi-Fi module `bca_pcie_ipc.ko` (`088cd0d2` → `050c7070`, the shipped
  build of open-wifi `0dcc9043`, reproduced byte for byte from that commit);
- `/etc/gt-be98-release`.

Built from (`gt-be98-rc15` tags):

| Component | Commit |
|---|---|
| gt-be98-buildroot | `br-rc15-r-2026-11-26` = `br-int16a-2026-11-25` `9a13a5c` (= `mainline-os` `d9ab915` (`gt-be98-rc14`) + the open-wifi pin) + these notes |
| open-wifi (`bca_pcie_ipc.ko`) | `fix-pmf-deauth-order-2026-11-25` `0dcc9043` (= RC14's `b3a483c1` + PMF-DEAUTH-ORDER); module `050c7070` |
| open-ethernet (Runner, kernel series, `rtl8372.ko`) | `ba2aae8`, unchanged since RC14; Runner module `c000a45b`, switch module `7010af97` |
| web UI (gt-be98-webui-go) | `3009db2`, unchanged since RC14 |
| hostapd | 2.12 with the local patches `0001`–`0005`, unchanged since RC14 (`fefda460`) |
| Linux / Buildroot | 7.2.9 / 2026.08 (kernel configuration unchanged since RC7) |

**Shipped Wi-Fi driver parameters:** 36, unchanged. No module parameter
was added; the open-wifi gates on `0dcc9043` are GREEN.

## Changes since RC14

### Fix: an AP-initiated disconnect on a PMF network reaches the client (open-wifi `0dcc9043`)

**The defect (PMF-DEAUTH-ORDER).** When hostapd removed a station, the
driver first told the radio firmware the station was no longer authorized,
which drops its keys, and only then asked it to send the deauthentication.
With the keys gone, the deauthentication left unprotected. A PMF client must
ignore an unprotected deauthentication ("Unprotected Deauthentication frame
dropped" in its log), so it stayed associated.

**The fix (`c783865e`).** The deauthentication is sent first, while the
station still holds its keys (so it is protected), and the station is
deauthorized after it.

**Box evidence**
- q442 (RC14's module, 6 GHz WPA3-SAE, PMF required): the client dropped
  the deauthentication as unprotected (the defect). With the order swapped:
  the client logged the disconnect after 0.12 s and reconnected after 0.67 s.
- **q444 (imgint16a, its own module and hostapd):**
  - 6 GHz WPA3-SAE, PMF required: disconnect +0.18 s, 0 unprotected frames
    dropped, reconnect +0.66 s, 5/5 pings after: PASS;
  - 5 GHz WPA2 with PMF optional (the control): disconnect +0.14 s, 0
    dropped, reconnect +0.64 s, 5/5: PASS.

## Box evidence (imgint16a unless noted)

| Queue | Image | Result |
|---|---|---|
| q442 | RC14 + bench modules | the defect found and the order swap proven (above) |
| q444 | imgint16a | **PMF disconnect P6 + C5 PASS**; L1 radio cycles clean; WIFISTOP PASS; soak DRY-OK; multi-SSID (two BSS, one removed and re-added under the other's ping: 0 % loss; isolation holds) PASS; perf smoke 5 GHz-low and 6 GHz as RC14; its 2.4 GHz client rows low and its 30-minute soak INCONCLUSIVE, both re-run in q448 |
| q448 | imgint15a / imgint16a / imgint15a | **2.4 GHz A/B/A: no image regression.** perf 2.4 GHz tcp-up RC14 28.1–32.5, RC15 30.1–31.4, RC14 again 28.1–31.2 Mbit/s (down 42–44 everywhere); the low L1 2.4 GHz battery reading (5.3 / 3.8 Mbit/s up) hit RC14's first leg too (RC15's legs 30.4 / 28.0, RC14's second 31.1 / 30.0), a lab-bench effect. **60-minute instrumented soak VERDICT PASS** (shape FLAT, decline 7.6 MB, +16.3 MB after teardown, stations 2 → 3); clean, CHECK and baseline PASS |
| q450 | release | Release-image phases: FIRST 16/16 PASS (W2b-BIND 0 s). Its SECOND did not reach the release image: after FIRST's reboot the slot-1 boot did not answer within the queue's boot budget (port 22 refused, the box back on the stock firmware when the check began), the queue did not check that, and the phase scored empty reads (3 FAIL, 3 hollow ok). The saved release state was on the NAND (q454 read it: host keys and the web UI database present). A harness fault, not a product verdict; the arm was hardened (r3: no check scored unless the release image answers) |
| q454 | release | **Release-image phases PASS:** FIRST 16/16 (W2b-BIND 0 s); the slot-1 boot watched: the release image answered after 85 s on the first attempt; SECOND (r3) 6/6 on the confirmed release build: same host-key fingerprint after the reboot, keys restored not regenerated, still configured, no setup token, login. The lab image imgint16a restored afterwards |

## Known open

Unchanged from RC14. In addition:
- **One slot-1 boot did not answer within the release test's budget**
  (q450: after the first-boot phase the box was found on the stock firmware
  about 9 minutes later). Not reproduced: q454's boot answered after 85 s on
  the first attempt. Watched in every later release run.
- **MLO:** an AP MLD link going down is not yet a clean, protected
  disconnect for its clients (work in the separate MLO driver build; MLO is
  not in RC15).
