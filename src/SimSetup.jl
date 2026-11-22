module SimSetups

# Simulation setup: net classes + lumped elements (VRMs, sinks, passive models).
# One model serves both DC and AC power-integrity analyses: each parameter is tagged
# with the analysis that uses it. No GLMakie dependency, so this is unit-testable.

using JSON3
using Dates
using ..BoardParser: BoardData, Component

export NET_CLASSES, CLASS_LABELS, CLASS_TAGS, ParamSpec, KindSpec, KIND_SPECS, KIND_ORDER,
       Element, SimSetup, parse_si, format_si, guess_netclass, guess_kind, default_element,
       next_element_id, component_nets, element_summary, netclass, set_class!,
       validate_dc, setup_path, recovery_path, load_setup, save_setup, new_setup

# ─────────────────────────────────────────────────────────────────────────────
# Net classes
# ─────────────────────────────────────────────────────────────────────────────
const NET_CLASSES  = (:power, :ground, :digital, :unspecified)
const CLASS_LABELS = Dict(:power => "Power", :ground => "Ground", :digital => "Digital", :unspecified => "Unspecified")
const CLASS_TAGS   = Dict(:power => "PWR", :ground => "GND", :digital => "DIG", :unspecified => " — ")

"Best guess of a net's PI role from its name (the user can override it)."
function guess_netclass(name::AbstractString)
    n = uppercase(strip(name))
    occursin(r"^(A|D|P|S|SH|CH)?GND|^VSS|^GROUND|^EARTH$|^0V$", n) && return :ground
    occursin(r"^\+", n) && return :power
    occursin(r"^-\d", n) && return :power
    occursin(r"^(VCC|VDD|VBUS|VBAT|VSYS|VIN|VREF|AVDD|DVDD|VDDA|VDDIO|PWR|VPP)", n) && return :power
    occursin(r"^\d+(\.\d+)?V\d*[A-Z]?$|^V\d+V?\d*$", n) && return :power
    return :unspecified
end

# ─────────────────────────────────────────────────────────────────────────────
# Element kinds and their parameters
# ─────────────────────────────────────────────────────────────────────────────
struct ParamSpec
    name::String
    unit::String
    default::Float64
    scope::Symbol          # :dc, :ac or :both — which analysis uses it
    label::String
end

struct KindSpec
    label::String
    group::Symbol          # :source, :load, :passive
    terminals::Tuple{String,String}
    params::Vector{ParamSpec}
end

const KIND_ORDER = [:vrm, :sink, :resistor, :inductor, :ferrite, :short, :capacitor]

const KIND_SPECS = Dict{Symbol,KindSpec}(
    :vrm => KindSpec("VRM", :source, ("+ out", "− ref"), [
        ParamSpec("V",    "V", 3.3,   :dc, "Output voltage"),
        ParamSpec("Rout", "Ω", 0.005, :dc, "Output resistance"),
        ParamSpec("Lout", "H", 1e-9,  :ac, "Output inductance")]),
    :sink => KindSpec("Sink", :load, ("+ supply", "− return"), [
        ParamSpec("I", "A", 0.1, :dc, "Load current"),
        ParamSpec("Istep", "A", 0.05, :ac, "Load step (target Z)"),
        ParamSpec("Ripple", "%", 3.0, :ac, "Allowed ripple (target Z)")]),
    :resistor => KindSpec("Resistor", :passive, ("1", "2"), [
        ParamSpec("R", "Ω", 1e3, :both, "Resistance")]),
    :inductor => KindSpec("Inductor", :passive, ("1", "2"), [
        ParamSpec("DCR", "Ω", 0.05, :dc, "DC resistance"),
        ParamSpec("L",   "H", 1e-6, :ac, "Inductance")]),
    :ferrite => KindSpec("Ferrite bead", :passive, ("1", "2"), [
        ParamSpec("DCR", "Ω", 0.1,  :dc, "DC resistance"),
        ParamSpec("L",   "H", 1e-6, :ac, "Equivalent inductance")]),
    :short => KindSpec("0 Ω / jumper", :passive, ("1", "2"), [
        ParamSpec("R", "Ω", 5e-4, :dc, "Resistance")]),
    :capacitor => KindSpec("Capacitor", :passive, ("1", "2"), [
        ParamSpec("C",   "F", 1e-7,  :ac, "Capacitance"),
        ParamSpec("ESR", "Ω", 0.01,  :ac, "Series resistance"),
        ParamSpec("ESL", "H", 5e-10, :ac, "Series inductance")]),
)

