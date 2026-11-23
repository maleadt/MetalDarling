#!/usr/bin/env bash
# Print the sha256 of the Metal libraries Darling loads in a runtime container, and check them
# against the image's /etc/metaldarling/runtime-libs.sha256 (the hashes of the packaged files,
# also a release asset).
#
# Usage: scripts/print-hashes.sh <container>
#
# Each library is hashed on the Linux side (/usr/libexec/darling/...) and as seen from inside
# Darling (`darling shell shasum`). Darling's prefix is an overlay over /usr/libexec/darling:
# a copy in the prefix's upper layer shadows the image's file, and a file replaced in the
# image keeps being served until `darling shutdown`. Exits nonzero on any mismatch.
set -euo pipefail

container=${1:?usage: print-hashes.sh <container>}
list=/etc/metaldarling/runtime-libs.sha256
expected=$(docker exec "$container" cat $list) || { echo "!!! no $list in $container" >&2; exit 1; }

paths=() dpaths=()
while read -r _ p; do paths+=("$p"); dpaths+=("${p#/usr/libexec/darling}"); done <<< "$expected"
linux=$(docker exec "$container" sha256sum "${paths[@]}")
darling=$(docker exec "$container" darling shell shasum -a 256 "${dpaths[@]}" | tr -d '\r')

status=0
echo "darling libraries in $container:"
while read -r e p; do
    dp=${p#/usr/libexec/darling}
    l=$(awk -v p="$p" '$2 == p {print $1}' <<< "$linux")
    d=$(awk -v p="$dp" '$2 == p {print $1}' <<< "$darling")
    printf '  %s  %s\n' "${d:-MISSING}" "$dp"
    if [ "$l" != "$e" ]; then
        echo "!!! $p is ${l:-missing} on the Linux side, the image's list says $e" >&2; status=1
    fi
    if [ "$d" != "$e" ]; then
        echo "!!! $dp is ${d:-missing} inside Darling, the image's list says $e" >&2
        echo "!!! (run 'darling shutdown' and check the prefix's upper layer)" >&2; status=1
    fi
done <<< "$expected"
[ $status != 0 ] || echo "  (match $list)"
exit $status
