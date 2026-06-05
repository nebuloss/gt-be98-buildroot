#!/bin/bash
# GT-BE98 rootfs mutation proof: diff two squashfs images and print exactly
# what changed (listing-level + per-file content hashes). Used to verify a
# mutated rootfs.squashfs contains ONLY the intended changes vs the blob.
#
# Usage: rootfs-diff.sh <old.squashfs> <new.squashfs> [unsquashfs-binary]
set -eu

OLD=${1:?usage: rootfs-diff.sh <old.squashfs> <new.squashfs> [unsquashfs]}
NEW=${2:?usage: rootfs-diff.sh <old.squashfs> <new.squashfs> [unsquashfs]}
UNSQ=${3:-unsquashfs}
command -v "$UNSQ" >/dev/null || { echo "FATAL: $UNSQ not found (pass Buildroot's host unsquashfs)"; exit 1; }

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

# 1. listing diff (mode/uid/size/path; mtimes are expected to differ -> drop)
"$UNSQ" -lln "$OLD" 2>/dev/null | awk '{$4=""; $5=""; print}' | sort > "$W/old.lst"
"$UNSQ" -lln "$NEW" 2>/dev/null | awk '{$4=""; $5=""; print}' | sort > "$W/new.lst"
echo "=== listing diff (mode uid/gid size path; < old, > new) ==="
diff "$W/old.lst" "$W/new.lst" | grep '^[<>]' || echo "(no listing-level differences)"

# 2. content diff for files present in both: extract and hash
"$UNSQ" -q -d "$W/old" "$OLD" >/dev/null 2>&1
"$UNSQ" -q -d "$W/new" "$NEW" >/dev/null 2>&1
( cd "$W/old" && find . -type f -print0 | xargs -0 sha256sum | sort -k2 ) > "$W/old.sha"
( cd "$W/new" && find . -type f -print0 | xargs -0 sha256sum | sort -k2 ) > "$W/new.sha"
echo
echo "=== content changes (files whose sha256 differs or only in one image) ==="
join -j 2 -o 1.2,1.1,2.1 "$W/old.sha" "$W/new.sha" | awk '$2!=$3{print "CHANGED " $1}'
comm -13 <(awk '{print $2}' "$W/old.sha") <(awk '{print $2}' "$W/new.sha") | sed 's/^/ADDED   /'
comm -23 <(awk '{print $2}' "$W/old.sha") <(awk '{print $2}' "$W/new.sha") | sed 's/^/REMOVED /'
echo
echo "=== summary ==="
echo "old: $(wc -l < "$W/old.sha") files, $(du -h "$OLD" | cut -f1)"
echo "new: $(wc -l < "$W/new.sha") files, $(du -h "$NEW" | cut -f1)"
