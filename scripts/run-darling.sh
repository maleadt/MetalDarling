#!/usr/bin/env bash
# Run a Julia script against a Metal.jl checkout under Darling, in a runtime container.
#
# Usage: scripts/run-darling.sh [options] <script.jl> [script args...]
#
#   --image IMAGE      runtime image (default $MD_IMAGE), e.g.
#                      ghcr.io/maleadt/metaldarling@sha256:... or a local tag
#   --container NAME   runtime container (default metaldarling). Started from --image if
#                      it doesn't exist or isn't running, and reused otherwise.
#   --volume NAME      volume holding /root, i.e. the Darling prefix (/root/.darling) and the
#                      copied checkout and depot (/root/work) (default: <container>-home)
#   --recreate         remove the container first (the volume is kept), e.g. to switch images
#   --metal DIR        Metal.jl checkout to copy in (default $MD_METAL). Its working tree is
#                      copied without .git, replacing the previous copy. If neither is set,
#                      the copy already in the container is used.
#   --depot DIR        host depot from make-depot.jl (default $MD_DEPOT). Copied in when it
#                      changed since the last copy; precompile caches made inside the
#                      container are kept. If neither is set, the container's copy is used.
#   --gpu GPU          Vulkan driver to run on: nvidia (default), amd (RADV) or lavapipe.
#                      New containers get the NVIDIA GPU (`--gpus all`) when the host's
#                      NVIDIA Container Toolkit has a CDI spec, so one container serves all
#                      three. A container without it falls back to amd unless --gpu is given.
#                      An explicit VK_DRIVER_FILES in --env overrides the choice.
#   --env K=V          extra environment variable for Julia; repeatable
#   --timeout SECONDS  kill the run after this long (default 3600); then `darling shutdown`
#   --julia PATH       Julia inside Darling (default: $DARLING_JULIA from the image)
#
# Julia runs as `julia --threads=1 --project=<checkout> <script>` under `darling shell`, with
# JULIA_DEPOT_PATH=<depot>: (keeping the bundled stdlib depot) and JULIA_PKG_OFFLINE=true,
# because HTTPS from Julia crashes under Darling. The script (only that one file) is copied to
# /root/work/scripts. Inside Darling, the Linux /root/work is /Volumes/SystemRoot/root/work.
#
# Before running, print-hashes.sh checks that Darling loads the image's Metal libraries.
#
# Exit status: that of the script, 124 on timeout, or 1 if the hashes check fails. A timeout
# is recognized by `timeout`'s status together with the elapsed wall time, so a script that
# itself exits with 124 or 137 right at the deadline would be reported as timed out.
set -euo pipefail

here=$(cd "$(dirname "$0")" && pwd)
container=metaldarling volume= image=${MD_IMAGE:-}
recreate=0 metal=${MD_METAL:-} depot=${MD_DEPOT:-} timeout=3600 julia=
gpu=
envs=()

die() { echo "run-darling: $*" >&2; exit 1; }

while [ $# -gt 0 ]; do
    case $1 in
        --container) container=$2; shift 2 ;;
        --volume) volume=$2; shift 2 ;;
        --image) image=$2; shift 2 ;;
        --recreate) recreate=1; shift ;;
        --gpu) gpu=$2; shift 2 ;;
        --metal) metal=$2; shift 2 ;;
        --depot) depot=$2; shift 2 ;;
        --env) [[ $2 == *=* ]] || die "--env needs K=V"; envs+=("$2"); shift 2 ;;
        --timeout) timeout=$2; shift 2 ;;
        --julia) julia=$2; shift 2 ;;
        -h|--help) sed -n '2,/^set -e/p' "$0" | sed '$d; s/^# \{0,1\}//'; exit 0 ;;
        --) shift; break ;;
        -*) die "unknown option $1" ;;
        *) break ;;
    esac
