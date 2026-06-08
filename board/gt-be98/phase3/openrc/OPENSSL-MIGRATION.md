# OpenSSL 1.1.1w -> 3.x migration analysis (open-init / br-0050 base)

Branch `feat/openssl3-and-pkg-trim`, 2026-06-08. BUILD/ANALYSIS ONLY — no device,
no flash, no committed-baseline mutation.

## 1. Provenance verdict: openssl 1.1 is a MONOLITHIC-BLOB lib, NOT a Buildroot package

`libssl.so.1.1` + `libcrypto.so.1.1` (OpenSSL 1.1.1w, EOL Sep 2023) live inside the
proprietary `gt-be98-rootfs-<ver>.tar.gz` blob (package/gt-be98-rootfs), consumed
VERBATIM by post-image-full.sh. They are:

- NOT a Buildroot package: no `BR2_PACKAGE_LIBOPENSSL` / `BR2_PACKAGE_OPENSSL` in any
  open-init-lineage defconfig (full / openrc-init / fromsrc / pkgtest / inverted).
- NOT harvested by rootfs-transform.sh (no libssl/libcrypto reference in the harvest,
  the overlay, or rootfs-remove.list).
- The ONLY from-source openssl in the tree is `gt-be98-br-openssl` **3.6.2**, built
  `no-shared -static`; only `apps/openssl` (the CLI) is harvested to
  `/usr/br/bin/openssl` (and that CLI is itself stripped by openrc-strip.list).

=> There is no openssl source artifact to "version-bump". Replacing the shared
   libssl/libcrypto.so.1.1 means RELINKING the closed merlin binaries that DT_NEEDED
   them — impossible for the closed set.

## 2. Dependent classification (157 ELF link openssl-1.1 in the base; 72 survive the strip)

Scan: `readelf -d` over every ELF in the br-0050 base-rootfs reference.

### REBUILDABLE-from-source (could use openssl-3 in principle)
| binary | status | note |
|---|---|---|
| `usr/sbin/hostapd` | KEPT, closed-ABI-bound | from-source via gt-be98-hostapd (DAEMON), but **byte-identical reproducibility REQUIRES openssl-1.1** to match `libceshared.so`'s ABI (DRIVER_BRCM build). See gt-be98-hostapd.mk "OPENSSL DECISION". NOT a clean openssl-3 target. |
| `usr/sbin/hostapd_cli` | KEPT | built from source with NO openssl (CTRL_IFACE only) — already openssl-free. |
| `usr/sbin/curl`,`usr/lib/libcurl.so.4` | KEPT (blob) | upstream-rebuildable, but it is the BLOB copy; rc DT_NEEDEDs libcurl.so.4. |
| `usr/sbin/openssl` (stock) | KEPT (blob) | stock merlin CLI; the source-built static one is /usr/br (separate). |

### CLOSED merlin blobs — STRIPPED (gone, don't matter): 85 of 157
All strongswan/ipsec (`usr/lib/ipsec/**`, 60 objs), the lighttpd `mod_*.so` +
AiCloud cluster, `Tor`, `aaews`, `asuswebstorage`, `webdav_client`, `openvpn`,
`httpd`, `lighttpd*`, `libasusnatnl`. Removed by openrc-strip.list -> their
openssl-1.1 dependency is inert.

### CLOSED merlin blobs — SURVIVING + openssl-1.1-linked: 72 of 157
The load-bearing / KEEP-critical ones:

| survivor | why it stays | relink to ssl-3? |
|---|---|---|
| **`sbin/rc`** | IRREDUCIBLE keep-set (config_switch / sync_apgx_to_wlunit). Directly DT_NEEDED `libssl.so.1.1`+`libcrypto.so.1.1` plus a closed-lib chain (libshared, libnvram, libbwdpi, libwlcsm, libasc, libletsencrypt, libcurl, libamas-utils) several of which ALSO link ssl-1.1. | **NO** — closed blob, cannot relink. **Hard openssl-1.1 pin.** |
| `usr/sbin/hostapd` | KEPT wifi daemon | NO — see above (libceshared ABI). |
| `sbin/wps_pbcd` | rc companion | NO — closed. |
| `usr/lib/libovpn.so` | rc/wps_pbcd DT_NEEDED (keep-set invariant) | NO — closed. |
| `usr/lib/liblightsql.so`,`libwpa_client.so`,`libcurl.so.4`,`libasc.so`,`libletsencrypt.so`,`libamas-utils.so` | closed libs in rc's dep graph | NO — closed. |

