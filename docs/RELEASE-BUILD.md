# Building a release image of the GT-BE98 mainline OS

A lab build (`board/gt-be98-mainline/build.sh` with the lab `local.conf`) puts
lab material into every image. Measured with `release-check.sh` on a lab
image of 2026-11-02:

- the lab `ROOTFS_URL` (lab HTTP server address) in the rescue initramfs
  (`rescue/ml-defaults`) and in `ml-bootfs.info`;
- the lab SSH host keys, private and public (`SSH_HOSTKEY_DIR` -> `/etc/ssh`);
- the web UI password hash and salt (`/etc/webui/auth.conf`);
- the lab authorized key with its comment (`user@host`);
- the build host's identity: `user@host` in the kernel banner and in `lsof`
  (also `uname -a` of the build host), and `/home/<user>/` build paths in
  `lsof`, `procan`, `perf`/`trace`, `gawkbug`, libstdc++'s `gdb.py` and the
  two external driver modules (`__FILE__` of kernel headers).

A release image carries none of these. `RELEASE=1` makes the build refuse
them, and `release-check.sh` checks the result.

## Distribution: privately, never published

The image contains proprietary Broadcom/ASUS vendor firmware (Runner
microcode, PHY firmware, the Wi-Fi dongle firmware and NVRAM) copied from the
build host's local directories. Its licence does not allow redistribution.
**Never publish a release image or a flash kit** (no public URL, no public
repository, no release attachment). Hand it over privately, to one recipient
at a time. A release image also carries the recipient's SSH public keys,
which is one more reason to build per recipient. See also
`board/gt-be98-mainline/README.md`, "Licences", and `docs/FLASHING.md`.

## Build

Once on the build host, as root: a build directory whose path names no
person (absolute build paths end up in binaries, see above):

```sh
install -d -o <build user> /srv/gt-be98-release
```

Then:

```sh
cp board/gt-be98-mainline/release.conf.example ~/.config/gt-be98-os/release.conf
$EDITOR ~/.config/gt-be98-os/release.conf   # BR2_SRC, STOCK_BOOTFS, FW_*_DIR, WEBUI_DIR,
                                            # the RECIPIENT's SSH_AUTHORIZED_KEYS
GT_BE98_LOCAL_CONF=~/.config/gt-be98-os/release.conf \
    sh board/gt-be98-mainline/build.sh --print-config   # dry run: checks + fragment
GT_BE98_LOCAL_CONF=~/.config/gt-be98-os/release.conf \
    rtk sh board/gt-be98-mainline/build.sh              # full build, ~1 h, ~15 GB
```

`RELEASE=1` comes from the configuration file (the template sets it) or from
the environment (`RELEASE=1 ... build.sh`); the environment can turn it on,
never off. Keep the release `OUT` separate from the lab one: the lab output
directory's target tree has held the lab files.

`build.sh` with `RELEASE=1` stops before Buildroot runs when any of these
keys is set, or when `OUT` is under `/home` or contains the user name:

| key | lab use | in a release |
|---|---|---|
| `SSH_HOSTKEY_DIR` | the box keeps the lab host keys across rebuilds | must be empty: keys are made on the box (below) |
| `WEBUI_PASSWORD`, `WEBUI_PASSWORD_HASH` | the hash baked into `/etc/webui/auth.conf` | must be empty: first-login setup token (below) |
| `ROOTFS_URL` | HTTP rootfs fallback in the initramfs | must be empty (see "What a release loses") |
| `SYSLOG_REMOTE`, `NETCONSOLE`, `RNR0_FALLBACK`, `USB_FALLBACK` | lab log hosts and static lab addresses | must be empty; the owner can set them on the box (`/etc/conf.d/gt-be98-netconsole`, ...) |
| `SSH_AUTHORIZED_KEYS` | the lab keys | the recipient's public keys; only `type base64` is kept (comment and options dropped) |

The same refusals run again inside the build (`apply-local-conf.sh`,
`post-image.sh`). In release mode the build also sets
`KBUILD_BUILD_USER=gt-be98 KBUILD_BUILD_HOST=release` for the kernel and
`LSOF_HOST/LSOF_LOGNAME/LSOF_SYSINFO/LSOF_USER=none` for lsof, writes
`release-mode yes` into `/etc/gt-be98-release` and `release mode: yes` into
`ml-bootfs.info`.

