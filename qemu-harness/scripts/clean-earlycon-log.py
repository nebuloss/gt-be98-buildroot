#!/usr/bin/env python3
# clean-earlycon-log.py — reconstruct a readable console log from a harness run.
#
# The merlin amba-pl011 runtime console ("ttyAMA0") does not enable on -M virt
# (its clock is set up by the SoC init we stubbed), so the only console that
# works is the *earlycon* path. QEMU emits "PL011 data written to disabled UART"
# after every byte the guest pushes through earlycon, so the raw -nographic
# capture is one console char per warning line. This strips the warnings and
# reflows the carriage-returns back into readable kernel log lines.
#
#   qemu ... 2>&1 | clean-earlycon-log.py > traces/dhd-harness.log
#   clean-earlycon-log.py raw.log          > clean.log
import sys

src = sys.argv[1] if len(sys.argv) > 1 else None
raw = (open(src, "rb").read() if src else sys.stdin.buffer.read()).decode("utf-8", "replace")
raw = raw.replace("PL011 data written to disabled UART", "")
# device-model qemu_log() lines (bcm-fmac-stub: ...) are emitted with real \n and
# survive; keep them. Everything else is earlycon bytes separated by stray \n.
joined = raw.replace("\n", "")
lines = [l for l in joined.split("\r") if l.strip()]
sys.stdout.write("\n".join(lines) + "\n")
