# OpenSSL 1.1.1w -> 3.x migration — v31 (rc-FREE) re-scope

Branch `feat/openssl3-v31`, off **v31** (commit 9267338, the rc-free open-init:
v30 removed `sbin/rc` + `sbin/hnd-write` + `usr/lib/libconn_diag.so`, v31 added the
committed-boot health-window auto-revert). ANALYSIS + low-risk source changes ONLY —
no device, no flash, no committed-baseline mutation.

This supersedes the earlier v27 scoping (branch `feat/openssl3-and-pkg-trim`), which
was written while `sbin/rc` was still in the image and (correctly, at the time)
named `rc` as the dominant irreducible openssl-1.1 pin. **rc is GONE in v31, so the
1.1-consumer surface has been re-scanned from scratch below.**

---

## 0. TL;DR verdict

- **rc removal did NOT close the EOL-1.1 gap.** With `rc` gone, the LIVE (actually
  launched) openssl-1.1 surface collapses to **exactly ONE daemon: `hostapd`** — but
  hostapd is the security-critical WPA authenticator and is **irreducibly pinned to
  openssl-1.1** by the Broadcom SDK (TLS=openssl against `router/openssl` 1.1.1w +
  closed `libceshared.so`, DRIVER_BRCM). Same floor as the kernel: the SDK
  (src-rt-5.04behnd.4916) ships **openssl 1.1.1w everywhere** and has **no openssl-3
  anywhere**.
- The open SSH/SFTP surface (`/usr/br`, dropbearmulti + OpenSSH sftp-server) already
  runs on a maintained **OpenSSL 3.6.2**, **statically linked** — fully decoupled from
  the blob's 1.1. No dynamic openssl-3 consumer exists to relink.
- **Achievable ceiling = COEXISTENCE (unchanged): openssl-3.6.2 for the open `/usr/br`
  surface (already shipped) + openssl-1.1.1w retained ONLY for hostapd (live) and a
  set of present-but-NOT-launched closed blobs.** No clean low-risk relink target
  exists, so **no binary/relink change is landed**; the only change on this branch is
  this documentation re-scope.
- **The residual EOL-1.1 exposure is IRREDUCIBLE without a newer Broadcom SDK** — the
  same conclusion, and the same root cause, as the pinned 4.19 kernel / glibc 2.32.

---

## 1. Provenance: openssl-1.1 is a SDK-from-source lib delivered as a blob

`libssl.so.1.1` + `libcrypto.so.1.1` = **OpenSSL 1.1.1w (11 Sep 2023, EOL)**. They are
NOT a Buildroot package in any open-init defconfig. They originate as a *from-source*
build inside the Broadcom/merlin SDK and are delivered into the rootfs as a graft:

    SDK src-rt-5.04behnd.4916/router/openssl/Makefile : VERSION=1.1.1w
    package/gt-be98-hostapd/src/build-hostapd-daemon.sh : cp router/openssl/lib{ssl,crypto}.so.1.1

The ENTIRE SDK floor is 1.1.1w (router/openssl, hostTools/openssl, targets/96813GW
fs.build all read `OpenSSL 1.1.1w`). There is **no openssl-3 source in the SDK**.
=> There is no version-bump knob; replacing the shared 1.1 lib means relinking every
   DT_NEEDED consumer — impossible for the closed set, and impossible for hostapd
   because the SDK's hostapd/libceshared only build against 1.1.

The only from-source openssl in OUR tree is `gt-be98-br-openssl` **3.6.2**, built
`no-shared -static`; its CLI is harvested to `/usr/br/bin/openssl` and dropbearmulti /
OpenSSH link it statically. Distinct island; never touches the blob 1.1.

---

## 2. v31 openssl-1.1 consumer scan (rc-FREE keep-set)

Scan method: `readelf -d` over every non-symlink ELF in the br-0050/v31 base-rootfs
reference, with the v31 `openrc-strip.list` applied virtually (globs + dir-prefixes),
plus a DT_NEEDED reverse-dependency reachability trace from the daemons the v31
OpenRC init actually launches. (scripts: job-tmp v31-openssl-scan / -reachability /
-live-trace.)

