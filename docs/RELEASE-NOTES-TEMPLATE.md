# GT-BE98 mainline OS <VERSION> - release notes

<!--
Template. Copy to docs/releases/<VERSION>.md (or the release page) and fill
every <...>. Rules:
- a number goes in only with the run that produced it (log name, date,
  image); no number means "not measured", never 0;
- a feature goes under "What works" only if a box run on THIS image (or on an
  image with the same driver pins) shows it; otherwise "Known limits";
- no lab addresses, MACs, host names, user names or passphrases;
- the images themselves are never attached to a public page (they contain
  proprietary vendor firmware): give the sha256s, hand the kit over privately.
-->

Date: <YYYY-MM-DD> · Status: <release candidate | release>

## Images

| File | sha256 |
|---|---|
| `rootfs.squashfs` | `<from IMAGES.sha256>` |
| `ml-bootfs.itb` | `<from IMAGES.sha256>` |

Build id (DT): `<"build id (DT)" line of ml-bootfs.info>`

Built from:

| Component | Commit |
|---|---|
| gt-be98-buildroot `mainline-os` | `<sha>` |
| open-wifi (`bca_pcie_ipc.ko`) | `<pin in package/gt-be98-open-wifi>` |
| open-ethernet (Runner, kernel series) | `<pin in package/gt-be98-open-ethernet>` |
| web UI (gt-be98-webui-go `mainline-os`) | `<sha, or "not included">` |
| Linux / Buildroot | `<7.2.9>` / `<2026.08>` |

Release configuration (`local.conf`, values not secrets): SSH keys of
`<who>`, `ROOTFS_URL` `<empty | owner server>`, `NAND=<rw-jffs>`, web UI
`<enabled | not included>`, telnet lifeline `<auto>`.

## Installing, booting, going back

Follow `docs/FLASHING.md` (repository commit `<sha>`): verify the sha256s
above, flash slot 1 from stock with `gt-be98-flash.sh`, boot it once,
`reboot` to return to stock. **Every reset, including a power cut, returns
the box to stock**: run the boot step again after it (FLASHING.md, "Making
the mainline OS the default boot").

End-to-end flashing test on this image: `<PASS/REFUTED/VOID, log, date>`
(`docs/PREREG-RELEASE-FLASH-E2E-2026-11-02.md`).

## What works

<!-- one line per feature, each with its evidence (arm/log name, date) -->

| Area | Feature | Evidence |
|---|---|---|
| Boot | one-shot boot from slot 1, rootfs from vol 4 (sha256-checked), watchdog return to stock | <run> |
| Ethernet | Runner driver: LAN port, <ports> | <run> |
| Wi-Fi | radios: <2.4 / 5 / 6 GHz>; APs per radio: <n>; security: <open, WPA2-PSK, WPA3-SAE(-H2E), WPA2/3-Enterprise, OWE AP> | <run> |
| Wi-Fi | station (client) mode: <WPA2, SAE> | <run> |
| Wi-Fi | bridged VLANs per network, Runner Wi-Fi offload <on/off> | <run> |
| Wi-Fi | 6 GHz widths <20/40/80/160/320 MHz> | <run> |
| Wi-Fi | airtime fairness <off by default> | <run> |
| Web UI | <pages> | <run> |
| Persistence | settings saved in stock `/jffs` (`gt-be98-save`, autosave) | <run> |

## Measured numbers

<!-- copy from the run summaries; give the direction, the client and the band -->

| Measurement | Value | Run (log, date, image) |
|---|---|---|
| boot: reboot to ssh | <s> | <run> |
| rollback: mainline reboot to stock ssh | <s> | <run> |
| Ethernet routed / bridged throughput | <Gbit/s> | <run> |
| Wi-Fi throughput 2.4 GHz (client, mode) | <Mbit/s up / down> | <run> |
| Wi-Fi throughput 5 GHz | <Mbit/s> | <run> |
| Wi-Fi throughput 6 GHz | <Mbit/s> | <run> |
| WPA3-SAE station / AP | <Mbit/s> | <run> |
| CPU load at <throughput> | <%> | <run> |
| driver reload cycles without loss | <n/N> | <run> |
| uptime soak | <h, no reset> | <run> |

## Known limits

<!-- keep the ones that still hold for THIS image; remove those fixed, with
the fix's commit in "Changes since" -->

- Boot is one-shot: any reset or power cut returns to stock until the boot
  step is run again (by design, FLASHING.md).
- The rootfs contains the SSH host keys and the web UI password hash of
  the release build (PERSISTENCE.md, "secrets off the served rootfs"): do
  not share the kit.
- Web UI changes live in the RAM overlay unless saved
  (`board/gt-be98-mainline/README.md`, "Web UI"): <state for this image>.
- Wi-Fi MLO: <not available>.
- Wi-Fi station: OWE <not supported>; 4-address (WDS) repeater <not
  working>.
- Radio removal under load: <rate of the remove-time timeout seen in
  long runs>.
- <others from the orchestrator's open items>

## Changes since <previous version>

- <commit range per repository, one line each>

## Reporting a problem

Include: the output of `gt-be98-status` (on mainline) or
`gt-be98-flash.sh status` (on stock), the post-code byte read on stock
after a failed boot, `ml-bootfs.info`, and what was done since the boot.
