module PerplexForge

export run_workbench, BoardData, SimSetup, Element, launch_viewer, version_text

include("BoardParser.jl")
using .BoardParser

include("SimSetup.jl")      # net classes + lumped elements, sidecar file (no GUI)
using .SimSetups

include("Geometry.jl")      # pad / stackup geometry shared by the view and the solvers
include("Mesh.jl")          # copper mesh shared by the solvers
include("DCSolver.jl")      # DC IR-drop solver (no GUI)
using .DCSolver
include("ACSolver.jl")      # AC PDN-impedance solver (no GUI)
using .ACSolver
include("XSection.jl")      # 2-D field solver for trace cross-sections (no GUI)
using .XSection
include("SISolver.jl")      # signal-integrity analysis: impedance, return paths, lengths (no GUI)
using .SISolver
include("Report.jl")        # HTML report of the DC / AC / SI results (no GUI)
using .Report

include("Widgets.jl")       # list panel, splitters, tabs, rebuildable panels
include("State.jl")         # shared observable UI state
include("Scene3D.jl")       # geometry + 3D scene
include("Inspector.jl")     # net / component / element inspector
include("ResultsPanel.jl")  # DC / AC results tab
include("ImpedancePanel.jl") # |Z(f)| plot tab
include("SIPanel.jl")       # signal-integrity tab and tables
include("Viewer.jl")        # the workbench window
using .Viewer

const BANNER = raw"""
  ╔══════════════════════════════════════════════════╗
  ║   P E R P L E X   F O R G E                      ║
  ║   Power / Signal Integrity Workbench             ║
  ╚══════════════════════════════════════════════════╝
"""

const ROOT = normpath(joinpath(@__DIR__, ".."))
const VERSION_TEXT = Ref("")

"""
    version_text() -> String

"v0.1.0" for an installed release; "v0.1.0-dev (abc1234)" when running from a git
checkout (the development copy), so the two are easy to tell apart.
"""
function version_text()
    isempty(VERSION_TEXT[]) || return VERSION_TEXT[]
    v = "v" * string(something(pkgversion(@__MODULE__), v"0.0.0"))
    if isdir(joinpath(ROOT, ".git"))
        sha = try
            readchomp(pipeline(`git -C $ROOT rev-parse --short HEAD`; stderr = devnull))
        catch
            ""
        end
        v *= "-dev" * (isempty(sha) ? "" : " ($sha)")
    end
    return VERSION_TEXT[] = v
end

"""
    run_workbench(filepath; on_simulate=nothing, block=false, show=true)

Parse a KiCad board (printing a launch log), load its `<board>.perplex.json` setup if
present, and open the workbench.

- `on_simulate(board, setup)` is called by the ▶ button once the DC setup check passes.
- `block=true` keeps Julia alive until the window is closed (use when running as a script).
"""
function run_workbench(filepath::String; on_simulate = nothing, block::Bool = false, show::Bool = true)
    println(BANNER)
    println("  ", version_text())
    println()
    isfile(filepath) || error("Board file not found: $filepath")
    filepath = abspath(filepath)
    println("[boot   ] Project file : ", filepath)

    log_lines = String[]
    board = parse_kicad_board(filepath; logger = s -> push!(log_lines, s))

    println()
    println("[summary] Board        : ", round(board.width, digits = 2), " × ", round(board.height, digits = 2), " mm")
    println("[summary] Nets         : ", length(board.nets))
    println("[summary] Components   : ", length(board.components))
    println("[summary] Trace segs   : ", length(board.traces))
    println("[summary] Vias         : ", length(board.vias))
    println("[summary] Pours        : ", length(board.zones))
    println("[summary] Stackup      : ", isempty(board.stackup) ? "not defined" : "$(length(board.stackup)) entries")

    setup, status = load_setup(filepath, board)
    sp = basename(setup_path(filepath))
    msg = status == :loaded ?
        "Loaded $sp: $(length(setup.elements)) element(s), $(count(!=(:unspecified), values(setup.netclass))) classified net(s)" :
        "No $sp yet: nets auto-classified from their names (click Save to create it)"
    println("[setup  ] ", msg)
    push!(log_lines, "[setup] " * msg)
    println()
    println("[boot   ] Launching workbench...")

    launch_viewer(board, setup; on_simulate = on_simulate, startup_log = log_lines, block = block, show = show,
                  version = version_text())
    return board
end

end # module