- Surviving keep-set ELF: **649**
- Surviving ELF linking libssl/libcrypto.so.1.1: **41** (was 72 with rc present)
- Stripped ELF linking 1.1: **116** (inert — removed by the strip list)

### 2a. LIVE (actually launched in v31) 1.1 consumers — the ONLY ones that matter

The v31 open-init launches: dropbearmulti (static openssl-3), acsd2 (no ssl), the wl
driver + Broadcom graft early-init (no ssl), the webui controller, and — via the
webui controller's `EnsureRadio` (gtbe98_wifi_extsup=1 + webui_radio_init=1) —
**hostapd**. DT_NEEDED closure of that launched set contains exactly one 1.1 chain:

| LIVE consumer | links | from-source? | relink to ssl-3? |
|---|---|---|---|
| **`usr/sbin/hostapd`** | libssl.so.1.1 + libcrypto.so.1.1 (DIRECT) + libceshared.so | YES, but **byte-identical ONLY vs SDK openssl-1.1** (TLS=openssl, DRIVER_BRCM, libceshared ABI) | **NO — irreducible.** SDK has no openssl-3; libceshared/hostapd source only build against 1.1. |

`wps_pbcd` (+ its `libcurl.so.4` pull) shows up in a naive closure, but **wps_pbcd is
NOT launched in v31** — it was an rc companion; the live wifi path is webui→EnsureRadio
→hostapd, no wps_pbcd. So libcurl/wps_pbcd are present-but-dormant (§2b), not live.

**=> The live, EOL-exposed openssl-1.1 attack surface in v31 = hostapd alone.**

### 2b. SURVIVING-but-NOT-LAUNCHED 1.1 consumers (present on disk, inert in v31)

The other 40 surviving 1.1 linkers are on-disk inside the blob but have no launcher in
the v31 open-init. Split by source nature:

CLOSED ASUS/Broadcom proprietary (cannot relink — no source):
  sbin/wps_pbcd, bin/bp3, usr/sbin/{dropbox_client,google_client,ftpclient,
  amas-utils-cli}, usr/bin/afppasswd, and libs libasc / libasd / libamas-utils /
  libovpn / liblightsql / libletsencrypt / libwpa_client / libmssl / libawsiot_ipc /
  libsmartsync_api. (libovpn was the rc/wps_pbcd keep-invariant; with rc gone it is an
  orphan-but-kept blob, no live referrer.)

UPSTREAM-OSS (rebuildable from source against openssl-3 IN PRINCIPLE, but all DEAD in
v31 — no launcher, would be a brand-new package + reverse-dep-validated strip slice,
out of scope and pointless since none runs):
  usr/sbin/{curl,wget,stubby,pppd,vsftpd}, usr/sbin/wpa_supplicant-2.7 +
  usr/sbin/wpa_cli-2.7, usr/sbin/{charon-cmd,swanctl,pki} (strongSWAN residue),
  usr/sbin/chilli_* (coova-chilli), usr/lib/libnetsnmp*.so.35 (net-snmp),
  usr/lib/netatalk/uams_*.so, usr/sbin/openssl (stock merlin CLI),
  usr/lib/libcurl.so.4.8.0.

These 40 are inert (no exec path). They are NOT worth a relink: the closed ones can't
be relinked, and the OSS ones aren't run — removing them would be a size/strip task,
not an openssl-security task. They are left untouched here (conservative; a fresh
reverse-dep strip slice is a separate effort).

---

## 3. Achievable migration — is full coexistence-with-relink feasible?

Question: ship `libssl.so.3` + `libcrypto.so.3` side-by-side (distinct soname, no
clash with the 1.1 the blob needs) and relink the from-source-able (b) set against it,
keeping 1.1 ONLY for the irreducible (a) set?

- **Side-by-side soname is trivially safe**: openssl-3 sonames are `.so.3`, openssl-1.1
  are `.so.1.1` — they coexist on disk and in the loader with zero collision. The
  Broadcom wl-graft datapath (`wl`, `wlceventd`, `acsd2`, `dhd`) links **zero**
  openssl, so an added openssl-3 poses no ABI risk to the datapath.