done
[ $# -ge 1 ] || die "no script given (see --help)"
script=$(realpath "$1"); shift
[ -f "$script" ] || die "no such script: $script"
volume=${volume:-$container-home}
[ -n "$image" ] || die "no image given (--image or MD_IMAGE)"

work=/root/work                            # Linux side
dwork=/Volumes/SystemRoot/root/work        # the same, inside Darling

[[ $timeout =~ ^[1-9][0-9]*$ ]] || die "--timeout takes a positive number of seconds"
case ${gpu:-nvidia} in nvidia|amd|lavapipe) ;; *) die "--gpu takes nvidia, amd or lavapipe" ;; esac
host_has_nvidia() { nvidia-ctk cdi list 2>/dev/null | grep -q '^nvidia.com/gpu=all$'; }
container_has_nvidia() {
    [ "$(docker container inspect -f '{{len .HostConfig.DeviceRequests}}' "$1")" != 0 ]
}

# One run at a time per container and per volume: they share the checkout, depot and Darling
# prefix. flock(1) locks under $XDG_RUNTIME_DIR (or /tmp), held until this script exits.
lock() {
    local fd file=${XDG_RUNTIME_DIR:-/tmp}/metaldarling-$1.lock
    exec {fd}>"$file"
    flock -n $fd || die "$1 is in use by another run (lock $file)"
}
lock "container-$container"
lock "volume-$volume"
if docker container inspect "$container" >/dev/null 2>&1; then
    v=$(docker container inspect -f '{{range .Mounts}}{{if eq .Destination "/root"}}{{.Name}}{{end}}{{end}}' "$container")
    [ -z "$v" ] || [ "$v" = "$volume" ] || lock "volume-$v"
fi

if [ $recreate = 1 ]; then
    docker rm -f "$container" >/dev/null 2>&1 || true
fi
if docker container inspect "$container" >/dev/null 2>&1; then
    # reuse it only if it is what this script would have created
    image_id=$(docker image inspect -f '{{.Id}}' "$image") || die "no image $image; docker pull it first"
    [ "$(docker container inspect -f '{{.Image}}' "$container")" = "$image_id" ] ||
        die "container $container doesn't run the current $image; use --recreate"
    docker container inspect -f '{{range .Mounts}}{{.Type}} {{.Name}} {{.Destination}} {{.RW}}{{println}}{{end}}' "$container" |
        grep -Fxq "volume $volume /root true" || die "container $container doesn't have volume $volume at /root"
    [ "$(docker container inspect -f '{{.HostConfig.Privileged}} {{.HostConfig.Init}}' "$container")" = "true true" ] ||
        die "container $container isn't --privileged --init; use --recreate"
    [ "$(docker container inspect -f '{{.State.Running}}' "$container")" = true ] ||
        docker start "$container" >/dev/null
else
    docker volume create "$volume" >/dev/null
    # --init: without a reaping PID 1, darlingserver turns into a zombie.
    # The prefix must be on a volume: nested overlayfs fails on Docker's overlay root.
    gpus=(); host_has_nvidia && gpus=(--gpus all)
    docker run -d --name "$container" --init --privileged "${gpus[@]}" \
        -v "$volume:/root" "$image" sleep infinity >/dev/null
fi
if ! container_has_nvidia "$container"; then
    [ "$gpu" != nvidia ] || die "container $container has no NVIDIA GPU; use --recreate (or --gpu amd)"
    [ -n "$gpu" ] || echo "run-darling: container $container has no NVIDIA GPU; using amd" >&2
    gpu=${gpu:-amd}
fi
gpu=${gpu:-nvidia}
case $gpu in
    nvidia) icd=/etc/vulkan/icd.d/nvidia_icd.json ;;
    amd) icd=/usr/share/vulkan/icd.d/radeon_icd.json ;;
    lavapipe) icd=/usr/share/vulkan/icd.d/lvp_icd.json ;;
esac
[[ " ${envs[*]} " == *" VK_DRIVER_FILES="* ]] || envs=(VK_DRIVER_FILES=$icd "${envs[@]}")
dexec() { docker exec -i "$container" "$@"; }
dexec mkdir -p $work/scripts