# ─────────────────────────────────────────────────────────────────────────────
# Data model
# ─────────────────────────────────────────────────────────────────────────────
mutable struct Element
    id::String                     # "VRM1", "SNK2", "C14", …
    kind::Symbol
    ref::String                    # component reference
    net_pos::String                # terminal nets; pads are found from the component at use time
    net_neg::String
    params::Dict{String,Float64}   # SI units
end

mutable struct SimSetup
    board_file::String
    netclass::Dict{String,Symbol}
    elements::Vector{Element}
    view::Dict{String,Any}         # zscale, color_by, panel sizes, display modes …
    dc::Dict{String,Any}           # DC analysis settings (cell size, temperature, plating …)
    ac::Dict{String,Any}           # AC analysis settings (frequency range, points, cell size)
    dirty::Bool
end

netclass(s::SimSetup, net::AbstractString) = get(s.netclass, net, :unspecified)

function set_class!(s::SimSetup, net::AbstractString, cls::Symbol)
    cls in NET_CLASSES || error("unknown net class $cls")
    get(s.netclass, net, nothing) === cls && return false
    s.netclass[String(net)] = cls
    s.dirty = true
    return true
end

# ─────────────────────────────────────────────────────────────────────────────
# SI values
# ─────────────────────────────────────────────────────────────────────────────
const SI_PREFIX = Dict('f' => 1e-15, 'p' => 1e-12, 'n' => 1e-9, 'u' => 1e-6, 'µ' => 1e-6, 'μ' => 1e-6,
                       'm' => 1e-3, 'k' => 1e3, 'K' => 1e3, 'M' => 1e6, 'G' => 1e9)

"""
    parse_si(s) -> Float64 or nothing

Parses engineering values: `"4.7u"`, `"100nF"`, `"10 mA"`, `"1e-3"`, `"3.3V"` and the
letter-as-decimal style used on schematics: `"4u7"`, `"1k5"`, `"4R7"`, `"3V3"`.
"""
function parse_si(s::AbstractString)
    t = replace(strip(s), " " => "")
    isempty(t) && return nothing
    m = match(r"^([-+]?(?:\d+\.?\d*|\.\d+)(?:[eE][-+]?\d+)?)([fpnuµμmkKMG]?)(?:Ω|ohms?|Ohms?|[FHVAWRΩ])?$", t)
    if m !== nothing
        v = parse(Float64, m.captures[1])
        p = m.captures[2]
        return isempty(p) ? v : v * SI_PREFIX[first(p)]
    end
    m = match(r"^(\d+)([fpnuµμmkKMGRrVv])(\d+)(?:Ω|ohms?|[FHVA])?$", t)
    if m !== nothing
        v = parse(Float64, m.captures[1] * "." * m.captures[3])
        c = first(m.captures[2])
        return c in ('R', 'r', 'V', 'v') ? v : v * SI_PREFIX[c]
    end
    return nothing
end
parse_si(::Nothing) = nothing

const PREFIX_OF = Dict(-15 => "f", -12 => "p", -9 => "n", -6 => "µ", -3 => "m", 0 => "", 3 => "k", 6 => "M", 9 => "G")

"Engineering notation: format_si(4.7e-6, \"F\") == \"4.7 µF\"."
function format_si(v::Real, unit::AbstractString = ""; digits::Int = 3)
    isfinite(v) || return string(v)
    v == 0 && return "0 " * unit
    e = clamp(floor(Int, log10(abs(v)) / 3) * 3, -15, 9)
    m = round(v / 10.0^e, sigdigits = digits)
    if abs(m) >= 1000 && e < 9                     # rounding pushed it to the next prefix
        e += 3
        m = round(v / 10.0^e, sigdigits = digits)
    end
    s = string(m)
    endswith(s, ".0") && (s = s[1:end-2])
    return s * " " * PREFIX_OF[e] * unit
