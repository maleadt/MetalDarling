# Build a Julia depot on the Linux host for running a Metal.jl checkout under Darling.
#
# Usage: julia scripts/make-depot.jl <depot> <Metal.jl checkout> [<macOS Julia version>]
#
# HTTPS from Julia crashes under Darling, so everything is downloaded here and the container
# runs with JULIA_PKG_OFFLINE=true. The checkout's environment is resolved (writing its
# Manifest.toml if it has none) and instantiated into <depot>, and then every artifact of every
# dependency, lazy ones included, is also installed for x86_64 macOS. Nothing is precompiled:
# caches made by the Linux Julia are useless to the macOS one.
#
# In a workspace, the dependencies of its subprojects (e.g. test/) are included.
#
# Run it with the same Julia version as the macOS Julia in the image (default: that of the
# running Julia), so that the manifest resolves the same way.

using Pkg, TOML, Base.BinaryPlatforms

if !(2 <= length(ARGS) <= 3)
    println(stderr, "usage: julia scripts/make-depot.jl <depot> <Metal.jl checkout> [<macOS Julia version>]")
    exit(2)
end
depot = abspath(ARGS[1])
project = abspath(ARGS[2])
mac_julia = length(ARGS) == 3 ? VersionNumber(ARGS[3]) : VERSION
if VersionNumber(VERSION.major, VERSION.minor, VERSION.patch) != mac_julia
    @warn "Host Julia $VERSION differs from the macOS Julia $mac_julia; the manifest may not load there"
end
isfile(joinpath(project, "Project.toml")) || error("$project has no Project.toml")

mkpath(depot)
empty!(DEPOT_PATH)
push!(DEPOT_PATH, depot)
ENV["JULIA_PKG_PRECOMPILE_AUTO"] = "0"

isempty(Pkg.Registry.reachable_registries()) && Pkg.Registry.add("General")
Pkg.activate(project)
if !any(isfile, joinpath.(project, ["Manifest-v$(VERSION.major).$(VERSION.minor).toml", "Manifest.toml"]))
    Pkg.resolve()
end
Pkg.instantiate()

# Only the checkout and the depot are copied into the container, so a dependency tracked by
# path must be recorded relative to the manifest and resolve inside the checkout.
let manifest = Base.project_file_manifest_path(Base.active_project()), root = realpath(project)
    raw = TOML.parsefile(manifest)
    # format 2 has the packages under [deps]; format 1 has them at the top level
    pkgs = haskey(raw, "manifest_format") ? get(raw, "deps", Dict()) : raw
    for (name, entries) in pkgs, entry in (entries isa Vector ? entries : [entries])
        path = entry isa Dict ? get(entry, "path", nothing) : nothing
        path === nothing && continue
        isabspath(path) && error("$name is tracked by the absolute path $path in $manifest; it won't exist in the container")
        lexical = rstrip(normpath(joinpath(realpath(dirname(manifest)), path)), '/')
        target = realpath(lexical)
        # tar copies symlinks as they are, so a symlink on the way could point at the host
        target == lexical || error("$name's path $path goes through a symlink; copy it into the checkout instead")
        target == root || startswith(target, root * "/") ||
            error("$name is tracked by path at $target, outside $root; it won't exist in the container")
    end
end

platform = Platform("x86_64", "macos"; julia_version=mac_julia)

# JLLs with platform augmentation (e.g. LLVMExtra_jll's `llvm_version` tag) select their
# artifact with extra tags computed by `.pkg/platform_augmentation.jl`. Pkg only does this for
# the host platform, so apply the hook to the macOS platform here. The hooks look at the
# running Julia (its LLVM version), which is why this must be the same Julia version.
function augmented_platform(pkg_source)
    hook = joinpath(pkg_source, ".pkg", "platform_augmentation.jl")
    isfile(hook) || return platform
    m = Module(:PlatformAugmentation)
    Base.include(m, hook)
    augment! = Base.invokelatest(getglobal, m, :augment_platform!)
    return Base.invokelatest(augment!, deepcopy(platform))
end

# A workspace (Julia 1.12+) shares one manifest between the checkout and its subprojects
# (test/, docs/, ...), but Pkg.instantiate() and Pkg.dependencies() only cover what the active
# project needs, so instantiate every project in the workspace and collect its dependencies.
function workspace_projects(dir)
    dirs = [dir]
    ws = get(TOML.parsefile(joinpath(dir, "Project.toml")), "workspace", Dict{String,Any}())
    for sub in get(ws, "projects", String[])
        isfile(joinpath(dir, sub, "Project.toml")) && append!(dirs, workspace_projects(joinpath(dir, sub)))
    end
    return dirs
end
deps = Dict{Base.UUID,Any}()
for dir in workspace_projects(project)
    Pkg.activate(dir; io=devnull)
    Pkg.instantiate()
    merge!(deps, Pkg.dependencies())
end
Pkg.activate(project; io=devnull)

n = 0
for (_, pkg) in deps
    pkg.source === nothing && continue
    for name in ("Artifacts.toml", "JuliaArtifacts.toml")
        f = joinpath(pkg.source, name)
        isfile(f) || continue
        p = augmented_platform(pkg.source)
        p == platform || println("$(pkg.name): artifacts for ", triplet(p))
        Pkg.Artifacts.ensure_all_artifacts_installed(f; platform=p, include_lazy=true)
        global n += 1
    end
end
# Stdlib JLLs (e.g. OpenBLAS_jll) ship their artifacts inside the Julia distribution, so the
# macOS Julia already has those.

# KernelAbstractions (0.10.8 at least) launches a kernel on its PoCL CPU back-end in its
# precompile workload, and under Darling that hangs forever (the precompile process waits on a
# socket with no CPU use). Disable the workload with a PrecompileTools preference. It lives in
# the depot's default environment, which is on the load path behind the active project, so
# the Metal.jl checkout stays untouched. Preferences only apply to packages that environment
# lists, hence the [deps] entry; nothing is installed for it.
no_workload = ["KernelAbstractions"]
envdir = joinpath(depot, "environments", "v$(mac_julia.major).$(mac_julia.minor)")
mkpath(envdir)
# merge into whatever is there already
readtoml(f) = isfile(f) ? TOML.parsefile(f) : Dict{String,Any}()
envproject = readtoml(joinpath(envdir, "Project.toml"))
envprefs = readtoml(joinpath(envdir, "LocalPreferences.toml"))
for (uuid, pkg) in deps
    pkg.name in no_workload || continue
    get!(envproject, "deps", Dict{String,Any}())[pkg.name] = string(uuid)
    get!(envprefs, pkg.name, Dict{String,Any}())["precompile_workload"] = false
end
open(io -> TOML.print(io, envproject; sorted=true), joinpath(envdir, "Project.toml"), "w")
open(io -> TOML.print(io, envprefs; sorted=true), joinpath(envdir, "LocalPreferences.toml"), "w")

println("depot: ", depot)
println("manifest: ", Base.project_file_manifest_path(Base.active_project()))
println("artifact files processed for $(triplet(platform)): ", n)
