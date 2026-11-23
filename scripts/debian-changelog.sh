#!/usr/bin/env bash
# Write debian/changelog in a Darling tree, as Darling's tools/debian/make-deb does, but with
# the version derived from the pinned commit instead of today's date, and a downstream suffix:
#
#   0.1.<YYYYMMDD of the Darling commit, UTC>~<distro>-1+md<revision>
#
# so that these packages sort after upstream's build of the same commit and never share a
# version with it. <revision> must grow with every release (the workflow uses its run number).
#
# Usage: scripts/debian-changelog.sh <darling dir> <revision>
set -euo pipefail

dir=${1:?usage: debian-changelog.sh <darling dir> <revision>}
rev=${2:?usage: debian-changelog.sh <darling dir> <revision>}
[[ $rev =~ ^[0-9]+$ ]] || { echo "revision must be a number" >&2; exit 2; }

date=$(TZ=UTC git -C "$dir" show -s --date=format-local:%Y%m%d --format=%cd HEAD)
distro=${DEB_DISTRO:-}
[ -n "$distro" ] || distro=$(lsb_release -cs)
version=0.1.${date}~${distro}-1+md${rev}

cd "$dir"
rm -f debian/changelog
EDITOR=true NAME=MetalDarling EMAIL=metaldarling@invalid \
    dch -u low -v "$version" --create --distribution "$distro" --package darling \
    "Darling with the MetalDarling patch stack (stack.lock)" >&2
echo "$version"