end

# ─────────────────────────────────────────────────────────────────────────────
# Components → nets, guesses, defaults
# ─────────────────────────────────────────────────────────────────────────────
is_real_net(n) = !isempty(n) && n != "UNCONNECTED"

"Nets on a component's pads, in pad order, with pad counts: [(net, npads), …]."
function component_nets(c::Component)
    order = String[]
    counts = Dict{String,Int}()
    for p in c.pads
        is_real_net(p.net_name) || continue
        haskey(counts, p.net_name) || push!(order, p.net_name)
        counts[p.net_name] = get(counts, p.net_name, 0) + 1
    end
    return [(n, counts[n]) for n in order]
end

ref_prefix(ref) = (m = match(r"^[A-Za-z_]+", ref); m === nothing ? "" : uppercase(m.match))

const REGULATOR_HINT = r"LDO|REG|BUCK|BOOST|1117|78\d\d|MP\d{4}|TPS\d|LM\d{3}|AMS|RT\d{4}|AP\d{4}|MIC\d{4}|LT[C]?\d{4}|NCP\d"i

function guess_kind(c::Component, ::SimSetup)
    p = ref_prefix(c.ref)
    v = strip(c.value)
    p == "R"  && return (v in ("0", "0R", "0Ω") ? :short : :resistor)
    p == "C"  && return :capacitor
    p == "FB" && return :ferrite
    p == "L"  && return (occursin(r"@|MHz"i, v) ? :ferrite : :inductor)
    p in ("JP", "SB", "F", "NT") && return :short
    occursin(REGULATOR_HINT, v) && return :vrm
    p in ("PS", "VR") && return :vrm
    return :sink
end

"Voltage hinted by a rail name: \"+3V3\" → 3.3, \"+5V\" → 5, \"+3.3VA\" → 3.3."
function rail_voltage(net::AbstractString)
    m = match(r"(\d+)V(\d+)", net)
    m !== nothing && return parse(Float64, m.captures[1] * "." * m.captures[2])
    m = match(r"(\d+(?:\.\d+)?)V", net)
    m !== nothing && return parse(Float64, m.captures[1])
    return nothing
end

function next_element_id(s::SimSetup, kind::Symbol, ref::AbstractString)
    taken = Set(e.id for e in s.elements)
    if KIND_SPECS[kind].group == :passive
        ref in taken || return String(ref)
        base = String(ref) * "_"
    else
        base = kind == :vrm ? "VRM" : "SNK"
    end
    k = 1
    while base * string(k) in taken
        k += 1
    end
    return base * string(k)
end

"A new element of `kind` on component `c`, with terminals and values pre-filled."
function default_element(kind::Symbol, c::Component, s::SimSetup)
    spec = KIND_SPECS[kind]
    nets = [n for (n, _) in component_nets(c)]
    params = Dict(p.name => p.default for p in spec.params)
    pos = neg = ""
    if spec.group == :passive
        padnet(num) = (i = findfirst(p -> p.pad_num == num && is_real_net(p.net_name), c.pads);
                       i === nothing ? nothing : c.pads[i].net_name)
        pos = something(padnet("1"), get(nets, 1, ""))
        others = filter(!=(pos), nets)
        neg = something(padnet("2"), isempty(others) ? "" : others[1])
        val = parse_si(c.value)
        if val !== nothing
            kind in (:resistor, :short) && (params["R"] = val)
            kind == :capacitor && (params["C"] = val)
            kind == :inductor && (params["L"] = val)
        end
    else
        # supply terminal: the power-class net with most pads; return: a ground-class net
        pw = sort([(n, k) for (n, k) in component_nets(c) if netclass(s, n) == :power]; by = x -> -x[2])
        gd = [n for n in nets if netclass(s, n) == :ground]
        pos = isempty(pw) ? "" : pw[1][1]
        neg = isempty(gd) ? "" : gd[1]
        if kind == :vrm && !isempty(pos)
            v = rail_voltage(pos)
            v === nothing || (params["V"] = v)
        end
    end
    return Element(next_element_id(s, kind, c.ref), kind, c.ref, pos, neg, params)
end

