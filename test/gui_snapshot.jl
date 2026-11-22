# Renders the workbench offscreen, drives a few actions, and saves PNG snapshots.
#   PERPLEXFORGE_TEST_BOARD=<board.kicad_pcb>  julia --project=. test/gui_snapshot.jl [outdir]
# Uses a fresh in-memory setup: nothing is written next to the board. The script is written
# for a board with an STM32F405RGT6 sink and an MP2359 buck (adapt the refs for other boards).

using PerplexForge
using GLMakie

const PF = PerplexForge
board_path = get(ENV, "PERPLEXFORGE_TEST_BOARD", "")
isfile(board_path) || error("Set PERPLEXFORGE_TEST_BOARD to a .kicad_pcb (this script drives the GUI on a real board).")
outdir = isempty(ARGS) ? mktempdir() : mkpath(ARGS[1])

board = PF.parse_kicad_board(board_path; verbose = false)
setup = PF.SimSetups.new_setup(board_path, board)
ui = launch_viewer(board, setup; show = false)

function snap(name)
    ui.flush!()
    path = joinpath(outdir, name * ".png")
    save(path, ui.fig; px_per_unit = 1)
    println("snapshot: ", path)
end

ref_of(value) = first(c.ref for c in board.components if c.value == value)
mcu = ref_of("STM32F405RGT6")
buck = ref_of("MP2359DJ-LF-Z")
cap = first(c.ref for c in board.components if c.value == "100n")

snap("01_start")

ui.exec("net +3V3")
ui.exec("colorby class")
snap("02_net_class_colors")

ui.exec("element add sink $mcu +3V3 GND I=150m")
ui.exec("element add vrm $buck +3V3 GND V=3.3 Rout=5m")
ui.state.sel[] = (:elem, "VRM1")
snap("03_vrm_editor")

ui.state.sel[] = (:comp, cap)
ui.flush!()
ui.exec("element add c $cap")
snap("04_capacitor_editor")

ui.state.sel[] = (:elem, "SNK1")
ui.tabs_left.active[] = :setup
ui.exec("check")
snap("05_sink_and_check")

ui.exec("dc")                                   # voltage overlay of the VRM rail by default
ui.exec("view top")
snap("05a_dc_voltage_top")
ui.exec("view bottom")
snap("05b_dc_voltage_bottom")
ui.exec("rail GND")
snap("05b2_dc_voltage_gnd_bottom")
ui.exec("rail +3V3")
ui.exec("overlay drop")
ui.exec("view iso")
snap("05c_dc_ir_drop_iso")
ui.exec("overlay density")
snap("05d_dc_current_density")
ui.exec("overlay drop")
for n in ui.state.layer_names                   # what the Results tab's Layer menu does
    ui.state.layer_on[n][] = n == "In2.Cu"
end
ui.exec("view top")
snap("05e_dc_ir_drop_In2_only")
foreach(n -> ui.state.layer_on[n][] = true, ui.state.layer_names)

ui.tabs_right.active[] = :view
ui.exec("zscale 8")
ui.exec("view side")
snap("06_view_tab_zscale8_side")

# ── synthetic mouse: drag the left splitter 120 px right and the console splitter 100 px up ──
ev = events(ui.fig)
function drag!(box, dx, dy)
    bb = box.layoutobservables.computedbbox[]
    c = GLMakie.Makie.GeometryBasics.origin(bb) .+ widths(bb) ./ 2
    ev.mouseposition[] = (c[1], c[2])
    ev.mousebutton[] = GLMakie.Makie.MouseButtonEvent(Mouse.left, Mouse.press)
    ev.mouseposition[] = (c[1] + dx / 2, c[2] + dy / 2)
    ev.mouseposition[] = (c[1] + dx, c[2] + dy)
    ev.mousebutton[] = GLMakie.Makie.MouseButtonEvent(Mouse.left, Mouse.release)
end
before = ui.splitters.sizes()
drag!(ui.splitters.left.box, 120, 0)
drag!(ui.splitters.console.box, 0, 100)
drag!(ui.splitters.right.box, -80, 0)
after = ui.splitters.sizes()
println("splitters before: ", before, "\nsplitters after:  ", after)
ui.tabs_right.active[] = :inspector
ui.exec("view iso")
snap("07_resized_panels")

