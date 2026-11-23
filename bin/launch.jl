# PerplexForge launcher entry point.
#
#   julia --project=<PerplexForge> bin/launch.jl <board.kicad_pcb>
#
# Started by the KiCad plugin (kicad_plugin/launch_workbench.py) or by bin/perplexforge.bat / .sh.

function pause_before_exit(msg)
    println()
    println(msg)
    println("Press Enter to close this window.")
    try
        readline()
    catch
    end
end

if isempty(ARGS)
    pause_before_exit("Usage: perplexforge <board.kicad_pcb>")
    exit(1)
end

# First run (e.g. right after installing the KiCad add-on): install the Julia packages once.
import Pkg
function deps_ready()
    try
        for name in ("GLMakie", "JSON3")
            id = Base.identify_package(name)
            (id === nothing || Base.locate_package(id) === nothing) && return false
        end
        return true
    catch
        return false
    end
end
if !deps_ready()
    println("[setup  ] First run: installing PerplexForge's Julia packages (GLMakie and friends).")
    println("[setup  ] This happens once and takes several minutes; later starts are much faster.")
    println()
    try
        Pkg.instantiate()
        Pkg.precompile()
    catch err
        showerror(stdout, err)
        pause_before_exit("Installing the Julia packages failed (see above). Check your internet connection and try again.")
        exit(1)
    end
end

println("[launch ] Loading PerplexForge (first start after an update can take a while)...")
using PerplexForge          # must be top level: Julia 1.12+ binding world-age rules

function main(board_path)
    println("[launch ] Reading the LAST SAVED copy of the board.")
    println("[launch ] To pick up edits: refill zones (B) and save in KiCad, then relaunch.")
    println()
    try
        run_workbench(board_path; block = true)
    catch err
        println()
        println("ERROR while running the workbench:")
        showerror(stdout, err, catch_backtrace())
        pause_before_exit("The workbench stopped because of the error above.")
        return 1
    end
    return 0
end

exit(main(abspath(ARGS[1])))
