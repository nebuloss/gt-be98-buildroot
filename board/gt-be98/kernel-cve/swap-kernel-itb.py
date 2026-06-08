#!/usr/bin/env python3
"""Surgically swap ONLY the kernel Image inside the GT-BE98 device bootfs .itb.

Strategy (preserves every non-kernel component byte-exactly):
  1. Parse the device .itb FIT structure (a DTB header followed by external data
     referenced by data-position/data-size on each /images/<node>).
  2. Extract every image's data blob verbatim from the device .itb by position.
  3. Replace ONLY the `kernel` blob with a caller-supplied new lzo.
  4. Regenerate the FIT .its preserving node order + all props (load/entry/type/
     arch/os/compression), with data = /incbin/(extracted-blob) per node, and an
     empty hash-1{algo=sha256} so mkimage recomputes the hash.
  5. Run the SDK mkimage (-E external data) then re-pad the FIT header to 1280 via
     fit_header_tool and re-run mkimage -p <pad> -E  ==> the final .itb, byte-for-
     byte matching the device framing except the (recomputed) kernel hash.

This mirrors bootloaders/Makefile lines 841-858 exactly, but sources every blob
from the DEVICE itb so u-boot/atf/dtbs stay device-exact.
"""
import struct, subprocess, sys, os, re, hashlib

SDK = "/home/guillaume/be98/gt-be98-firmware/vendor/asuswrt-merlin.ng/release/src-rt-5.04behnd.4916"
MKIMAGE = os.path.join(SDK, "bootloaders/obj/uboot/tools/mkimage")
FIT_HEADER_TOOL = os.path.join(SDK, "bootloaders/build/work/fit_header_tool")
DEVITB = "/home/guillaume/be98/job-tmp/openrc-init-v31/base/bcm96813GW_uboot_linux.itb"

def fdt_totalsize(data):
    assert data[:4] == b"\xd0\x0d\xfe\xed", "not a FIT/DTB"
    return struct.unpack(">I", data[4:8])[0]

def decompile(dtb_bytes, out_its):
    open(out_its + ".dtb", "wb").write(dtb_bytes)
    subprocess.run(["dtc", "-I", "dtb", "-O", "dts", "-o", out_its, out_its + ".dtb"],
                   check=True, stderr=subprocess.DEVNULL)
    return open(out_its).read()

def main(new_kernel_lzo, out_itb, workdir):
    os.makedirs(os.path.join(workdir, "blobs"), exist_ok=True)
    dev = open(DEVITB, "rb").read()
    ts = fdt_totalsize(dev)
    its_txt = decompile(dev[:ts], os.path.join(workdir, "dev-struct.its"))

    # Parse the images block: capture each node name and its full property body.
    images_blk = re.search(r"images \{(.*?)\n\t\};", its_txt, re.S).group(1)
    # Each image node: \t\t<name> { ... \t\t};
    node_re = re.compile(r"\t\t([A-Za-z0-9_+\-]+) \{(.*?)\n\t\t\};", re.S)
    nodes = node_re.findall(images_blk)
    assert nodes, "no image nodes parsed"

    new_kernel = open(new_kernel_lzo, "rb").read()

    def getprop(body, name):
        m = re.search(r"%s = <([^>]+)>;" % re.escape(name), body)
        return m.group(1).strip() if m else None

    its_images = []
    for name, body in nodes:
        pos = int(getprop(body, "data-position"), 16) if getprop(body, "data-position") else None
        size = int(getprop(body, "data-size"), 16) if getprop(body, "data-size") else None
        assert pos is not None and size is not None, "missing pos/size for %s" % name
        if name == "kernel":
            blob = new_kernel
        else:
            blob = dev[pos:pos+size]
            assert len(blob) == size, "short read %s" % name
        blob_path = os.path.join(workdir, "blobs", name + ".bin")
        open(blob_path, "wb").write(blob)

        # Reconstruct node props minus data-size/data-position/data, with /incbin/.
        # Preserve load/entry/type/arch/os/compression/description in original order.
        lines = []
        lines.append("\t\t%s {" % name)
        lines.append('\t\t\tdata = /incbin/("%s");' % blob_path)
        for prop in ("description", "type", "arch", "os", "compression"):
            m = re.search(r'%s = ("[^"]*");' % prop, body)
            if m:
                lines.append("\t\t\t%s = %s;" % (prop, m.group(1)))
        for prop in ("load", "entry"):
            v = getprop(body, prop)
            if v is not None:
                lines.append("\t\t\t%s = <%s>;" % (prop, v))
        lines.append("\t\t\thash-1 {")
        lines.append('\t\t\t\talgo = "sha256";')
        lines.append("\t\t\t};")
        lines.append("\t\t};")
        its_images.append("\n".join(lines))

    # Top-level props: keep description + #address-cells + ident_* from device struct.
    top_desc = re.search(r'description = ("[^"]*");', its_txt).group(1)
    idents = re.findall(r'(ident_\d+ = "[^"]*");', its_txt)
    # configurations block: copy verbatim from device struct
    conf_m = re.search(r"(configurations \{.*?\n\t\};)", its_txt, re.S)
    conf_blk = conf_m.group(1)

    its = []
    its.append("/dts-v1/;\n")
    its.append("/ {")
    its.append("\tdescription = %s;" % top_desc)
    its.append("\t#address-cells = <1>;")
    for idt in idents:
        its.append("\t%s;" % idt)
    its.append("")
    its.append("\timages {\n")
    its.append("\n\n".join(its_images))
    its.append("\n\t};\n")
    its.append("\t" + conf_blk.replace("\n", "\n\t"))
    its.append("};")
    its_text = "\n".join(its) + "\n"
    its_path = os.path.join(workdir, "swap.its")
    open(its_path, "w").write(its_text)

    # mkimage pass 1 (external data), then pad header to 1280, then pass 2.
    tmp_itb = os.path.join(workdir, "tmp_fit.itb")
    subprocess.run([MKIMAGE, "-f", its_path, "-E", tmp_itb], check=True)
    pad = subprocess.run([FIT_HEADER_TOOL, "--hex", "--pad", "1280", tmp_itb],
                         check=True, capture_output=True, text=True).stdout.strip()
    subprocess.run([MKIMAGE, "-p", pad, "-f", its_path, "-E", out_itb], check=True)

    print("pad=%s" % pad)
    print("out_itb=%s size=%d" % (out_itb, os.path.getsize(out_itb)))
    print("out_itb sha256=%s" % hashlib.sha256(open(out_itb, "rb").read()).hexdigest())

if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], sys.argv[3])