# ── picking: sample a grid of points over the 3D view, report what is under each ──
vp = ui.scene.scene.viewport[]
o, w = GLMakie.Makie.GeometryBasics.origin(vp), widths(vp)
hits = Dict{Symbol,Int}()
for fx in 0.3:0.1:0.7, fy in 0.3:0.1:0.7
    ev.mouseposition[] = (o[1] + fx * w[1], o[2] + fy * w[2])
    t = PF.Scene3D.pick_target(ui.scene)
    k = t === nothing ? :nothing : t[1]
    hits[k] = get(hits, k, 0) + 1
    if t === nothing && get(ENV, "PF_DEBUG_PICK", "") == "1"
        plt, i = pick(ui.scene.scene)
        if plt === nothing
            println("  miss → nothing")
        else
            nv = haskey(plt.attributes, :mesh) ? length(GLMakie.Makie.coordinates(plt.mesh[])) : -1
            println("  miss → ", (GLMakie.Makie.plotfunc(plt), i, "nverts=$nv", "transp=$(get(plt.attributes, :transparency, missing)[])",
                                  "parent mapped=$(haskey(ui.scene.pickmap, plt.parent))"))
        end
    end
end
println("pick results over 25 points: ", hits)
ui.exec("mode bodies off")
for v in ("top", "bottom")
    ui.exec("view $v")
    ui.flush!(); save(joinpath(outdir, "_tmp.png"), ui.fig; px_per_unit = 1)   # render so the camera is applied
    ev.mouseposition[] = (o[1] + 0.42 * w[1], o[2] + 0.55 * w[2])
    println("hover from $v: ", something(PF.Scene3D.hover_info(ui.scene, ui.state), "(nothing)"))
end
ui.exec("mode bodies solid")

# ── AC: decoupling caps on +3V3/GND as elements, sweep, impedance tab, click → 3D map ──
for c in board.components
    startswith(c.ref, "C") || continue
    any(p -> p.net_name == "+3V3", c.pads) && any(p -> p.net_name == "GND", c.pads) || continue
    any(e -> e.ref == c.ref, ui.state.setup.elements) || ui.exec("element add c $(c.ref)")
end
ui.exec("acset points_per_decade 6")
ui.exec("ac")
ui.flush!()
snap("08_ac_impedance")
zax = first(b for b in ui.zpanel.blocks if b isa Axis)
zvp = zax.scene.viewport[]
zo, zw = GLMakie.Makie.GeometryBasics.origin(zvp), widths(zvp)
ev.mouseposition[] = (zo[1] + 0.62 * zw[1], zo[2] + 0.5 * zw[2])
fm = PF.ImpedancePanel.axis_x_at_mouse(zax)
println("impedance axis x-limits: ", zax.finallimits[].origin[1], " … ", zax.finallimits[].origin[1] + zax.finallimits[].widths[1],
        "  → f at 62% = ", round(fm, sigdigits = 4))
ev.mousebutton[] = GLMakie.Makie.MouseButtonEvent(Mouse.left, Mouse.press)
ev.mousebutton[] = GLMakie.Makie.MouseButtonEvent(Mouse.left, Mouse.release)
println("picked frequency: ", ui.state.ac_freq[], "  mode: ", ui.state.result_mode[])
ui.tabs_right.active[] = :results
ui.exec("view iso")
snap("09_ac_map_iso")
for n in ui.state.layer_names
    ui.state.layer_on[n][] = n == "In2.Cu"
end
ui.exec("view top")
snap("10_ac_map_In2_top")
foreach(n -> ui.state.layer_on[n][] = true, ui.state.layer_names)

# toggle Impedance ↔ Console a few times: nothing may be left behind
for t in (:console, :impedance, :console, :impedance, :console)
    ui.tabs_bottom.active[] = t
    ui.flush!()
end
nleg = count(b -> b isa Legend, ui.fig.content)
println("legends left in the figure after toggling (expect 0): ", nleg)
snap("11_after_toggling")

println("console tail:")
foreach(l -> println("  ", l), last(ui.console.items[], 12))