if [ -n "$metal" ]; then
    [ -f "$metal/Project.toml" ] || die "$metal is not a Julia project"
    dexec rm -rf $work/Metal.jl
    dexec mkdir -p $work/Metal.jl
    tar -C "$metal" --exclude=.git -cf - . | dexec tar -xf - -C $work/Metal.jl
    rev=$(git -C "$metal" rev-parse --short HEAD 2>/dev/null || echo unknown)
    [ -n "$(git -C "$metal" status --porcelain --untracked-files=no 2>/dev/null)" ] && rev+="+dirty"
    echo "$(realpath "$metal") $rev" | dexec tee $work/Metal.jl.source >/dev/null
fi
dexec test -f $work/Metal.jl/Project.toml || die "no Metal.jl in $container; pass --metal or set MD_METAL"

if [ -n "$depot" ]; then
    [ -d "$depot/packages" ] || die "$depot doesn't look like a depot (run make-depot.jl)"
    stamp=$(cd "$depot" && find . -path ./compiled -prune -o -path ./logs -prune -o -printf '%P %s %T@\n' | sort | sha256sum | cut -d' ' -f1)
    if [ "$(dexec cat $work/depot.stamp 2>/dev/null)" != "$stamp" ]; then
        echo "run-darling: copying depot $depot into $container"
        # into a fresh directory, so files deleted on the host go away here too; the
        # precompile caches made in the container are carried over
        # finish or undo an interrupted swap first, keeping the active depot and its caches
        dexec bash -c "set -e; cd $work; rm -f depot.stamp
            if [ ! -d depot ] && [ -d depot.old ]; then mv depot.old depot; fi
            if [ -d depot.new/compiled ] && [ -d depot ] && [ ! -d depot/compiled ]; then mv depot.new/compiled depot/; fi
            rm -rf depot.new depot.old; mkdir depot.new"
        tar -C "$depot" --exclude=./compiled --exclude=./logs -cf - . | dexec tar -xf - -C $work/depot.new ||
            die "copying the depot failed"
        dexec bash -c "set -e; cd $work; rm -rf depot.old
            if [ -d depot ]; then mv depot depot.old; fi
            if [ -d depot.old/compiled ]; then mv depot.old/compiled depot.new/; fi
            mv depot.new depot && rm -rf depot.old" ||
            die "swapping in the new depot failed; the old one is in $work/depot.old"
        echo "$stamp" | dexec tee $work/depot.stamp >/dev/null
    fi
fi
dexec test -d $work/depot/packages || die "no depot in $container; pass --depot or set MD_DEPOT"

docker cp "$script" "$container:$work/scripts/" >/dev/null

"$here/print-hashes.sh" "$container" || exit 1
echo "Metal.jl: $(dexec cat $work/Metal.jl.source 2>/dev/null || echo unknown)"

julia=${julia:-$(docker exec "$container" printenv DARLING_JULIA)}
env_args=(JULIA_DEPOT_PATH=$dwork/depot: JULIA_PKG_OFFLINE=true "${envs[@]}")
echo "run-darling: ${envs[*]} julia --threads=1 $(basename "$script") $*"

start=$(date +%s)
set +e
docker exec "$container" timeout --kill-after=30 "$timeout" \
    darling shell env "${env_args[@]}" \
    "$julia" --threads=1 --project=$dwork/Metal.jl "$dwork/scripts/$(basename "$script")" "$@"
rc=$?
set -e
if { [ $rc = 124 ] || [ $rc = 137 ]; } && [ $(( $(date +%s) - start )) -ge "$timeout" ]; then
    echo "run-darling: timed out after ${timeout}s; shutting Darling down" >&2
    src=0; docker exec "$container" timeout 120 darling shutdown >/dev/null 2>&1 || src=$?
    [ $src != 124 ] || echo "run-darling: warning: 'darling shutdown' timed out" >&2
    rc=124
fi
exit $rc