"One-line description: \"VRM1  U1  +3V3 → GND  3.3 V\"."
function element_summary(e::Element)
    spec = KIND_SPECS[e.kind]
    main = isempty(spec.params) ? "" : (p = spec.params[1]; format_si(get(e.params, p.name, p.default), p.unit))
    a = isempty(e.net_pos) ? "?" : e.net_pos
    b = isempty(e.net_neg) ? "?" : e.net_neg
    who = e.id == e.ref ? e.id : "$(e.id)  $(e.ref)"
    return "$who  $a → $b  $main"
end

# ─────────────────────────────────────────────────────────────────────────────
# DC setup validation
# ─────────────────────────────────────────────────────────────────────────────
"""
    validate_dc(setup, board) -> (errors, warnings, summary)

Checks that the setup is complete enough for a DC (IR-drop) analysis and builds a
per-rail summary. All three are vectors of strings.
"""
function validate_dc(s::SimSetup, board::BoardData)
    errors, warnings, summary = String[], String[], String[]
    comps = Dict(c.ref => c for c in board.components)
    vrms  = [e for e in s.elements if e.kind == :vrm]
    sinks = [e for e in s.elements if e.kind == :sink]
    isempty(vrms) && push!(errors, "No VRM defined: a DC analysis needs at least one voltage source.")
    isempty(sinks) && push!(warnings, "No sinks defined: nothing draws current, so there is no IR drop.")
    any(n -> n == :ground, values(s.netclass)) || push!(errors, "No net is classified as Ground.")

    for e in s.elements
        spec = KIND_SPECS[e.kind]
        c = get(comps, e.ref, nothing)
        c === nothing && (push!(errors, "$(e.id): component $(e.ref) is not on the board."); continue)
        isempty(e.net_pos) && push!(errors, "$(e.id): $(spec.terminals[1]) net not set.")
        isempty(e.net_neg) && push!(errors, "$(e.id): $(spec.terminals[2]) net not set.")
        !isempty(e.net_pos) && e.net_pos == e.net_neg && push!(errors, "$(e.id): both terminals on $(e.net_pos).")
        cnets = Set(n for (n, _) in component_nets(c))
        for n in (e.net_pos, e.net_neg)
            isempty(n) && continue
            n in board.nets || (push!(errors, "$(e.id): net $n does not exist on the board."); continue)
            if !(n in cnets)
                if spec.group == :source
                    push!(warnings, "$(e.id): $(e.ref) has no pad on $n; the solver will attach it at the nearest pad of that net.")
                else
                    push!(errors, "$(e.id): $(e.ref) has no pad on $n.")
                end
            end
        end
        if spec.group != :passive
            !isempty(e.net_pos) && netclass(s, e.net_pos) != :power &&
                push!(warnings, "$(e.id): + net $(e.net_pos) is not classified as Power.")
            !isempty(e.net_neg) && netclass(s, e.net_neg) != :ground &&
                push!(warnings, "$(e.id): − net $(e.net_neg) is not classified as Ground.")
        end
        for p in spec.params
            v = get(e.params, p.name, NaN)
            p.scope == :ac && continue
            (isfinite(v) && v >= 0) || push!(errors, "$(e.id): $(p.label) is invalid ($v).")
        end
    end

    # rails: one line per net that has a VRM or a sink on it
    rails = sort!(unique([e.net_pos for e in vcat(vrms, sinks) if !isempty(e.net_pos)]))
    for r in rails
        rv = [e for e in vrms if e.net_pos == r]
        rs = [e for e in sinks if e.net_pos == r]
        total = sum(e.params["I"] for e in rs; init = 0.0)
        src = isempty(rv) ? "NO VRM" : join(["VRM $(e.ref) " * format_si(e.params["V"], "V") for e in rv], ", ")
        lds = isempty(rs) ? "no sinks" : "sinks " * join(["$(e.ref) " * format_si(e.params["I"], "A") for e in rs], ", ")
        push!(summary, "$r: $src | $lds | total " * format_si(total, "A"))
        isempty(rv) && !isempty(rs) && push!(errors, "Rail $r has sinks but no VRM.")
        length(rv) > 1 && push!(warnings, "Rail $r has $(length(rv)) VRMs (parallel sources).")
    end
    return errors, warnings, summary
