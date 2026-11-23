# MetalDarling

Builds [Darling](https://github.com/darlinghq/darling) with patches that make
[Metal.jl](https://github.com/JuliaGPU/Metal.jl) work on Linux, through Darling's Metal
implementation over Vulkan ([darling-metal](https://github.com/darlinghq/darling-metal) and
[Indium](https://github.com/darlinghq/indium)). The patches are pull requests on their way
upstream; this repository lets Metal.jl's CI and Linux developers use them before they land.

Each [release](https://github.com/maleadt/MetalDarling/releases) has:

- Darling's `.deb` packages for Ubuntu 26.04 (x86_64), built as Darling's own CI builds them;
- `darling-source.tar.xz`, the complete source they were built from, including this
  repository's recipe and `stack.lock` (the commits that went in);
- `runtime-libs.sha256`, the hashes of the Metal libraries Darling loads, and `SHA256SUMS`.

and a runtime image, `ghcr.io/maleadt/metaldarling`, tagged with the release's name: Ubuntu 26.04
with those packages, Mesa's Vulkan drivers (RADV, lavapipe) and the official macOS x86_64
Julia, unpacked where Darling sees it as `/opt/julia-<version>`. The release notes give the
image's digest; pin that, not the tag. `latest` follows the newest release. (GHCR makes a new
package private: its visibility has to be set to public once, in the package's settings on
GitHub, before anyone else can pull it. The smoke job warns until then.)

Darling is GPL-3.0; its components carry their own licences (see the source archive). The
image also redistributes Ubuntu's packages, listed with their versions in the release's
`image-packages.txt` (sources at <https://launchpad.net/ubuntu>), and Julia's macOS build
(sources at <https://github.com/JuliaLang/julia> under the matching tag, with the versions of
its bundled libraries in `deps/`).

## Running Metal.jl locally

You need Docker and an x86_64 Linux machine with an NVIDIA or AMD GPU (for
NVIDIA, the NVIDIA Container Toolkit with a CDI spec), or none at all for lavapipe, Mesa's CPU
driver. Containers run `--privileged --init` with Darling's prefix on a named volume:
Darling mounts an overlayfs, which doesn't work on Docker's own overlay root, and without an
init process its server becomes a zombie.

HTTPS from Julia crashes under Darling, so packages are installed on the host, into a depot
that is then copied in. Build it with the same Julia version as the image's:

```sh
# a Metal.jl checkout; until the patches it needs are merged, the one the smoke test uses:
python3 scripts/apply-stack.py metal ~/MetalDarling-Metal.jl
printf '[Metal]\nallow_unsupported_devices = true\n' > ~/MetalDarling-Metal.jl/LocalPreferences.toml

julia +1.13.4 scripts/make-depot.jl ~/MetalDarling-depot ~/MetalDarling-Metal.jl
```

Then run a script, e.g. the survey of 25 array operations:

```sh
export MD_IMAGE=ghcr.io/maleadt/metaldarling@sha256:...    # from a release
docker pull $MD_IMAGE
scripts/run-darling.sh --metal ~/MetalDarling-Metal.jl --depot ~/MetalDarling-depot \
    --gpu lavapipe scripts/survey.jl
```

`run-darling.sh` creates a container (`metaldarling`, with volume `metaldarling-home`) or reuses
it, copies in the checkout and the depot, checks that the Metal libraries Darling sees are the
image's (`print-hashes.sh`), and runs the script with
`julia --threads=1 --project=<checkout>` under `darling shell`. The first run precompiles
Metal.jl inside Darling, which takes a while. `--help` lists the options; `--gpu` picks
`nvidia`, `amd` or `lavapipe`.

| Script | |
|---|---|
| `apply-stack.py` | Checks out Darling (or Metal.jl) with the topics of `stack.toml` merged in |
| `debian-changelog.sh`, `source-tarball.sh`, `runtime-libs.sh` | Packaging steps of the workflow |
| `make-depot.jl` | Builds a depot on the host for a Metal.jl checkout, with the macOS artifacts |
| `run-darling.sh` | Runs a Julia script in a runtime container |
| `print-hashes.sh` | Checks the Metal libraries Darling loads against the image's list |
| `survey.jl` | 25 array operations, run in a worker process that is restarted after a crash, so a crash only loses its case |
| `load-metal.jl` | Loads Metal.jl and prints `Metal.versioninfo()` |
| `env-info.sh` | Kernel, image, package versions and `vulkaninfo --summary` of a container |

Known workarounds, all in these scripts: the offline depot (HTTPS), `--threads=1` (Julia
crashes at exit with an interactive thread), `--init` (zombie darlingserver),
`--force-overwrite` when installing the packages (two of them ship CoreData.framework), and
KernelAbstractions' precompile workload turned off in the depot (it hangs under Darling).

## Bumping the stack

`stack.toml` pins Darling's commit and, for each patched submodule, an upstream base commit and
the topic branches merged onto it, in order, by full commit SHA. To pick up new commits, change
the SHAs (`git ls-remote https://github.com/<fork> <branch>` gives a branch's head), and remove
a topic once upstream has merged it and the base has moved past it. Topics must merge cleanly;
check locally with

```sh
python3 scripts/apply-stack.py darling /tmp/darling    # writes /tmp/stack.lock
```

A push to `main` that changes anything but Markdown runs the workflow: it builds the packages
(from scratch, as long as Darling's own CI takes; with the previous run's ccache, mostly cached),
publishes them as a prerelease `v<date>-<commit>`, builds and pushes the image, runs the survey
on a hosted runner's lavapipe, and then promotes the release and adds the image digest and
survey score to its notes. The package version is
`0.1.<Darling commit date>~resolute-1+md<run number>`.

The pins make the source reproducible: `apply-stack.py` gives the same tree, and even the same
merge commits, every time. The build is traceable rather than reproducible: the release keeps
the source, the `.buildinfo` files (build dependencies) and the image's package list, but the
runner image and Ubuntu's packages move on.
