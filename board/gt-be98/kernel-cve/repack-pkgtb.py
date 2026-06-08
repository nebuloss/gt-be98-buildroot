#!/usr/bin/env python3
"""Repack GT-BE98 .pkgtb = [FIT-DTB] + [bootfs.itb] + [rootfs.squashfs].

Parameterized version of the v31 repacker. Args: <itb> <squashfs> <out.pkgtb>.
Reproduces the exact external-data FIT structure of the v31/blob0035 pkgtb: the
outer FIT-DTB lists bootfs (data-offset 0) and rootfs (data-offset = itb size),
then the raw itb and squashfs are concatenated after the 4-byte-aligned DTB.
"""
import struct, subprocess, hashlib, sys, os, tempfile

def hex_words(h):
    return " ".join("0x%s" % h[i:i+8] for i in range(0, 64, 8))

def main(itb_path, sq_path, out_path):
    itb = open(itb_path, "rb").read()
    sq  = open(sq_path, "rb").read()
    itb_size, sq_size = len(itb), len(sq)
    bf_hash = hashlib.sha256(itb).hexdigest()
    sq_hash = hashlib.sha256(sq).hexdigest()

    its = """/dts-v1/;

/ {{
\ttimestamp = <0x6a2658a3>;
\tdescription = "GT-BE98";
\tasus = "ASUSFLAG#1";
\t#address-cells = <0x01>;

\timages {{

\t\tbootfs_6813_a0+ {{
\t\t\tdata-size = <{bf_size:#x}>;
\t\t\tdata-offset = <0x00>;
\t\t\tdescription = "bootfs";
\t\t\ttype = "multi";
\t\t\tcompression = "none";

\t\t\thash-1 {{
\t\t\t\tvalue = <{bf_hash}>;
\t\t\t\talgo = "sha256";
\t\t\t}};
\t\t}};

\t\tnand_squashfs {{
\t\t\tdata-size = <{sq_size:#x}>;
\t\t\tdata-offset = <{sq_off:#x}>;
\t\t\tdescription = "rootfs";
\t\t\ttype = "filesystem";
\t\t\tcompression = "none";

\t\t\thash-1 {{
\t\t\t\tvalue = <{sq_hash}>;
\t\t\t\talgo = "sha256";
\t\t\t}};
\t\t}};
\t}};

\tconfigurations {{
\t\tdefault = "conf_6813_a0+_nand_squashfs";

\t\tconf_6813_a0+_nand_squashfs {{
\t\t\tdescription = "Brcm Image Bundle";
\t\t\tbootfs = "bootfs_6813_a0+";
\t\t\trootfs = "nand_squashfs";
\t\t\tcompatible = "flash=nand;chip=6813;rev=a0+;ip=ipv6,ipv4;ddr=ddr4;fstype=squashfs";
\t\t}};
\t}};
}};
""".format(bf_size=itb_size, bf_hash=hex_words(bf_hash),
           sq_size=sq_size, sq_off=itb_size, sq_hash=hex_words(sq_hash))

    with tempfile.TemporaryDirectory() as td:
        its_p = os.path.join(td, "fit.its"); dtb_p = os.path.join(td, "fit.dtb")
        open(its_p, "w").write(its)
        subprocess.run(["dtc", "-I", "dts", "-O", "dtb", "-o", dtb_p, its_p], check=True)
        dtb = open(dtb_p, "rb").read()
        totalsize = struct.unpack(">I", dtb[4:8])[0]
        dtb = dtb[:totalsize]
        aligned = (totalsize + 3) & ~3
        dtb = dtb + b"\x00" * (aligned - totalsize)
        out = dtb + itb + sq
        open(out_path, "wb").write(out)

    print("dtb totalsize=%d aligned=%d" % (totalsize, aligned))
    print("itb=%d squashfs=%d" % (itb_size, sq_size))
    print("pkgtb=%s size=%d" % (out_path, len(out)))
    print("pkgtb sha256=%s" % hashlib.sha256(out).hexdigest())
    print("rootfs sha256=%s" % sq_hash)
    print("bootfs(itb) sha256=%s" % bf_hash)

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], sys.argv[3])