## Check before handing it over

```sh
sh board/gt-be98-mainline/release-check.sh --selftest      # the checker itself
sh board/gt-be98-mainline/release-check.sh -f ~/.config/gt-be98-os/lab-patterns \
    /srv/gt-be98-release/out/images
```

Exit 0 and `release-check: PASS`, or no hand-over. The built-in checks need
no input (host keys, private keys, password hashes, remote log/netconsole/
static fallback, key comments, the release marker, `ROOTFS_URL`, `/home/<x>/`
paths). The lab values are given **at run time only**, in a file that is
never committed (one per line: `ip:ADDR` whole IPv4 address, `fixed:STRING`,
`user:NAME`, `re:ERE`; `#` comments): the lab addresses of the lab harness,
the lab `ROOTFS_URL` and its host, the build user name and host names, the
lab authorized and host public key bodies, the lab web UI salt and hash.
Without `-v` a finding names the pattern by number and file line, never by
value, so the output can be quoted. A broad range (`re:` over a private
/16) also hits the legitimate private-range lists of `gt-be98-router` and
`gt-be98-wifi-gen`: use exact addresses for the pass/fail decision.

The kernel Image's built-in initramfs is xz-compressed, so the checker reads
its sources (`rescue/`, `ml-defaults`) and the uncompressed `Image`, not the
initramfs bytes; it finds only the lab values it is given.

## First boot of a release image

**SSH host keys** - `gt-be98-hostkeys` (boot runlevel, after `gt-be98-jffs`,
before `sshd`): when `/etc/ssh` has no host keys (first boot), it runs
`ssh-keygen -A` on the box and saves them at once to
`/jffs/mainline-os/state.tgz` (`gt-be98-save --local`, through the UBI write
fence). Later boots restore them (`gt-be98-jffs`), so the fingerprint stays.
With `/jffs` not writable (`NAND=off`/`ro`, or the fenced setup failed) the
keys live in RAM and the next boot makes new ones (warning in the log and in
`/etc/motd`). Keys never leave the box.

**Web UI** - needs a webui-go build with the first-login setup token
(`webui -features` prints `setup-token`; branch `wu-first-login-2026-11-02`).
It is enabled without a password; until one is set it accepts nothing but
`set_password` with the one-time token it writes, root-only, to
`/run/webui/setup-token` (tmpfs, regenerated at every start while no
password is set, deleted once one is). Read it as root:
`ssh root@<box> cat /run/webui/setup-token` (recipient key), or on the USB
lifeline. Exposed before the password is set: the static UI files, and the
API actions `auth_status` (configured/authed flags), `login`/`logout`
(no-ops) and `set_password` (refused without the token); the loopback-only
notifiers answer loopback only, as always. Everything else, `/events` and the
`/ws/console` shell included, answers "authentication required". An older
webui without the token is refused by `gt-be98-webui-guard` (it would be open
to the LAN), so the web UI then does not start.

**No SSH key** - with `SSH_AUTHORIZED_KEYS` empty, `TELNET_LIFELINE=auto`
enables the passwordless root telnet on the USB NIC (`gt-be98-telnet`):
physical access to the USB lifeline is root.

## What a release loses

- `ROOTFS_URL`: no HTTP rootfs fallback. The rescue `/init` boots a
  `GTBE98-ROOT` USB partition, else slot 1's UBI volume 4 (`NAND != off`, the
  flash procedure of `docs/FLASHING.md` writes it). If neither holds a valid
  rootfs, the boot ends in the rescue lifeline (post-code `e9`/`eb`, or `e0`;
  `package/gt-be98-os/src/rescue/init`) and the watchdog then resets the box
  into stock. The rescue lifeline (passwordless root telnet on the USB NIC,
  bounded watchdog petting) is in every image, release included.
- Remote syslog and netconsole: off until the owner configures them on the box.
- A stable lab SSH identity: each box has its own host keys.
