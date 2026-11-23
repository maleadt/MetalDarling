# Survey of 25 basic Metal.jl array operations, robust against crashing cases.
#
# Usage: julia --project=<Metal.jl> survey.jl [--case-timeout S] [--load-timeout S]
#                                             [--logdir DIR] [--only NAME,NAME...]
#
# The driver (this script without --worker) loads nothing itself. It runs the cases in a
# worker process (the same Julia, project and environment, --threads=1), which reports each
# case to a progress file. If the worker dies (an ACO abort, an uncaught Objective-C
# exception) or a case runs past --case-timeout, that case is reported as CRASH or TIMEOUT and
# a fresh worker resumes with the next case. Worker output goes to --logdir (default: a new
# directory under the system temp dir); the tail of a crashed worker's log goes to stderr.
#
# Prints one `<name> <STATUS>` line per case, with STATUS one of PASS, WRONG, ERROR <message>,
# CRASH <how>, TIMEOUT, and finally `survey: <passes>/<cases>`.

const CASES = [
    "fill!"          => :(Array(fill!(MtlArray{Float32}(undef, 1000), 3f0)) == fill(3f0, 1000)),
    "copyto! d2d"    => :(x = rand(Float32, 1000); a = MtlArray(x); b = similar(a); copyto!(b, a); Array(b) == x),
    "broadcast +"    => :(x = rand(Float32, 1000); Array(MtlArray(x) .+ 1f0) ≈ x .+ 1),
    "broadcast 2arg" => :(x = rand(Float32, 1000); y = rand(Float32, 1000); Array(MtlArray(x) .* MtlArray(y)) ≈ x .* y),
    "broadcast 2d"   => :(x = rand(Float32, 30, 40); Array(MtlArray(x) .+ MtlArray(x[:, 1])) ≈ x .+ x[:, 1]),
    "map sin"        => :(x = rand(Float32, 1000); Array(map(sin, MtlArray(x))) ≈ sin.(x)),
    "sum"            => :(x = rand(Float32, 10000); sum(MtlArray(x)) ≈ sum(x)),
    "sum dims"       => :(x = rand(Float32, 100, 50); Array(sum(MtlArray(x); dims=1)) ≈ sum(x; dims=1)),
    "maximum"        => :(x = rand(Float32, 10000); maximum(MtlArray(x)) == maximum(x)),
    "mapreduce Int"  => :(x = rand(1:100, 5000); mapreduce(abs2, +, MtlArray(Int32.(x))) == mapreduce(abs2, +, Int32.(x))),
    "any/all"        => :(x = rand(Bool, 1000); any(MtlArray(x)) == any(x) && all(MtlArray(x)) == all(x)),
    "accumulate"     => :(x = rand(Float32, 1000); Array(accumulate(+, MtlArray(x))) ≈ accumulate(+, x)),
    "cumsum native"  => :(x = rand(Float32, 1000); Array(cumsum(MtlArray(x))) ≈ cumsum(x)),
    "sort"           => :(x = rand(Float32, 1000); Array(sort(MtlArray(x))) == sort(x)),
    "rand"           => :(a = Metal.rand(Float32, 1000); all(0 .<= Array(a) .< 1)),
    "randn"          => :(a = Array(Metal.randn(Float32, 10000)); m = sum(a) / 10000;
                          abs(m) < 0.1 && 0.8 < sum(abs2, a .- m) / 9999 < 1.2),
    "matmul native"  => :(A = rand(Float32, 64, 64); B = rand(Float32, 64, 64); C = MtlArray(zeros(Float32, 64, 64));
                          mul!(C, MtlArray(A), MtlArray(B)); Array(C) ≈ A * B),
    "transpose"      => :(x = rand(Float32, 33, 65); Array(permutedims(MtlArray(x), (2, 1))) == permutedims(x, (2, 1))),
    "getindex vec"   => :(x = rand(Float32, 1000); i = rand(1:1000, 100); Array(MtlArray(x)[MtlArray(i)]) == x[i]),
    "findall"        => :(x = rand(Bool, 1000); Array(findall(MtlArray(x))) == findall(x)),
    "Float16 bcast"  => :(x = rand(Float16, 1000); Array(MtlArray(x) .* Float16(2)) == x .* Float16(2)),
    "Int64 bcast"    => :(x = rand(Int64, 1000); Array(MtlArray(x) .÷ 7) == x .÷ 7),
    "complex"        => :(x = rand(ComplexF32, 1000); Array(MtlArray(x) .* MtlArray(x)) ≈ x .* x),
    "bounds error"   => :(try
                              a = MtlArray(zeros(Float32, 4))
                              @metal threads=8 ((a) -> (a[thread_position_in_grid().x] = 1f0; nothing))(a)
                              synchronize()
                              false
                          catch e
                              # anything but the kernel's exception is an ERROR, not a WRONG
                              e isa Metal.KernelException || rethrow()
                              e.name == "BoundsError"
                          end),
    "atomic add"     => :(a = MtlArray([0f0]);
                          @metal threads=256 groups=4 ((a) -> (Metal.@atomic a[1] += 1f0; nothing))(a);
                          Array(a)[1] == 1024),
]

