#!/bin/bash
# Phase-3 inversion Step-0 — assemble the INVERTED rootfs (build-only, no flash).
#
# Composes: Buildroot skeleton (structural rewrite, plan §3) + Buildroot busybox
# (the inverted/open half, from the O= build's target dir) + the ASUS graft set
# (manifest, extracted byte-for-byte from the validated 0031 blob). Re-squashes
# with merlin-exact options. NO device, NO flash, NO network.
#
# Usage:
#   step0-assemble.sh <blob-root> <br-target-dir> <manifest> <out-dir>
#     <blob-root>      unpacked validated 0031 rootfs (graft source of truth)
#     <br-target-dir>  Buildroot O=.../target (source of /bin/busybox + applets)
#     <manifest>       docs/device/plans/phase3-graft-manifest.txt
#     <out-dir>        work/output dir; writes $out/root (tree) + $out/inverted-rootfs.squashfs
set -euo pipefail

BLOB="${1:?blob-root}"; BRT="${2:?br-target-dir}"; MAN="${3:?manifest}"; OUT="${4:?out-dir}"
MKSQ="${MKSQ:-/home/guillaume/be98/buildroot/output/host/bin/mksquashfs}"

[ -d "$BLOB" ] || { echo "FATAL: blob root $BLOB missing"; exit 1; }
[ -f "$MAN" ]  || { echo "FATAL: manifest $MAN missing"; exit 1; }
[ -x "$MKSQ" ] || { echo "FATAL: mksquashfs $MKSQ missing"; exit 1; }

ROOT="$OUT/root"
rm -rf "$ROOT"; mkdir -p "$ROOT"
miss="$OUT/missing.txt"; shamis="$OUT/sha-mismatch.txt"
: > "$miss"; : > "$shamis"

echo "== Layer 1: structural skeleton (plan §3) =="
# Top-level symlinks
declare -A LN=( [etc]=tmp/etc [home]=tmp/home [mnt]=tmp/mnt [opt]=tmp/opt \
                [root]=tmp/home/root [debug]=sys/kernel/debug )
for l in "${!LN[@]}"; do ln -s "${LN[$l]}" "$ROOT/$l"; done
# Stub dirs (mount points + runtime roots, all empty in image) — plan §3.2
for d in data jffs jffs/awscerts mmc cifs1 cifs2 sysroot bootfs dev dev/misc \
         proc sys tmp tmp/etc tmp/mnt var var/var; do
    mkdir -p "$ROOT/$d"
done

echo "== Layer 2: ASUS graft (manifest) =="
n_seed=0; n_clo=0; n_link=0; n_struct=0; n_tree=0
# Parse manifest: <kind> <bytes> <sha> <path> [-> target]
while read -r kind bytes sha path arrow target; do
    case "$kind" in
      seed:*|closure|struct)
        rel="${path#/}"; src="$BLOB/$rel"
        if [ ! -e "$src" ]; then echo "$path" >> "$miss"; continue; fi
        mkdir -p "$ROOT/$(dirname "$rel")"
        cp -a "$src" "$ROOT/$rel"
        if [ "$sha" != "-" ] && [ "$sha" != "?" ]; then
            got=$(sha256sum "$ROOT/$rel" | cut -d' ' -f1)
            [ "$got" = "$sha" ] || echo "$path want=$sha got=$got" >> "$shamis"
        fi
        case "$kind" in seed:*) n_seed=$((n_seed+1));; closure) n_clo=$((n_clo+1));; struct) n_struct=$((n_struct+1));; esac
        ;;
      link|link:rc)
        # format: link <0> <-> <path> -> <target>
        rel="${path#/}"; mkdir -p "$ROOT/$(dirname "$rel")"
        ln -sf "$target" "$ROOT/$rel"; n_link=$((n_link+1))
        ;;
      tree)
        # bytes col holds "(whole" — real path is the LAST field; re-extract
        t=$(echo "$kind $bytes $sha $path $arrow $target" | awk '{print $NF}')
        trel="${t#/}"
        if [ -d "$BLOB/$trel" ]; then
            mkdir -p "$ROOT/$(dirname "$trel")"
            cp -a "$BLOB/$trel" "$ROOT/$(dirname "$trel")/"
            n_tree=$((n_tree+1))
        else echo "$t (tree)" >> "$miss"; fi
        ;;
    esac
done < <(grep -vE '^\s*#|^\s*$|^dlopen' "$MAN")

echo "  seeds=$n_seed closure=$n_clo struct=$n_struct links=$n_link trees=$n_tree"

echo "== Layer 2.5: Phase-2 overlay /rom rails (plan §3.4: S26/S27/S28 carry over verbatim) =="
OVL="${OVL:-/home/guillaume/be98/gt-be98-buildroot/board/gt-be98/rootfs-overlay-full}"
if [ -d "$OVL/rom" ]; then
    cp -a "$OVL/rom/." "$ROOT/rom/"
    echo "  applied overlay /rom ($(find "$OVL/rom" -type f | wc -l) files)"
fi
# Build-identity marker (baseline writes one too; content differs by design).
mkdir -p "$ROOT/rom/etc"
cat > "$ROOT/rom/etc/gt-be98-release" <<EOF
release=phase3-step0-inverted
model=buildroot-skeleton+busybox+asus-graft
rootfs_blob=0031
build_date=$(date -u '+%Y-%m-%dT%H:%M:%SZ')
EOF

echo "== Layer 3: Buildroot busybox (inverted/open half) =="
[ -x "$BRT/bin/busybox" ] || { echo "FATAL: $BRT/bin/busybox not found"; exit 1; }
cp -a "$BRT/bin/busybox" "$ROOT/bin/busybox"
# Install Buildroot busybox applet symlinks, but NEVER overwrite a graft path
# (ASUS binary/symlink wins). Record what we add as EXPECTED-NEW.
newlinks="$OUT/busybox-applets.txt"; : > "$newlinks"
while IFS= read -r lpath; do
    rel="${lpath#"$BRT"/}"
    [ -e "$ROOT/$rel" ] || [ -L "$ROOT/$rel" ] && continue
    tgt=$(readlink "$lpath")
    mkdir -p "$ROOT/$(dirname "$rel")"
    ln -sf "$tgt" "$ROOT/$rel"
    echo "/$rel -> $tgt" >> "$newlinks"
done < <(find "$BRT" -type l -lname '*busybox*')
echo "  busybox applets added (non-colliding): $(wc -l < "$newlinks")"

echo "== Re-squash (merlin-exact: squashfs4.0/xz/128K/-all-root) =="
SQ="$OUT/inverted-rootfs.squashfs"
rm -f "$SQ"
"$MKSQ" "$ROOT" "$SQ" -noappend -all-root -comp xz -b 131072 -no-progress >/dev/null
echo "  wrote $SQ ($(du -h "$SQ" | cut -f1))"
echo "  sha256 $(sha256sum "$SQ" | cut -d' ' -f1)"

echo "== Assembly summary =="
echo "  missing manifest paths : $(wc -l < "$miss")  ($miss)"
echo "  sha mismatches         : $(wc -l < "$shamis")  ($shamis)"
[ -s "$miss" ] && { echo "  --- MISSING ---"; cat "$miss"; }
[ -s "$shamis" ] && { echo "  --- SHA MISMATCH ---"; cat "$shamis"; }
exit 0
