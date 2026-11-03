# Pre-registered box test: release flashing, end to end (2026-11-02)

Lane `release-docs` (gt-be98-buildroot branch `br-release-docs-2026-11-02`).
This was written before any run. It tests `docs/FLASHING.md` and
`board/gt-be98-mainline/flash/gt-be98-flash.sh` on the development box, once:
stock, then flash, then boot mainline, then back to stock, then mainline
again without re-flashing. The runnable script contains lab addresses and is
kept outside git (`release-flash-e2e.sh`, next to the other arm scripts on
the orchestrator's machine). It prints one `VERDICT-<step>` line per step
and a final `VERDICT-E2E`. A reading it could not take is `UNREAD`, never
counted as passing or failing.

Input: a flash kit built on the build host by `build-flash-kit.sh` from the
images the box should run afterwards. The box ends on the mainline OS,
running the kit's images.

## Steps and endpoints

| Step | Action (FLASHING.md step) | Scored endpoint |
|---|---|---|
| P0 | if the box is on mainline: `reboot`, wait for stock | not scored (start state) |
| S1 | copy the 8 kit files to stock `/tmp/gtb` (2) | `sha256sum -c SHA256SUMS` on stock: 8 OK |
| S2 | `gt-be98-flash.sh status` (3) | `booted slot 2`, `committed 2`; `reset_reason: 34` recorded |
| S3 | `flash --check` with the kit's sha256s (3) | rc 0 and `check only: nothing written` |
| S4 | `flash` (4) | rc 0 and `FLASH-OK` (both volumes read back) |
| S5 | `boot --check`, then `boot --clear-postcode` (5) | rc 0; `post-code byte cleared` and `BOOT-ARMED`; stock stops answering within 90 s |
| S6 | find the box, check on mainline (5) | found as MAINLINE within 600 s; `/proc/device-tree/gt-be98,build-id` = the kit's `build id (DT)`; `BOOT_ROOT_SOURCE=ubi:rootfs1`; `gt-be98-health -q` rc 0 **and** post-code `fb`, within 300 s |
| S7 | `reboot` on mainline (6) | found as STOCK within 900 s; `ubi.block=0,6`; `committed 2`; vol 4 / vol 3 sha256 over the image lengths = the kit's (slot 1 unchanged); post-code byte and `reset_reason` recorded |
| S8 | copy `gt-be98-flash.sh` only, then `boot` (no options, the helper's own reboot) (6) | `BOOT-ARMED`; stock stops answering within 90 s |
| S9 | as S6 | as S6 |

Recorded, not scored: time from arming to mainline ssh (S6, S9), time from
the mainline reboot to stock ssh (S7), the boot-state register value on
stock after the round trip (`fe` in the top byte expected: a clean OpenRC
shutdown), `reset_reason` after the round trip (S2 and S7), the S4 flash
duration.

## Verdicts

- **PASS**: every scored endpoint of S1 to S9 holds.
- **REFUTED `<step>`**: the bench was valid and a scored endpoint failed. In
  particular: the helper refuses on a healthy box (S3, S5, S8); the box
  comes back on stock instead of mainline (S6, S9: the script reads the
  post-code then); mainline runs another build or takes its rootfs from
  elsewhere (S6, S9); a mainline reboot does not land on stock, or slot 2
  is no longer committed (S7); slot 1 changed while mainline ran (S7).
- **VOID `<reason>`**: the test could not be run as designed: the box lock is
  held; the kit is missing or its `SHA256SUMS` fails on the build host; no
  box is found at the start; stock ssh fails before anything is written;
  a transfer arrives with a wrong sha256 (S1, S8); at S2, stock is not on
  slot 2 with slot 2 committed. The FLASHING.md prerequisite does not
  hold, so the run says nothing about the procedure.

## Predictions

- S2 and S7 `reset_reason` 34: the box reaches stock by warm reboot. If S7
  is not 34, S8 refuses (the helper's `expected 34`). That reading would
  REFUTE the FLASHING.md claim that a warm reboot leaves 34.
- S5: `--clear-postcode` leaves bits [23:0] unchanged. This is the
  read-modify-write the lab has used before every slot-1 boot. The helper
  re-reads the register and refuses to arm if [23:0] changed.
- S6/S9: about 1 to 2 minutes from arming to ssh (TESTPLAN.md T1: ssh at
  about 50 s after the kernel starts, plus the stock shutdown and the
  bootloader). S7: about 2 to 3 minutes to stock ssh.

## Not covered by this run

- A cold start (power cycle) before arming: `reset_reason` is then not 34,
  and the helper refuses by design. Whether a one-shot boot armed after a
  cold start works is still unmeasured.
- The automatic return to stock of a mainline boot that fails: it is
  covered by earlier trials (open-ethernet
  `docs/mainline-noUART-bringup.md`, stage 0b and cycles 01-15), not by
  this run.
- A box whose stock runs from slot 1, and the ASUS-update path in the
  FLASHING.md prerequisites.
- Option B of FLASHING.md (stock re-arms mainline at every boot): design
  only.