# Progress file protocol, one event per line: `loaded`, `start <i>`, `done <i> <status>`,
# `finished`. Each line is appended and the file closed, so a crash loses nothing written.
function report(file, line)
    open(io -> (println(io, line); flush(io)), file, "a")
end

# the last `n` bytes of a file at most, so that a flood of diagnostics can't exhaust memory
function read_tail(file, n=65536)
    isfile(file) || return ""
    open(file) do io
        seek(io, max(0, filesize(io) - n))
        read(io, String)
    end
end

function worker(progress::String, cases::Vector{Int})
    @eval Main using Metal, Random, LinearAlgebra
    report(progress, "loaded")
    for i in cases
        report(progress, "start $i")
        name, ex = CASES[i]
        # Iridium and the Vulkan driver report on stderr; capture it per case (the driver
        # shows the file if the case crashes) and keep the first Iridium message
        errfile = case_stderr(progress, i)
        status = open(errfile, "w") do errio
            redirect_stderr(errio) do
                try
                    Base.invokelatest(Core.eval, Main, :(let; $ex; end)) ? "PASS" : "WRONG"
                catch e
                    # showerror methods for Metal's and ObjectiveC's exceptions (NSError) were
                    # added after this function was compiled
                    msg = first(split(Base.invokelatest(sprint, showerror, e), '\n'))
                    "ERROR " * first(msg, 140)
                end
            end
        end
        open(errfile) do io             # copy it to the worker log; keep the first Iridium line
            iridium = nothing
            for line in eachline(io)
                println(stderr, line)
                iridium === nothing && startswith(line, "Iridium: ") && (iridium = line[10:end])
            end
            flush(stderr)
            if startswith(status, "ERROR") && iridium !== nothing
                status *= " [Iridium: " * first(iridium, 120) * "]"
            end
        end
        report(progress, "done $i $status")
    end
    report(progress, "finished")
end

case_stderr(progress, i) = joinpath(dirname(progress), "$(splitext(basename(progress))[1])-case$i.stderr")

function parse_progress(file)
    # only complete (newline-terminated) records: a worker can die halfway through a write
    events = isfile(file) ? split(read(file, String), '\n')[1:end-1] : String[]
    loaded = "loaded" in events
    finished = "finished" in events
    started = nothing
    results = Pair{Int,String}[]     # in the order the cases ran
    for ev in events
        fields = split(ev, ' '; limit=3)
        i = length(fields) >= 2 ? tryparse(Int, fields[2]) : nothing
        (i === nothing || !checkbounds(Bool, CASES, i)) && continue
        if fields[1] == "start" && length(fields) == 2
            started = i
        elseif fields[1] == "done" && length(fields) == 3
            push!(results, i => String(fields[3]))
            started = nothing
        end
    end
    (; loaded, finished, started, results, nevents=length(events))
end

function describe_exit(proc)
    proc.termsignal != 0 ? "signal $(proc.termsignal)" : "exit code $(proc.exitcode)"
end

function tail_log(log, n=15)
    isfile(log) || return
    lines = split(chomp(read_tail(log)), '\n')
    for l in lines[max(1, end - n + 1):end]
        println(stderr, "  | ", l)
    end
    flush(stderr)
