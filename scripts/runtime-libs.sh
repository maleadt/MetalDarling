#!/usr/bin/env bash
# Print the sha256 of the Metal libraries Darling loads, as packaged in a directory of .debs,
# in sha256sum format with the paths they install to. The image keeps this list in
# /etc/metaldarling/runtime-libs.sha256 and print-hashes.sh checks against it.
#
# Usage: scripts/runtime-libs.sh <debs dir>
#
# Prints nothing and fails unless each file is in exactly one package.
set -euo pipefail

debs=${1:?usage: runtime-libs.sh <debs dir>}
files=(
    /usr/libexec/darling/usr/lib/darling/libiridium.dylib
    /usr/libexec/darling/usr/lib/darling/libindium.dylib
    /usr/libexec/darling/System/Library/Frameworks/Metal.framework/Versions/A/Metal
)
out=
for f in "${files[@]}"; do
    found=0
    for deb in "$debs"/*.deb; do
        if dpkg-deb -c "$deb" | awk '{print $6}' | grep -xF ".$f" >/dev/null; then   # not -q: with pipefail, an early exit fails dpkg-deb
            [ $found = 0 ] || { echo "$f is in more than one package" >&2; exit 1; }
            sha=$(dpkg-deb --fsys-tarfile "$deb" | tar -xO ".$f" | sha256sum)
            out+="${sha%% *}  $f"$'\n'
            found=1
        fi
    done
    [ $found = 1 ] || { echo "$f is in no package" >&2; exit 1; }
done
printf %s "$out"
