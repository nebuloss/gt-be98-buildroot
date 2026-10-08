#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-2.0
"""Add the rootfs initrd to a GT-BE98 bootfs FIT, and find where it lands.

    fit-rootfs.py add  BOOTFS.its FILE OUT.its [NAME [TYPE]]
    fit-rootfs.py pos  FIT.itb [NAME]     -> prints "<data-position> <data-size>"
    fit-rootfs.py base STOCK.itb          -> prints the stock external-data base

"add" appends an image node NAME (default "rootfs", TYPE default ramdisk; no
compression, sha256) to the .its that mkbootfs.py wrote; post-image.sh also
uses it for the "pad" image of the size probe. No configuration references it: the
vendor U-Boot boots with "bootm start/loados/prep/go" and never runs the
ramdisk step, so U-Boot only copies the node's data into RAM as part of the
whole bootfs volume (read to 0x2000000). The kernel finds it through
/chosen/linux,initrd-start/-end in our DTB (post-image.sh), which U-Boot
leaves alone when it has no ramdisk of its own (fdt_initrd() returns early
for an empty initrd).

The FIT is built with external data at a fixed base (mkimage -E -p), so a
node's data-position is its byte offset from the start of the FIT.
"""
import re
import subprocess
import sys


def dts(path):
    return subprocess.run(["dtc", "-I", "dtb", "-O", "dts", path], check=True,
                          capture_output=True, text=True).stdout


def add(its, cpio, out, name="rootfs", itype="ramdisk"):
    lines = open(its).read().splitlines()
    path, outl, done = [], [], False
    for line in lines:
        s = line.strip()
        m = re.match(r"^([^\s{]+) \{$", s)
        if m:
            path.append(m.group(1))
        elif s == "};":
            if len(path) == 2 and path[1] == "images" and not done:
                outl += ["",
                         "\t\t%s {" % name,
                         '\t\t\tdata = /incbin/("%s");' % cpio,
                         '\t\t\tdescription = "GT-BE98 mainline OS %s";' % name,
                         '\t\t\ttype = "%s";' % itype,
                         '\t\t\tarch = "arm64";',
                         '\t\t\tos = "linux";',
                         '\t\t\tcompression = "none";',
                         "",
                         "\t\t\thash-1 {",
                         '\t\t\t\talgo = "sha256";',
                         "\t\t\t};",
                         "\t\t};"]
                done = True
            path.pop()
        outl.append(line)
    if not done:
        sys.exit("no /images node in " + its)
    open(out, "w").write("\n".join(outl) + "\n")


def pos(itb, name="rootfs"):
    m = re.search(r"\b%s \{(.*?)\n\t\t\};" % re.escape(name), dts(itb), re.S)
    if not m:
        sys.exit("no %s image in %s" % (name, itb))
    body = m.group(1)
    p = int(re.search(r"data-position = <(0x[0-9a-f]+)>", body).group(1), 16)
    n = int(re.search(r"data-size = <(0x[0-9a-f]+)>", body).group(1), 16)
    print(p, n)


def base(itb):
    print(hex(min(int(p, 16) for p in
                  re.findall(r"data-position = <(0x[0-9a-f]+)>", dts(itb)))))


if __name__ == "__main__":
    if 5 <= len(sys.argv) <= 7 and sys.argv[1] == "add":
        add(*sys.argv[2:])
    elif 3 <= len(sys.argv) <= 4 and sys.argv[1] == "pos":
        pos(*sys.argv[2:])
    elif len(sys.argv) == 3 and sys.argv[1] == "base":
        base(sys.argv[2])
    else:
        sys.exit(__doc__)
