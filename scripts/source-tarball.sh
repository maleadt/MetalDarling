#!/usr/bin/env bash
# Archive the exact source a build used: the Darling tree as apply-stack.py left it (with
# debian/changelog written, without .git), plus this repository's recipe and the stack.lock
# that records the resolved commits. The archive holds darling/ and metaldarling/.
#
# Usage: scripts/source-tarball.sh <darling dir> <stack.lock> <out.tar.xz>
set -euo pipefail

dir=$(realpath "${1:?usage: source-tarball.sh <darling dir> <stack.lock> <out.tar.xz>}")
lock=$(realpath "${2:?}")
out=$(realpath -m "${3:?}")
here=$(cd "$(dirname "$0")/.." && pwd)

recipe=$(mktemp -d)
trap 'rm -rf "$recipe"' EXIT
mkdir "$recipe/metaldarling"
git -C "$here" archive HEAD | tar -x -C "$recipe/metaldarling"
cp "$lock" "$recipe/metaldarling/stack.lock"

mtime=@$(git -C "$dir" show -s --format=%ct HEAD)
tar --create --sort=name --owner=0 --group=0 --numeric-owner --mtime="$mtime" \
    --exclude=.git --exclude=.gitmodules --exclude=.gitignore \
    --file=- \
    -C "$(dirname "$dir")" --transform="s|^$(basename "$dir")\(/\|\$\)|darling\1|" "$(basename "$dir")" \
    -C "$recipe" metaldarling |
    xz -T0 -9 > "$out"
ls -l "$out"
