module WorkbenchState

# Shared, observable UI state of the workbench (used by the 3D scene, inspector and docks).

using GLMakie
using ..BoardParser: BoardData, Component
using ..SimSetups

export UIState, changed!, request!, sel_component, find_element, shown_rail, AC_MODE, SI_MODES, is_si_mode, OVERLAY_CMAP,
       CLASS_COLORS, KIND_COLORS, KIND_TAGS, SEVERITY_COLORS, lighten, darken, rgba

lighten(c::RGBf, t) = RGBf(c.r + (1 - c.r) * t, c.g + (1 - c.g) * t, c.b + (1 - c.b) * t)
darken(c::RGBf, t) = RGBf(c.r * t, c.g * t, c.b * t)
rgba(c::RGBf, a = 1f0) = RGBAf(c.r, c.g, c.b, a)

const CLASS_COLORS = Dict(
    :power       => RGBf(0.95, 0.38, 0.25),
    :ground      => RGBf(0.30, 0.58, 0.98),
    :digital     => RGBf(0.40, 0.82, 0.42),
    :unspecified => RGBf(0.55, 0.55, 0.58),
)

const KIND_COLORS = Dict(
    :vrm       => RGBf(0.25, 0.90, 0.40),
    :sink      => RGBf(1.00, 0.60, 0.15),
    :resistor  => RGBf(0.80, 0.80, 0.85),
    :inductor  => RGBf(0.75, 0.65, 0.95),
    :ferrite   => RGBf(0.65, 0.55, 0.85),
    :short     => RGBf(0.70, 0.70, 0.70),
    :diode     => RGBf(0.95, 0.85, 0.35),
    :capacitor => RGBf(0.45, 0.85, 0.95),
)

const KIND_TAGS = Dict(:vrm => "VRM", :sink => "SNK", :resistor => "R", :inductor => "L",
                       :ferrite => "FB", :short => "0Ω", :diode => "D", :capacitor => "C")

mutable struct UIState
    board::BoardData
    setup::SimSetup
    comps::Dict{String,Component}
    sel::Observable{Tuple{Symbol,String}}          # (:none|:net|:comp|:elem, name)
    rev::Observable{Int}                           # bumped on any setup change
    class_rev::Observable{Int}                     # bumped when net classes change
    color_by::Observable{String}                   # "Layer" | "Net class"
    modes::Dict{Symbol,Observable{String}}         # display mode per element category
    layer_names::Vector{String}
    layer_on::Dict{String,Observable{Bool}}
    show_outline::Observable{Bool}
    show_diel::Observable{Bool}
    diel_defined::Bool
    show_passive_markers::Observable{Bool}
    exag::Observable{Float64}
    filtered_nets::Vector{String}                  # current Nets-tab filter result
    pending::Set{Symbol}                           # deferred UI rebuilds (see request!)
    say::Function                                  # console logger
    result::Observable{Any}                        # last DCResult (or nothing)
    result_mode::Observable{String}                # overlay: "Off" | "Voltage" | "IR drop" | "Current density"
    result_net::Observable{String}                 # rail shown in the "Voltage" overlay ("" = first VRM rail)
    result_rev::Int                                # setup revision the result was computed from
    ac_result::Observable{Any}                     # last ACResult (or nothing)
    ac_freq::Observable{Float64}                   # frequency for the "AC |V|" overlay (0 = none picked)
    ac_port::Observable{Int}                       # port index driven for the "AC |V|" overlay
    ac_rev::Int
    si_result::Observable{Any}                     # last SIResult (or nothing)
    si_rev::Int
    si_issue::Observable{Int}                      # finding highlighted in 3D (0 = none)
end

const AC_MODE = "AC |V| at f"

"Result colour scale: turbo without its near-black ends, so both extremes stay visible on the dark view."
const OVERLAY_CMAP = cgrad([cgrad(:turbo)[x] for x in range(0.07, 0.93; length = 256)])
"Overlays of the signal-integrity result: traces coloured by impedance, by target check, by reference type."
const SI_MODES = ("SI impedance", "SI vs target", "SI reference")
is_si_mode(m) = m in SI_MODES

const SEVERITY_COLORS = Dict(:error => RGBf(0.95, 0.35, 0.30), :warning => RGBf(0.98, 0.75, 0.25),
                             :info => RGBf(0.60, 0.65, 0.75))

"The rail to show in the voltage overlay for result `res`."
function shown_rail(st::UIState, res)
    n = st.result_net[]
    return (!isempty(n) && n in res.nets) ? n : (isempty(res.vrms) ? (isempty(res.nets) ? "" : res.nets[1]) : res.vrms[1].net_pos)
end

"Record a change to the setup: marks it unsaved and notifies listeners."
function changed!(st::UIState; classes::Bool = false)
    st.setup.dirty = true
    classes && (st.class_rev[] += 1)
    st.rev[] += 1
    return st
end

"Ask for a UI part to be rebuilt on the next frame (safe to call from a widget's own callback)."
request!(st::UIState, what::Symbol) = (push!(st.pending, what); st)

find_element(st::UIState, id) = (i = findfirst(e -> e.id == id, st.setup.elements); i === nothing ? nothing : st.setup.elements[i])

"The component reference implied by the current selection, or nothing."
function sel_component(st::UIState, sel = st.sel[])
    kind, name = sel
    kind == :comp && return name
    if kind == :elem
        e = find_element(st, name)
        return e === nothing ? nothing : e.ref
    end
    return nothing
end

end # module