- **But there is no consumer to relink onto it.** The only LIVE from-source openssl
  daemon is hostapd, and hostapd CANNOT move to openssl-3 (SDK pin, §2a). The /usr/br
  SSH surface already has openssl-3, **statically** — it does not want a shared
  `.so.3`. Every other 1.1 linker is either closed (un-relinkable) or a dead OSS
  binary that isn't launched. So adding a shared `BR2_PACKAGE_LIBOPENSSL` (3.x) today
  would ship an **unused** lib (~3-5 MB) against the NAND headroom — net negative.
- **Dropping the 1.1 libs is NOT possible**: hostapd DT_NEEDEDs them directly and is
  live. Their removal is gated on a future hostapd that builds against openssl-3,
  which requires a **newer Broadcom SDK** (impl103 / 5.04behnd.4916 is 1.1.1w-only).

**=> Full coexistence-with-relink is FEASIBLE in mechanism but has NO beneficiary on
v31. The realistic ceiling is the existing split: openssl-3.6.2 (static) for the open
/usr/br surface + openssl-1.1.1w retained for hostapd (+ dormant blobs).**

### What WOULD move the needle (all out of reach on this SDK)
1. A Broadcom SDK that offers `TLS=openssl3` for hostapd + a libceshared built against
   3.x. Not present in 5.04behnd.4916. This is the ONLY path that closes the live gap.
2. A from-source open hostapd with a non-Broadcom driver backend (nl80211 generic)
   that we could build against openssl-3 — but that abandons the libceshared/DRIVER_BRCM
   byte-identity that makes the wifi authenticator trustworthy on this chipset; high
   risk, not "low-risk", explicitly out of scope for this task.

---

## 4. Changes landed on this branch (low-risk only)

**None to binaries / defconfig / packages.** After the rc-free re-scan, there is no
clean low-risk openssl-3 relink available:

- The open SSH/SFTP surface is **already** on openssl-3.6.2 (static, `gt-be98-br-openssl`)
  — nothing to do.
- hostapd is SDK-pinned to 1.1 — must not touch (security-critical, byte-identity).
- Adding a shared openssl-3 now ships an unused lib — deferred until a consumer exists.
- The 40 dormant 1.1 blobs are inert; relinking the OSS subset is a separate
  strip/reverse-dep effort, not an openssl-security win (none of them run).

The only artifact added is this re-scoped document.

### Staging note (for a FUTURE from-source openssl-3 daemon, NOT done here)
    # in a from-source open-daemon defconfig (NOT the openrc-init base):
    #   BR2_PACKAGE_LIBOPENSSL=y         # installs libssl.so.3 / libcrypto.so.3
    # then build that daemon with -lssl/-lcrypto (soname .3; no clash with blob 1.1).
    # Today there is no such daemon, so this stays unstaged.

---

## 5. Residual EOL-1.1 exposure — plain statement

- **LIVE exposure**: `hostapd` (WPA/WPA2/WPA3-SAE authenticator) runs against
  **OpenSSL 1.1.1w (EOL Sep 2023)**. This is the real, running EOL-crypto surface.
- **Dormant exposure**: ~40 present-but-not-launched 1.1-linked blobs/OSS binaries; no
  exec path in v31, so not a running attack surface, but they are dead weight on disk.
- **Is it closable without a newer Broadcom SDK? NO.** The whole SDK floor is 1.1.1w;
  hostapd + libceshared only build against it; there is no openssl-3 in the SDK and no
  TLS=openssl3 option. The byte-identical from-source hostapd is the safest
  authenticator we can ship on this chipset and it is 1.1-bound. This is the SAME
  irreducible-vendor-floor situation as the pinned kernel 4.19.294 / glibc 2.32:
  **closing it requires Broadcom to ship a new SDK, which is outside this project's
  control.** Stated plainly so it is not re-litigated each session.

VERDICT (rc-free, v31): **coexistence; the rc removal eliminated rc as a 1.1 pin but
the LIVE EOL-1.1 surface is now hostapd alone, which is irreducibly SDK-pinned to
1.1.1w. openssl-3.6.2 already serves the open /usr/br SSH/SFTP surface (static). No
relink target exists, so no binary change is made. The residual EOL-1.1 exposure
(hostapd) is irreducible without a newer Broadcom SDK.**