end

function driver(; case_timeout, load_timeout, logdir, selected)
    mkpath(logdir)
    julia = Base.julia_cmd()
    project = Base.active_project()
    script = abspath(PROGRAM_FILE)
    reported = Set{Int}()
    passes = 0
    emit(i, status) = (println(rpad(CASES[i].first, 16), status); flush(stdout); push!(reported, i);
                       status == "PASS" && (passes += 1))

    attempt = 0
    while true
        pending = filter(!in(reported), selected)
        isempty(pending) && break
        attempt += 1
        progress = joinpath(logdir, "progress-$attempt.txt")
        log = joinpath(logdir, "worker-$attempt.log")
        cmd = `$julia --threads=1 --project=$project $script --worker $progress $(join(pending, ','))`
        logio = open(log, "w")    # one stream for both, so they don't overwrite each other
        proc = run(pipeline(cmd; stdout=logio, stderr=logio, stdin=devnull); wait=false)

        seen = 0
        last_change = time()
        timed_out = false
        snapshot = nothing
        flush_results(state) = for (i, status) in state.results
            i in pending && !(i in reported) && emit(i, status)
        end
        while process_running(proc)
            sleep(0.5)
            state = parse_progress(progress)
            flush_results(state)
            if state.nevents != seen
                seen = state.nevents
                last_change = time()
            end
            limit = state.loaded ? case_timeout : load_timeout
            if time() - last_change > limit
                # whatever the worker reports while being killed doesn't count
                timed_out = true
                snapshot = state
                kill(proc)                                    # SIGTERM
                for _ in 1:20
                    process_running(proc) || break
                    sleep(0.5)
                end
                process_running(proc) && kill(proc, Base.SIGKILL)
                break
            end
        end
        wait(proc)
        close(logio)
        state = timed_out ? snapshot : parse_progress(progress)
        flush_results(state)
        state.finished && break

        how = timed_out ? "TIMEOUT" : "CRASH $(describe_exit(proc))"
        if !state.loaded
            println(stderr, "survey: worker failed before loading Metal ($how); log $log")
            tail_log(log)
            foreach(i -> emit(i, "$how (loading Metal)"), pending)
            break
        elseif state.started !== nothing && state.started in pending
            i = state.started
            println(stderr, "survey: worker $(timed_out ? "timed out" : "died") in case \"$(CASES[i].first)\"; log $log")
            tail_log(log)
            tail_log(case_stderr(progress, i))
            emit(i, how)
        else
            # died between cases; the next attempt resumes after the cases it reported, but
            # give up if it reported none, rather than retrying forever
            println(stderr, "survey: worker exited outside a case ($how); log $log")
            tail_log(log)
            isempty(state.results) && break
        end
    end
    for i in selected
        i in reported || emit(i, "NOT RUN")
    end
    println("survey: $passes/$(length(selected))")
    println(stderr, "survey: worker logs in $logdir")
    return
end

function main(args)
    if !isempty(args) && args[1] == "--worker"
        worker(args[2], parse.(Int, split(args[3], ',')))
        return
    end
    case_timeout = 300.0
    load_timeout = 900.0
    logdir = nothing
    selected = collect(eachindex(CASES))
    i = 1
    while i <= length(args)
        a = args[i]
        if a == "--case-timeout"
            case_timeout = parse(Float64, args[i+1]); i += 2
        elseif a == "--load-timeout"
            load_timeout = parse(Float64, args[i+1]); i += 2
        elseif a == "--logdir"
            logdir = args[i+1]; i += 2
        elseif a == "--only"
            # in the order given, so that a crashing case can be put before others
            selected = map(split(args[i+1], ',')) do name
                j = findfirst(c -> c.first == name, CASES)
                j === nothing && error("unknown case $name in --only")
                j
            end
            i += 2
        else
            error("unknown argument $a")
        end
    end
    # a fresh directory per run, so that a reused --logdir can't mix in old progress files
    logdir = logdir === nothing ? mktempdir(; cleanup=false) : (mkpath(logdir); mktempdir(logdir; prefix="survey-", cleanup=false))
    driver(; case_timeout, load_timeout, logdir, selected)
end

main(ARGS)