The remaining ~60 surviving ssl-1.1 linkers are dead-but-present clients (iDevice/
libimobiledevice tools, chilli, netatalk uams, snmp, vsftpd, inadyn, stubby, the
asus cloud clients) — orphaned (their launchers/usbmuxd are already removed), inert,
but still on disk inside the blob. They are NOT relinkable (closed) and not worth a
new reverse-dependency-validated strip slice for this task.

## 3. Migration approach + feasibility verdict: **COEXISTENCE, blocked-by-`rc`(+`hostapd`)**

Full migration to openssl-3 is **BLOCKED** by two irreducible KEEP-set closed blobs:

- **`sbin/rc`** — DT_NEEDED `libssl.so.1.1` + `libcrypto.so.1.1` (symbols at the
  OpenSSL 1.1 ABI/soname; openssl-3 ships `libssl.so.3`/`libcrypto.so.3` — a
  different soname, so it would NOT satisfy rc's NEEDED entries even if symbol-
  compatible, which they are not across the 1.1->3 major). rc is the open-init's
  only irreducible wireless role (BSS-slot alloc) and cannot be rebuilt from source.
- **`usr/sbin/hostapd`** — its from-source build is byte-identical to the device
  ONLY against the SDK openssl-1.1 (bound to closed `libceshared.so`).

The Broadcom wl-ioctl graft daemons are SAFE: `wl`, `wlceventd`, `acsd2`, `dhd` link
**zero** openssl (verified). So an openssl-3 swap poses no ABI risk to the graft
datapath — the risk is entirely rc + hostapd.

### Shippable outcome (already the current state — no change needed):
**COEXISTENCE.** Retain `libssl.so.1.1` + `libcrypto.so.1.1` (2.4M+472K) in the base
 for `rc` + `hostapd` + their closed dependency chain (already a DO-NOT-REMOVE
invariant in openrc-strip.list). For the OPEN/rebuildable surface there is already a
maintained OpenSSL **3.6.2** in the tree (`gt-be98-br-openssl`), static-linked into
the /usr/br island (dropbearmulti, openssh sftp/scp) — so the open SSH/SFTP channel
already runs on a maintained OpenSSL 3.x, fully decoupled from the blob's 1.1.

### What a source change would buy — and why none is made here:
- A buildroot `BR2_PACKAGE_LIBOPENSSL` (3.x) shared lib could be ADDED for any
  FUTURE from-source open daemon, installed as `libssl.so.3`/`libcrypto.so.3`
  (distinct soname, no collision with the 1.1 the blob needs). But the open-init
  currently has NO from-source daemon that would dynamically link a shared openssl-3
  (openssh links it statically; hostapd needs 1.1). So adding it now would ship an
  unused lib — deferred until a consumer exists.
- The 1.1 libs CANNOT be dropped while `rc` is the wireless-role binary. Removing
  them is gated on the Phase-3 "rc-non-PID1 / rc-demotion" milestone eliminating
  rc's DT_NEEDED, which is tracked separately.

## 4. Build/rebuild commands

No defconfig/package source change is required for the coexistence outcome (it is the
status quo). To stage a future shared openssl-3 for open daemons:

    # add to a from-source open-daemon defconfig (NOT full/openrc-init base):
    #   BR2_PACKAGE_LIBOPENSSL=y           # -> libssl.so.3 / libcrypto.so.3
    #   BR2_PACKAGE_LIBOPENSSL_BIN is optional
    # then relink the open daemon against -lssl/-lcrypto (soname .3, no 1.1 clash).

The openrc package + /usr/br openssl-3 build unchanged:

    make BR2_EXTERNAL=$(pwd) O=output-openrc-init gt-be98_openrc-init_defconfig
    make BR2_EXTERNAL=$(pwd) O=output-openrc-init openrc

VERDICT: **coexistence; full openssl-3 migration BLOCKED by `sbin/rc` (DT_NEEDED
libssl/libcrypto.so.1.1, closed, irreducible) and `usr/sbin/hostapd` (libceshared
ABI). openssl-3 already serves the open SSH/SFTP surface via the static /usr/br
build. No source edit lands; the 1.1 retention is the documented invariant.**