end

# ─────────────────────────────────────────────────────────────────────────────
# Sidecar file  <board>.perplex.json
# ─────────────────────────────────────────────────────────────────────────────
const FORMAT = "perplexforge-setup"
const VERSION = 1

setup_path(board_file)    = splitext(board_file)[1] * ".perplex.json"
recovery_path(board_file) = splitext(board_file)[1] * ".perplex.recovery.json"

"A setup with every net auto-classified from its name."
function new_setup(board_file::AbstractString, board::BoardData)
    nc = Dict(n => guess_netclass(n) for n in board.nets)
    return SimSetup(String(board_file), nc, Element[], Dict{String,Any}(), Dict{String,Any}(), Dict{String,Any}(), true)
end

function to_json_tree(s::SimSetup)
    groups = [(c, sort!([n for (n, k) in s.netclass if k == c])) for c in NET_CLASSES]
    return (format = FORMAT,
            version = VERSION,
            board = basename(s.board_file),
            saved = string(Dates.now()),
            netclasses = (; (Symbol(c) => ns for (c, ns) in groups)...),
            elements = [(id = e.id, kind = string(e.kind), ref = e.ref, net_pos = e.net_pos, net_neg = e.net_neg,
                         params = (; (Symbol(k) => e.params[k] for k in sort!(collect(keys(e.params))))...))
                        for e in s.elements],
            dc_settings = (; (Symbol(k) => s.dc[k] for k in sort!(collect(keys(s.dc))))...),
            ac_settings = (; (Symbol(k) => s.ac[k] for k in sort!(collect(keys(s.ac))))...),
            view = (; (Symbol(k) => s.view[k] for k in sort!(collect(keys(s.view))))...))
end

"Write the setup (atomically) to `path` (default: the board's sidecar). Clears `dirty`."
function save_setup(s::SimSetup, path::AbstractString = setup_path(s.board_file); mark_clean::Bool = true)
    tmp = path * ".tmp"
    open(tmp, "w") do io
        JSON3.pretty(io, JSON3.write(to_json_tree(s)))
        println(io)
    end
    mv(tmp, path; force = true)
    mark_clean && (s.dirty = false)
    return path
end

plain(x::JSON3.Object) = Dict{String,Any}(String(k) => plain(v) for (k, v) in pairs(x))
plain(x::JSON3.Array) = Any[plain(v) for v in x]
plain(x) = x

"""
    load_setup(board_file, board; path = setup_path(board_file)) -> (setup, status)

`status` is `:loaded` or `:new`. Nets missing from the file get a name-based guess.
"""
function load_setup(board_file::AbstractString, board::BoardData; path::AbstractString = setup_path(board_file))
    isfile(path) || return new_setup(board_file, board), :new
    obj = JSON3.read(read(path, String))
    get(obj, :format, "") == FORMAT || error("$path is not a PerplexForge setup file")
    nc = Dict{String,Symbol}()
    if haskey(obj, :netclasses)
        for (cls, names) in pairs(obj.netclasses)
            Symbol(cls) in NET_CLASSES || continue
            for n in names
                nc[String(n)] = Symbol(cls)
            end
        end
    end
    for n in board.nets
        haskey(nc, n) || (nc[n] = guess_netclass(n))
    end
    els = Element[]
    for e in get(obj, :elements, [])
        kind = Symbol(e.kind)
        haskey(KIND_SPECS, kind) || continue
        params = Dict{String,Float64}(String(k) => Float64(v) for (k, v) in pairs(e.params))
        for p in KIND_SPECS[kind].params                       # new params added in later versions
            haskey(params, p.name) || (params[p.name] = p.default)
        end
        push!(els, Element(String(e.id), kind, String(e.ref), String(e.net_pos), String(e.net_neg), params))
    end
    view = haskey(obj, :view) ? plain(obj.view) : Dict{String,Any}()
    dc = haskey(obj, :dc_settings) ? plain(obj.dc_settings) : Dict{String,Any}()
    ac = haskey(obj, :ac_settings) ? plain(obj.ac_settings) : Dict{String,Any}()
    return SimSetup(String(board_file), nc, els, view, dc, ac, false), :loaded
end

end # module
