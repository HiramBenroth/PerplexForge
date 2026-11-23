module SISolver

# Signal-integrity analysis of the routed board (no GUI):
#
#   • Impedance & delay: every signal trace is sampled along its length; at each point the
#     nearest reference planes above / below (pours of Power- or Ground-class nets), a
#     coplanar ground pour beside it, and the partner trace of a differential pair define
#     a cross-section that the 2-D field solver (XSection) turns into Z0, Zdiff and delay.
#   • Return paths: traces that leave their reference plane or cross a split, and signal
#     vias that change reference plane without a nearby return (stitching) via or, when
#     the reference changes net, a stitching capacitor.
#   • Lengths: net length (traces + via transitions) and delay, differential-pair skew,
#     user-defined length-match groups, and via stubs.
#
# Plane coverage is rasterized per layer; holes smaller than `hole_mm2` (via antipads,
# thermal reliefs) are treated as solid plane, larger voids / edges / splits are not.

using Printf
using ..BoardParser: BoardData, Component, Trace, Via
using ..Geometry
using ..SimSetups
using ..PDNMesh: Grid, fill_polygon!, cell_index, inbounds
using ..XSection

export SISettings, SIResult, SI_SETTING_SPECS, si_settings, solve_si, si_summary_lines, find_diff_pairs,
       ZTarget, GroupDef, si_targets, si_groups, set_si_targets!, set_si_groups!, DEFAULT_TARGETS, si_stack,
       SIStack, globmatch, impedance_of, si_net_report, SI_KIND_LABEL

# ─────────────────────────────────────────────────────────────────────────────
# Settings, targets, groups (stored in setup.si)
# ─────────────────────────────────────────────────────────────────────────────
Base.@kwdef struct SISettings
    return_via_mm::Float64 = 1.5     # a reference-changing signal via needs a return via this close
    stitch_cap_mm::Float64 = 5.0     # … or a stitching capacitor this close when the reference net changes
    pair_skew_mm::Float64 = 0.15     # intra-pair length mismatch allowed
    z_tol_pct::Float64 = 10.0        # default impedance tolerance (targets can override)
    z_min_len_mm::Float64 = 1.0      # impedance excursions shorter than this are ignored (pad fan-out)
    hole_mm2::Float64 = 2.0          # plane holes up to this area count as solid plane (antipads)
    stub_mm::Float64 = 1.0           # via stubs longer than this are reported on high-speed nets
    fanout_mm::Float64 = 2.0         # reference gaps this short next to the net's own pad / via are pad fan-out
    cell_mm::Float64 = 0.0           # plane raster cell; 0 = automatic
end

const SI_SETTING_SPECS = [("return_via_mm", "Return via ≤", "mm", "from a signal via"),
                          ("stitch_cap_mm", "Stitch cap ≤", "mm", "if reference net changes"),
                          ("pair_skew_mm", "Pair skew ≤", "mm", ""),
                          ("z_tol_pct", "Z tolerance", "%", "default ±"),
                          ("z_min_len_mm", "Ignore Z runs <", "mm", "fan-out"),
                          ("hole_mm2", "Plane holes ≤", "mm²", "= solid"),
                          ("stub_mm", "Via stub ≤", "mm", "high-speed nets"),
                          ("fanout_mm", "Fan-out ≤", "mm", "gaps at pads ignored"),
                          ("cell_mm", "Plane cell", "mm", "0 = auto")]

function si_settings(s::SimSetup)
    d = SISettings()
    g(k) = (x = get(s.si, k, getfield(d, Symbol(k))); x isa Real ? Float64(x) : getfield(d, Symbol(k)))
    return SISettings((g(String(k)) for k in fieldnames(SISettings))...)
end

"Impedance target: nets (or pairs, `mode = :diff`) whose name matches `pattern` (glob, * and ?)."
struct ZTarget
    pattern::String
    z::Float64
    tol_pct::Float64          # NaN = the default tolerance
    mode::Symbol              # :se (single-ended Z0) or :diff (pair Zdiff)
end

"Length-match group: nets matching any pattern must agree within `tol` (mm, or ps when by = :delay)."
struct GroupDef
    name::String
    patterns::Vector{String}
    tol::Float64
    by::Symbol                # :length or :delay
end

"USB data pairs are 90 Ω differential; other interfaces vary, so they are left to the user."
const DEFAULT_TARGETS = [ZTarget("*USB*", 90.0, NaN, :diff), ZTarget("D+", 90.0, NaN, :diff), ZTarget("DP", 90.0, NaN, :diff),
                         ZTarget("*_D+", 90.0, NaN, :diff), ZTarget("*_DP", 90.0, NaN, :diff)]

function si_targets(s::SimSetup)
    haskey(s.si, "targets") || return copy(DEFAULT_TARGETS)
    out = ZTarget[]
    for t in s.si["targets"]
        t isa AbstractDict || continue
        z = get(t, "z", NaN); z isa Real || continue
        tol = get(t, "tol_pct", NaN)
        push!(out, ZTarget(String(get(t, "pattern", "*")), Float64(z), tol isa Real ? Float64(tol) : NaN,
                           Symbol(get(t, "mode", "se"))))
    end
    return out
end

set_si_targets!(s::SimSetup, ts::Vector{ZTarget}) =
    (s.si["targets"] = [Dict{String,Any}("pattern" => t.pattern, "z" => t.z, "mode" => string(t.mode),
                                         "tol_pct" => isnan(t.tol_pct) ? nothing : t.tol_pct) for t in ts]; s)

function si_groups(s::SimSetup)
    out = GroupDef[]
    for g in get(s.si, "groups", Any[])
        g isa AbstractDict || continue
        pats = get(g, "patterns", Any[])
        push!(out, GroupDef(String(get(g, "name", "group")), String[String(p) for p in pats],
                            Float64(get(g, "tol", 0.5)), Symbol(get(g, "by", "length"))))
    end
    return out
end

set_si_groups!(s::SimSetup, gs::Vector{GroupDef}) =
    (s.si["groups"] = [Dict{String,Any}("name" => g.name, "patterns" => g.patterns, "tol" => g.tol, "by" => string(g.by))
                       for g in gs]; s)

"Case-insensitive glob match (* any run, ? any character) of the whole name, or of its last sheet component."
function globmatch(pat::AbstractString, name::AbstractString)
    re = Regex("^" * replace(pat, r"[.+^$()\[\]{}|\\]" => s"\\\0", "*" => ".*", "?" => ".") * "\$", "i")
    occursin(re, name) && return true
    leaf = last(split(name, '/'))
    return leaf != name && occursin(re, leaf)
end

# ─────────────────────────────────────────────────────────────────────────────
# Differential pairs (by name)
# ─────────────────────────────────────────────────────────────────────────────
const PAIR_SUFFIXES = [("_DP", "_DM"), ("_DP", "_DN"), ("_P", "_N"), ("_p", "_n"), ("+", "-"), ("_H", "_L"),
                       ("_T", "_C"), ("_t", "_c"), ("DP", "DM"), ("P", "N")]

"""
    find_diff_pairs(nets) -> Vector{(name, p, n)}

Pairs of nets whose names differ only by a polarity suffix (`_P/_N`, `+/-`, `_DP/_DM`,
`_H/_L`, `_T/_C`, `P/N`). Both nets must exist; each net is in at most one pair.
"""
function find_diff_pairs(nets)
    have = Set(nets)
    used = Set{String}()
    out = Tuple{String,String,String}[]
    for n in sort!(collect(nets))
        n in used && continue
        for (sp, sn) in PAIR_SUFFIXES
            endswith(n, sp) || continue
            base = n[1:end-length(sp)]
            isempty(base) && continue
            m = base * sn
            (m in have && !(m in used) && m != n) || continue
            name = sp == "+" ? base * "±" : (endswith(base, "/") || endswith(base, "_")) ? base * sp * "/" * sn : base
            push!(out, (name, n, m)); push!(used, n, m)
            break
        end
    end
    return out
end

# ─────────────────────────────────────────────────────────────────────────────
# Stackup
# ─────────────────────────────────────────────────────────────────────────────
struct StackItem
    name::String
    kind::Symbol          # :copper, :dielectric, :mask
    t::Float64            # mm
    εr::Float64
    tanδ::Float64
    prepreg::Bool
end

struct SIStack
    items::Vector{StackItem}       # top → bottom
    cu::Vector{String}             # copper layers, top → bottom
    defined::Bool
    notes::Vector{String}
end

const DEFAULT_ER, DEFAULT_MASK_ER, DEFAULT_MASK_T = 4.5, 3.3, 0.015

"The board's stackup as the SI solver sees it (defaults filled in, with notes)."
function si_stack(board::BoardData, layers::Vector{String} = copper_layers(board))
    notes = String[]
    items = StackItem[]
    phys = [s for s in board.stackup if s.kind in ("copper", "core", "prepreg") || startswith(s.name, "dielectric") ||
            occursin("Solder Mask", s.kind)]
    cu_in = [s.name for s in phys if s.kind == "copper"]
    if !isempty(phys) && all(l -> l in cu_in, layers)
        for s in phys
            if s.kind == "copper"
                t = s.thickness > 0 ? s.thickness : 0.035
                push!(items, StackItem(s.name, :copper, t, 1.0, 0.0, false))
            elseif occursin("Solder Mask", s.kind)
                er = s.epsilon_r > 0 ? s.epsilon_r : DEFAULT_MASK_ER
                push!(items, StackItem(s.name, :mask, s.thickness > 0 ? s.thickness : DEFAULT_MASK_T, er, s.loss_tangent, false))
            else
                er = s.epsilon_r
                if er <= 0
                    er = DEFAULT_ER
                    push!(notes, "$(s.name): no εr in the stackup, assuming $DEFAULT_ER.")
                end
                s.thickness > 0 || push!(notes, "$(s.name): zero thickness in the stackup.")
                push!(items, StackItem(s.name, :dielectric, s.thickness, er, s.loss_tangent, s.kind == "prepreg"))
            end
        end
        return SIStack(items, [i.name for i in items if i.kind == :copper], true, notes)
    end
    # no (usable) stackup: nominal 1.6 mm FR-4 with evenly spread layers
    n = length(layers)
    push!(notes, "No board stackup defined (KiCad: Board Setup → Board Stackup). Assuming a nominal 1.6 mm FR-4 " *
                 "board (εr $DEFAULT_ER, 35 µm copper, evenly spaced layers): impedances are rough estimates.")
    td = n > 1 ? (1.6 - 0.035n) / (n - 1) : 1.565
    push!(items, StackItem("F.Mask", :mask, DEFAULT_MASK_T, DEFAULT_MASK_ER, 0.0, false))
    for (i, l) in enumerate(layers)
        push!(items, StackItem(l, :copper, 0.035, 1.0, 0.0, false))
        i < n && push!(items, StackItem("dielectric $i", :dielectric, td, DEFAULT_ER, 0.02, isodd(i)))
    end
    push!(items, StackItem("B.Mask", :mask, DEFAULT_MASK_T, DEFAULT_MASK_ER, 0.0, false))
    return SIStack(items, copy(layers), false, notes)
end

"Depth (mm from the top surface of the stack) of the top and bottom of each item."
function depths(items)
    d = 0.0
    top = Float64[]; bot = Float64[]
    for it in items
        push!(top, d); d += it.t; push!(bot, d)
    end
    return top, bot
end

"Mid-plane depth of each copper layer (for via lengths)."
function cu_depth(stk::SIStack)
    top, bot = depths(stk.items)
    return Dict(it.name => (top[i] + bot[i]) / 2 for (i, it) in enumerate(stk.items) if it.kind == :copper)
end

"Average dielectric εr (used where no reference plane defines the field)."
function avg_er(stk::SIStack)
    ds = [it for it in stk.items if it.kind == :dielectric && it.t > 0]
    isempty(ds) && return DEFAULT_ER
    return sum(it.εr * it.t for it in ds) / sum(it.t for it in ds)
end

"""
Cross-section of a trace (or pair, gap > 0) of width `w` on layer `L` with reference planes
`ra` (above) / `rb` (below) ("" = none) and coplanar ground gaps `cpw` (NaN = none).
Returns (CrossSection, kind) or (nothing, :none).
"""
function build_xs(stk::SIStack, L::String, ra::String, rb::String, w::Float64; gap::Float64 = NaN, cpw::Float64 = NaN)
    (isempty(ra) && isempty(rb)) && return nothing, :none
    items = stk.items
    if isempty(rb)                         # only a plane above: flip so the reference is below
        items = reverse(items)
        ra, rb = rb, ra
    end
    iL = findfirst(it -> it.name == L, items)
    ib = findfirst(it -> it.name == rb, items)
    ia = isempty(ra) ? 0 : findfirst(it -> it.name == ra, items)
    (iL === nothing || ib === nothing || ia === nothing) && return nothing, :none
    # y = 0 at the top of the lower plane; walk upward
    y = 0.0
    slabs = Slab[]
    yL0 = yL1 = NaN
    coat_t, coat_er, coat_s = 0.0, 1.0, NaN
    outer = true                           # is the trace layer's upper side open (outer layer)?
    for k in (ib - 1):-1:(ia + 1)
        it = items[k]
        it.t > 0 || continue
        if it.kind == :copper
            if k == iL
                yL0, yL1 = y, y + it.t
                outer = ia == 0 && all(items[q].kind == :mask || items[q].t == 0 for q in 1:k-1)
                if outer
                    if k > 1 && items[k-1].kind == :mask
                        coat_t, coat_er, coat_s = items[k-1].t, items[k-1].εr, y
                    end
                else
                    push!(slabs, Slab(y, y + it.t, fill_er(items, k)))
                end
            else
                open_above = ia == 0 && all(items[q].kind == :mask || items[q].t == 0 for q in 1:k-1)
                if !open_above
                    push!(slabs, Slab(y, y + it.t, fill_er(items, k)))
                elseif k > 1 && items[k-1].kind == :mask       # bare outer copper band: solder mask fills it
                    push!(slabs, Slab(y, y + it.t, items[k-1].εr))
                end
            end
        elseif it.kind == :mask
            # the mask on the trace's own surface is modelled as a conformal coat above
            (coat_t > 0 && abs(coat_s - yL0) < 1e-12) || push!(slabs, Slab(y, y + it.t, it.εr))
        else
            push!(slabs, Slab(y, y + it.t, it.εr))
        end
        y += it.t
    end
    isnan(yL0) && return nothing, :none
    plane_top = ia == 0 ? nothing : y
    hw = isnan(gap) ? w / 2 : w + gap / 2
    conds = isnan(gap) ? [Conductor(-w / 2, w / 2, yL0, yL1)] :
                         [Conductor(-gap / 2 - w, -gap / 2, yL0, yL1), Conductor(gap / 2, gap / 2 + w, yL0, yL1)]
    grounds = Conductor[]
    if !isnan(cpw)
        far = 20 * max(yL0, 0.1)
        push!(grounds, Conductor(-hw - cpw - far, -hw - cpw, yL0, yL1), Conductor(hw + cpw, hw + cpw + far, yL0, yL1))
    end
    xs = CrossSection(slabs = slabs, conductors = conds, grounds = grounds, plane_bottom = 0.0, plane_top = plane_top,
                      coat_t = coat_t, coat_εr = coat_er, coat_surface = coat_s)
    kind = plane_top !== nothing ? :stripline : outer ? :microstrip : :embedded
    return xs, kind
end

"εr of the resin that fills a copper layer's gaps: the adjacent prepreg, else the dielectric above."
function fill_er(items, k)
    for q in (k - 1, k + 1)
        1 <= q <= length(items) && items[q].kind == :dielectric && items[q].prepreg && return items[q].εr
    end
    for q in (k - 1, k + 1)
        1 <= q <= length(items) && items[q].kind == :dielectric && return items[q].εr
    end
    return DEFAULT_ER
end

const SI_KIND_LABEL = Dict(:microstrip => "microstrip", :stripline => "stripline", :embedded => "embedded microstrip",
                           :none => "no reference")

# ─────────────────────────────────────────────────────────────────────────────
# Reference plane maps
# ─────────────────────────────────────────────────────────────────────────────
struct PlaneMaps
    grid::Grid
    layers::Vector{String}
    nets::Vector{String}                 # index → reference net name
    cov::Vector{Matrix{Int32}}           # per layer: reference net index (holes patched), 0 = none
    edges::Vector{Dict{Tuple{Int,Int},Vector{NTuple{4,Float64}}}}   # per layer: fill outline edges, 1 mm buckets
end

const EDGE_BUCKET = 1.0

function build_plane_maps(board::BoardData, setup::SimSetup, layers::Vector{String}, cfg::SISettings)
    refnets = sort!([n for n in board.nets if netclass(setup, n) in (:power, :ground)])
    netidx = Dict(n => Int32(i) for (i, n) in enumerate(refnets))
    lidx = Dict(l => i for (i, l) in enumerate(layers))
    bx0, bx1, by0, by1 = board_extent(board)
    mg = 1.0
    bx0 -= mg; by0 -= mg; bx1 += mg; by1 += mg
    W, H = bx1 - bx0, by1 - by0
    h = cfg.cell_mm > 0 ? cfg.cell_mm : clamp(max(W, H) / 2500, 0.03, 0.1)
    while ceil(W / h) * ceil(H / h) * length(layers) > 40_000_000
        h *= 1.25
    end
    g = Grid(bx0, by0, h, ceil(Int, W / h), ceil(Int, H / h))
    cov = [zeros(Int32, g.nx, g.ny) for _ in layers]
    edges = [Dict{Tuple{Int,Int},Vector{NTuple{4,Float64}}}() for _ in layers]
    for z in board.zones
        ni = get(netidx, z.net_name, Int32(0)); ni == 0 && continue
        li = get(lidx, z.layer, 0); li == 0 && continue
        for poly in z.fills
            xs, ys = [p.x for p in poly], [p.y for p in poly]
            fill_polygon!(cov[li], g, xs, ys, ni)
            n = length(xs)
            for i in 1:n
                k = i == n ? 1 : i + 1
                e = (xs[i], ys[i], xs[k], ys[k])
                for bx in floor(Int, min(e[1], e[3]) / EDGE_BUCKET):floor(Int, max(e[1], e[3]) / EDGE_BUCKET),
                    by in floor(Int, min(e[2], e[4]) / EDGE_BUCKET):floor(Int, max(e[2], e[4]) / EDGE_BUCKET)
                    push!(get!(edges[li], (bx, by), NTuple{4,Float64}[]), e)
                end
            end
        end
    end
    maxcells = max(1, round(Int, cfg.hole_mm2 / h^2))
    foreach(M -> patch_holes!(M, maxcells), cov)
    return PlaneMaps(g, layers, refnets, cov, edges)
end

"Fill uncovered islands of at most `maxcells` cells that don't touch the border with a neighbouring net."
function patch_holes!(M::Matrix{Int32}, maxcells::Int)
    nx, ny = size(M)
    seen = falses(nx, ny)
    comp = Tuple{Int,Int}[]
    stack = Tuple{Int,Int}[]
    for j0 in 1:ny, i0 in 1:nx
        (M[i0, j0] == 0 && !seen[i0, j0]) || continue
        empty!(comp); empty!(stack)
        push!(stack, (i0, j0)); seen[i0, j0] = true
        border = false
        fillnet = Int32(0)
        while !isempty(stack)
            i, j = pop!(stack)
            length(comp) <= maxcells && push!(comp, (i, j))
            (i == 1 || j == 1 || i == nx || j == ny) && (border = true)
            for (a, b) in ((i + 1, j), (i - 1, j), (i, j + 1), (i, j - 1))
                (1 <= a <= nx && 1 <= b <= ny) || continue
                v = M[a, b]
                if v != 0
                    fillnet == 0 && (fillnet = v)
                elseif !seen[a, b]
                    seen[a, b] = true
                    push!(stack, (a, b))
                end
            end
        end
        if !border && length(comp) <= maxcells && fillnet != 0
            for (i, j) in comp
                M[i, j] = fillnet
            end
        end
    end
    return M
end

covered(pm::PlaneMaps, li, x, y) = (c = cell_index(pm.grid, x, y); inbounds(pm.grid, c...) ? pm.cov[li][c...] : Int32(0))

"Nearest reference above / below layer index `k` at (x, y): (la, na, lb, nb), 0 = none."
function refcfg(pm::PlaneMaps, k::Int, x, y)
    la = na = lb = nb = 0
    for a in (k - 1):-1:1
        v = covered(pm, a, x, y)
        v != 0 && (la = a; na = Int(v); break)
    end
    for b in (k + 1):length(pm.layers)
        v = covered(pm, b, x, y)
        v != 0 && (lb = b; nb = Int(v); break)
    end
    return (la, na, lb, nb)
end

"Distance from (x, y) along unit direction (dx, dy) to the nearest reference-fill edge on layer li (≤ rmax), or Inf."
function raycast(pm::PlaneMaps, li, x, y, dx, dy, rmax)
    best = Inf
    ex, ey = x + dx * rmax, y + dy * rmax
    for bx in floor(Int, min(x, ex) / EDGE_BUCKET):floor(Int, max(x, ex) / EDGE_BUCKET),
        by in floor(Int, min(y, ey) / EDGE_BUCKET):floor(Int, max(y, ey) / EDGE_BUCKET)
        for (x1, y1, x2, y2) in get(pm.edges[li], (bx, by), ())
            ux, uy = x2 - x1, y2 - y1
            den = dx * uy - dy * ux
            abs(den) < 1e-12 && continue
            wx, wy = x1 - x, y1 - y
            t = (wx * uy - wy * ux) / den
            s = (wx * dy - wy * dx) / den
            (0 <= s <= 1 && 0 < t < best) && (best = t)
        end
    end
    return best <= rmax ? best : Inf
end

# ─────────────────────────────────────────────────────────────────────────────
# Result types
# ─────────────────────────────────────────────────────────────────────────────
"A piece of a trace with a constant cross-section."
struct SIPiece
    net::String
    layer::String
    xa::Float64; ya::Float64; xb::Float64; yb::Float64
    w::Float64
    len::Float64                # mm
    kind::Symbol                # :microstrip, :stripline, :embedded, :none
    ref::String                 # "In1.Cu GND / In2.Cu +3V3" style description
    Z0::Float64                 # single-ended Ω (NaN: no reference)
    Zdiff::Float64              # pair Ω when coupled (NaN otherwise)
    gap::Float64                # pair gap mm (NaN: uncoupled)
    cpw::Float64                # coplanar ground gap mm (NaN: none)
    delay::Float64              # s/m
    target::Float64             # Ω the relevant impedance is checked against (NaN: none)
    tol::Float64                # %
end

"The impedance a piece is judged by: Zdiff when it is a coupled pair piece, else Z0."
impedance_of(p::SIPiece) = isnan(p.Zdiff) ? p.Z0 : p.Zdiff

struct NetSI
    net::String
    pair::String                # pair name, "" if none
    length::Float64             # mm, traces + via transitions
    via_len::Float64            # mm of that in via barrels
    nvias::Int
    delay::Float64              # s
    layers::Vector{String}
    zmin::Float64; zmax::Float64; zavg::Float64     # single-ended Z0 (Ω), length-weighted mean
    target::Float64             # Ω (single-ended or pair) or NaN
    viol_len::Float64           # mm outside the target tolerance (runs ≥ z_min_len)
    max_stub::Float64           # mm
end

struct PairSI
    name::String
    p::String
    n::String
    len_p::Float64; len_n::Float64
    skew::Float64               # mm, |len_p − len_n|
    delay_skew::Float64         # s
    coupled::Float64            # fraction of the length that runs coupled
    zd_min::Float64; zd_max::Float64; zd_avg::Float64
    target::Float64; tol::Float64
    skew_ok::Bool
    z_ok::Bool
end

struct GroupSI
    name::String
    by::Symbol
    tol::Float64
    members::Vector{Tuple{String,Float64,Float64}}     # (net, length mm, delay s)
    spread::Float64             # mm or ps
    ok::Bool
end

struct SIIssue
    kind::Symbol                # :noref, :gap, :split, :return_via, :stitch_cap, :z, :skew, :group, :stub
    severity::Symbol            # :error, :warning, :info
    net::String
    layer::String
    x::Float64; y::Float64      # the worst location (NaN: not located)
    text::String
    spots::Vector{Tuple{Float64,Float64}}    # every location (3D markers)
end
SIIssue(kind, sev, net, layer, x, y, text) = SIIssue(kind, sev, net, layer, x, y, text, isnan(x) ? Tuple{Float64,Float64}[] : [(x, y)])

"A unique cross-section used on the board (the impedance table)."
struct XSRow
    layer::String
    kind::Symbol
    ref::String
    w::Float64
    gap::Float64
    cpw::Float64
    Z0::Float64
    Zdiff::Float64
    εeff::Float64
    delay::Float64              # s/m
    len::Float64                # mm of trace using it
end

struct SIResult
    ok::Bool
    messages::Vector{String}
    seconds::Float64
    settings::SISettings
    stack::SIStack
    layers::Vector{String}
    pieces::Vector{SIPiece}
    nets::Vector{NetSI}
    pairs::Vector{PairSI}
    groups::Vector{GroupSI}
    issues::Vector{SIIssue}
    xsecs::Vector{XSRow}
    nxs_solved::Int
end

# ─────────────────────────────────────────────────────────────────────────────
# Solver
# ─────────────────────────────────────────────────────────────────────────────
const SAMPLE_MM = 0.2
q(x, d) = isnan(x) ? NaN : round(x / d) * d          # quantize (cache keys, piece merging)

struct SegIndex
    buckets::Dict{Tuple{Int,Int,String},Vector{Int}}   # (bx, by, layer) → trace indices
end
const SEG_BUCKET = 2.0
function SegIndex(traces::Vector{Trace}, keep)
    d = Dict{Tuple{Int,Int,String},Vector{Int}}()
    for (i, t) in enumerate(traces)
        keep(t) || continue
        x0, x1 = minmax(t.start_pt.x, t.end_pt.x)
        y0, y1 = minmax(t.start_pt.y, t.end_pt.y)
        for bx in floor(Int, x0 / SEG_BUCKET):floor(Int, x1 / SEG_BUCKET), by in floor(Int, y0 / SEG_BUCKET):floor(Int, y1 / SEG_BUCKET)
            push!(get!(d, (bx, by, t.layer), Int[]), i)
        end
    end
    return SegIndex(d)
end

"""
    solve_si(board, setup; settings, log) -> SIResult
"""
function solve_si(board::BoardData, setup::SimSetup; settings::SISettings = si_settings(setup), log = (s -> nothing))
    t0 = time()
    cfg = settings
    msgs = String[]
    layers = copper_layers(board)
    L = length(layers)
    lidx = Dict(l => i for (i, l) in enumerate(layers))
    stk = si_stack(board, layers)
    append!(msgs, stk.notes)
    zdep = cu_depth(stk)
    εavg = avg_er(stk)

    signal(n) = !isempty(n) && netclass(setup, n) ∉ (:power, :ground) && !startswith(n, "unconnected-")
    sig_traces = [t for t in board.traces if signal(t.net_name) && t.width > 0 && haskey(lidx, t.layer)]
    signets = sort!(unique([t.net_name for t in sig_traces]))
    if isempty(signets)
        return SIResult(false, vcat(msgs, ["No routed signal nets (all routed nets are classified Power or Ground)."]),
                        time() - t0, cfg, stk, layers, SIPiece[], NetSI[], PairSI[], GroupSI[], SIIssue[], XSRow[], 0)
    end
    any(netclass(setup, n) == :ground for n in board.nets) ||
        push!(msgs, "No net is classified Ground: reference planes can't be identified (Nets tab).")

    log(@sprintf("[si] %d signal nets, %d trace segments, %d copper layers", length(signets), length(sig_traces), L))
    pm = build_plane_maps(board, setup, layers, cfg)
    log(@sprintf("[si] reference planes rasterized (%d × %d cells of %.3f mm, %d reference nets)",
                 pm.grid.nx, pm.grid.ny, pm.grid.h, length(pm.nets)))
    any(any(!=(0), M) for M in pm.cov) ||
        push!(msgs, "No filled Power/Ground pours found: return paths and impedances can't be computed. Refill zones (B) and save.")

    pairs = find_diff_pairs(signets)
    partner = Dict{String,String}()
    pairname = Dict{String,String}()
    for (nm, p, n) in pairs
        partner[p] = n; partner[n] = p
        pairname[p] = nm; pairname[n] = nm
    end
    targets = si_targets(setup)
    function target_for(net)
        hit = nothing
        for t in targets
            if t.mode == :diff
                haskey(pairname, net) || continue
                (globmatch(t.pattern, pairname[net]) || globmatch(t.pattern, net) ||
                 globmatch(t.pattern, partner[net])) && (hit = t)
            else
                globmatch(t.pattern, net) && (hit = t)
            end
        end
        return hit
    end
    sidx = SegIndex(sig_traces, t -> haskey(partner, t.net_name))
    groupdefs = si_groups(setup)
    "High-speed / controlled nets get full severity; findings on other nets are informational unless large."
    critical(net) = target_for(net) !== nothing || haskey(partner, net) ||
                    any(g -> any(pt -> globmatch(pt, net), g.patterns), groupdefs)

    # ── cross-section cache
    cache = Dict{Any,Any}()
    nsolved = Ref(0)
    function xs_params(Lname, ra, rb, w, gap, cpw)
        key = (Lname, ra, rb, q(w, 1e-3), q(gap, 5e-3), q(cpw, 1e-2))
        get!(cache, key) do
            xs, kind = build_xs(stk, Lname, ra, rb, key[4]; gap = key[5], cpw = key[6])
            xs === nothing && return (kind = :none, Z0 = NaN, Zdiff = NaN, εeff = εavg, delay = sqrt(εavg) / C0_LIGHT)
            nsolved[] += 1
            if isnan(gap)
                p = line_params(solve_extrapolated(xs))
                (kind = kind, Z0 = p.Z0, Zdiff = NaN, εeff = p.εeff, delay = p.delay)
            else
                r = solve_extrapolated(xs)
                pp = pair_params(r)
                (kind = kind, Z0 = pp.Zodd, Zdiff = pp.Zdiff, εeff = pp.εeff_odd, delay = pp.delay_odd)
            end
        end
    end

    # height of the nearest reference (for coupling / coplanar search radii)
    function ref_height(k, cf)
        la, _, lb, _ = cf
        hs = Float64[]
        la > 0 && push!(hs, abs(zdep[layers[k]] - zdep[layers[la]]))
        lb > 0 && push!(hs, abs(zdep[layers[k]] - zdep[layers[lb]]))
        return isempty(hs) ? 0.2 : minimum(hs)
    end
    refdesc(cf) = join(filter(!isempty, [cf[1] > 0 ? "$(layers[cf[1]]) $(pm.nets[cf[2]])" : "",
                                         cf[3] > 0 ? "$(layers[cf[3]]) $(pm.nets[cf[4]])" : ""]), " / ")

    # ── sample every signal trace
    pieces = SIPiece[]
    samples_by_netlayer = Dict{Tuple{String,Int},Dict{NTuple{4,Int},Float64}}()   # majority reference config
    seg_samples = Vector{Vector{Tuple{Float64,Float64,NTuple{4,Int}}}}(undef, length(sig_traces))
    for (si, t) in enumerate(sig_traces)
        k = lidx[t.layer]
        ax, ay, bx, by = t.start_pt.x, t.start_pt.y, t.end_pt.x, t.end_pt.y
        len = hypot(bx - ax, by - ay)
        seg_samples[si] = Tuple{Float64,Float64,NTuple{4,Int}}[]
        len < 1e-6 && continue
        ux, uy = (bx - ax) / len, (by - ay) / len
        nx_, ny_ = -uy, ux
        m = max(1, ceil(Int, len / SAMPLE_MM))
        w = t.width
        mate = get(partner, t.net_name, "")
        runs = Any[]                       # (s0, s1, key)
        tally = get!(samples_by_netlayer, (t.net_name, k), Dict{NTuple{4,Int},Float64}())
        for i in 1:m
            s = (i - 0.5) / m * len
            x, y = ax + ux * s, ay + uy * s
            cf = refcfg(pm, k, x, y)
            push!(seg_samples[si], (x, y, cf))
            tally[cf] = get(tally, cf, 0.0) + len / m
            hr = ref_height(k, cf)
            # differential partner alongside?
            gap = NaN
            side = 0.0                     # +1: partner on the +normal side
            if !isempty(mate)
                reach = max(3w, 2hr) + w
                best = Inf
                for bxk in floor(Int, (x - reach) / SEG_BUCKET):floor(Int, (x + reach) / SEG_BUCKET),
                    byk in floor(Int, (y - reach) / SEG_BUCKET):floor(Int, (y + reach) / SEG_BUCKET)
                    for j in get(sidx.buckets, (bxk, byk, t.layer), ())
                        u = sig_traces[j]
                        u.net_name == mate || continue
                        vx, vy = u.end_pt.x - u.start_pt.x, u.end_pt.y - u.start_pt.y
                        lv = hypot(vx, vy); lv < 1e-6 && continue
                        abs(ux * vx + uy * vy) / lv > 0.985 || continue
                        τ = ((x - u.start_pt.x) * vx + (y - u.start_pt.y) * vy) / lv
                        -0.05 <= τ <= lv + 0.05 || continue
                        d = abs((x - u.start_pt.x) * vy - (y - u.start_pt.y) * vx) / lv
                        g = d - (w + u.width) / 2
                        if 0 < g < best
                            best = g
                            px, py = u.start_pt.x + vx * τ / lv - x, u.start_pt.y + vy * τ / lv - y
                            side = sign(px * nx_ + py * ny_)
                        end
                    end
                end
                best <= max(3w, 2hr) && (gap = best)
            end
            # coplanar ground pour beside the trace (outer side of a pair)
            cpw = NaN
            if cf != (0, 0, 0, 0)
                gmax = min(2hr, 1.0)
                if isnan(gap)
                    g = min(raycast(pm, k, x, y, nx_, ny_, w / 2 + gmax), raycast(pm, k, x, y, -nx_, -ny_, w / 2 + gmax)) - w / 2
                else             # pair: the pour on the side away from the partner sets the outer gap
                    g = raycast(pm, k, x, y, -side * nx_, -side * ny_, w / 2 + gmax) - w / 2
                end
                g < gmax && (cpw = g)
            end
            key = (cf, q(gap, 5e-3), q(cpw, 1e-2))
            s0, s1 = (i - 1) / m * len, i / m * len
            if !isempty(runs) && isequal(runs[end][3], key)
                runs[end] = (runs[end][1], s1, key)
            else
                push!(runs, (s0, s1, key))
            end
        end
        tgt = target_for(t.net_name)
        for (s0, s1, key) in runs
            cf, gap, cpw = key
            ra = cf[1] > 0 ? layers[cf[1]] : ""
            rb = cf[3] > 0 ? layers[cf[3]] : ""
            xp = xs_params(t.layer, ra, rb, w, gap, cpw)
            tz = tgt === nothing ? NaN : (tgt.mode == :diff && isnan(gap)) ? NaN : tgt.z
            tol = tgt === nothing ? cfg.z_tol_pct : (isnan(tgt.tol_pct) ? cfg.z_tol_pct : tgt.tol_pct)
            push!(pieces, SIPiece(t.net_name, t.layer, ax + ux * s0, ay + uy * s0, ax + ux * s1, ay + uy * s1, w, s1 - s0,
                                  xp.kind, refdesc(cf), isnan(gap) ? xp.Z0 : NaN, xp.Zdiff, gap, cpw, xp.delay, tz, tol))
        end
    end
    log(@sprintf("[si] %d trace pieces, %d unique cross-sections solved", length(pieces), nsolved[]))

    issues = SIIssue[]

    # ── return path: runs that differ from the net's usual reference on that layer
    major = Dict(kl => findmax(d)[2] for (kl, d) in samples_by_netlayer)
    terminals = Dict{Tuple{String,Int},Vector{NTuple{3,Float64}}}()    # (net, layer) → (x, y, r) of its vias / pads
    for v in board.vias
        signal(v.net_name) || continue
        for k in 1:L
            push!(get!(terminals, (v.net_name, k), NTuple{3,Float64}[]), (v.pos.x, v.pos.y, v.size / 2))
        end
    end
    for c in board.components, pd in c.pads
        signal(pd.net_name) || continue
        x, y = pad_center(c, pd)
        for k in 1:L
            pad_on(pd.layers, layers[k]) && push!(get!(terminals, (pd.net_name, k), NTuple{3,Float64}[]),
                                                  (x, y, max(pd.size_x, pd.size_y) / 2))
        end
    end
    near_terminal(net, k, x, y) = any(hypot(x - tx, y - ty) <= tr + 0.3 for (tx, ty, tr) in get(terminals, (net, k), ()))
    runs_by = Dict{Any,Vector{Tuple{Float64,Float64,Float64}}}()      # (kind, net, layer, detail) → (x, y, len)
    for (si, t) in enumerate(sig_traces)
        k = lidx[t.layer]
        smp = seg_samples[si]
        isempty(smp) && continue
        mj = major[(t.net_name, k)]
        ax, ay = t.start_pt.x, t.start_pt.y
        len = hypot(t.end_pt.x - ax, t.end_pt.y - ay)
        ux, uy = (t.end_pt.x - ax) / len, (t.end_pt.y - ay) / len
        step = len / length(smp)
        i = 1
        while i <= length(smp)
            cf = smp[i][3]
            if cf == mj
                i += 1
                continue
            end
            j = i
            while j < length(smp) && smp[j+1][3] == cf
                j += 1
            end
            runlen = (j - i + 1) * step
            s0, s1 = (i - 1) * step, j * step
            fan = runlen <= cfg.fanout_mm && (near_terminal(t.net_name, k, ax + ux * s0, ay + uy * s0) ||
                                              near_terminal(t.net_name, k, ax + ux * s1, ay + uy * s1))
            if !fan
                mid = smp[(i + j) ÷ 2]
                key = if cf == (0, 0, 0, 0)
                    (:noref, t.net_name, k, "")
                elseif (cf[1] == mj[1] && cf[1] > 0 && cf[2] != mj[2]) || (cf[3] == mj[3] && cf[3] > 0 && cf[4] != mj[4])
                    sd = (cf[1] == mj[1] && cf[1] > 0 && cf[2] != mj[2]) ? 1 : 3
                    (:split, t.net_name, k, "$(layers[cf[sd]]): $(pm.nets[mj[sd+1]]) → $(pm.nets[cf[sd+1]])")
                else
                    lost = (mj[1] > 0 && cf[1] != mj[1]) ? 1 : 3
                    mj[lost] > 0 ? (:gap, t.net_name, k, "$(layers[mj[lost]]) $(pm.nets[mj[lost+1]])") :
                                   (:gap, t.net_name, k, refdesc(cf))
                end
                push!(get!(runs_by, key, Tuple{Float64,Float64,Float64}[]), (mid[1], mid[2], runlen))
            end
            i = j + 1
        end
    end
    for ((kind, net, k, detail), rs) in runs_by
        tot = sum(r[3] for r in rs)
        w = rs[argmax([r[3] for r in rs])]
        many = length(rs) == 1 ? @sprintf("%.1f mm", tot) : @sprintf("%d places, %.1f mm in total, longest %.1f mm", length(rs), tot, w[3])
        txt = kind == :noref ? "$net runs on $(layers[k]) with no reference plane ($many)" :
              kind == :split ? "$net on $(layers[k]) crosses a plane split, reference $detail ($many)" :
                               "$net on $(layers[k]) crosses a gap or edge in the $detail plane ($many)"
        sev = critical(net) ? ((kind == :noref && tot >= cfg.z_min_len_mm) ? :error : :warning) :
              (kind == :noref && w[3] > 5.0) ? :warning : :info
        push!(issues, SIIssue(kind, sev, net, layers[k], w[1], w[2], txt, [(r[1], r[2]) for r in rs]))
    end

    # ── vias: transitions, return vias, stubs
    span(v::Via) = (ls = [lidx[l] for l in v.layers if haskey(lidx, l)]; isempty(ls) ? (1, L) : (minimum(ls), maximum(ls)))
    sigvias = [v for v in board.vias if signal(v.net_name)]
    retpts = Dict{String,Vector{Tuple{Float64,Float64,Int,Int}}}()      # ref net → (x, y, layer span)
    for v in board.vias
        n = v.net_name
        netclass(setup, n) in (:power, :ground) || continue
        a, b = span(v)
        push!(get!(retpts, n, Tuple{Float64,Float64,Int,Int}[]), (v.pos.x, v.pos.y, a, b))
    end
    for c in board.components, p in c.pads
        netclass(setup, p.net_name) in (:power, :ground) || continue
        (p.pad_type == "thru_hole" && any(l -> l == "*.Cu", p.layers)) || continue
        x, y = pad_center(c, p)
        push!(get!(retpts, p.net_name, Tuple{Float64,Float64,Int,Int}[]), (x, y, 1, L))
    end
    caps = Tuple{Float64,Float64,String,String}[]                       # stitching capacitors between reference nets
    for c in board.components
        startswith(uppercase(c.ref), "C") || continue
        ns = unique([p.net_name for p in c.pads if netclass(setup, p.net_name) in (:power, :ground)])
        length(ns) == 2 || continue
        x, y = c.pos.x, c.pos.y
        push!(caps, (x, y, ns[1], ns[2]))
    end
    vias_on = Dict{String,Vector{Tuple{Float64,Float64,Float64,Int}}}()  # net → (via len, stub, x, layers used)
    for v in sigvias
        r = max(v.size / 2, 0.05) + 0.02
        used = Set{Int}()
        for t in sig_traces
            t.net_name == v.net_name || continue
            (hypot(t.start_pt.x - v.pos.x, t.start_pt.y - v.pos.y) <= r ||
             hypot(t.end_pt.x - v.pos.x, t.end_pt.y - v.pos.y) <= r) && push!(used, lidx[t.layer])
        end
        isempty(used) && continue
        a, b = span(v)
        lo, hi = minimum(used), maximum(used)
        vlen = abs(zdep[layers[hi]] - zdep[layers[lo]])
        stub = max(abs(zdep[layers[b]] - zdep[layers[hi]]), abs(zdep[layers[lo]] - zdep[layers[a]]))
        push!(get!(vias_on, v.net_name, Tuple{Float64,Float64,Float64,Int}[]), (vlen, stub, 0.0, length(used)))
        length(used) >= 2 || continue
        # reference planes of each used layer at the via
        refs = Dict(k => (cf = refcfg(pm, k, v.pos.x, v.pos.y);
                          Set(p for p in ((cf[1], cf[2]), (cf[3], cf[4])) if p[1] > 0)) for k in used)
        any(isempty, values(refs)) && continue           # handled by the no-reference checks
        isempty(intersect(values(refs)...)) || continue  # a shared plane carries the return current
        ks = sort!(collect(used))
        for i in 1:length(ks)-1
            ka, kb = ks[i], ks[i+1]
            RA, RB = refs[ka], refs[kb]
            isempty(intersect(RA, RB)) || continue
            best = Inf
            bestnet = ""
            shared = intersect(Set(n for (_, n) in RA), Set(n for (_, n) in RB))
            for (la, na) in RA, (lb, nb) in RB
                na == nb || continue
                n = pm.nets[na]
                for (x, y, s0, s1) in get(retpts, n, ())
                    (s0 <= min(la, lb) && s1 >= max(la, lb)) || continue
                    d = hypot(x - v.pos.x, y - v.pos.y)
                    d < best && (best = d; bestnet = n)
                end
            end
            refa, refb = join(sort!(["$(layers[l]) $(pm.nets[n])" for (l, n) in RA]), "+"),
                         join(sort!(["$(layers[l]) $(pm.nets[n])" for (l, n) in RB]), "+")
            sev = critical(v.net_name) ? :warning : :info
            if !isempty(shared)
                # same reference net on both sides: the return current needs a via of that net close by
                best <= cfg.return_via_mm && continue
                txt = isfinite(best) ?
                    @sprintf("%s via at (%.2f, %.2f) changes reference %s → %s; nearest %s return via is %.2f mm away (≤ %.1f mm recommended)",
                             v.net_name, v.pos.x, v.pos.y, refa, refb, bestnet, best, cfg.return_via_mm) :
                    @sprintf("%s via at (%.2f, %.2f) changes reference %s → %s with no %s via joining those planes",
                             v.net_name, v.pos.x, v.pos.y, refa, refb, pm.nets[first(shared)])
                push!(issues, SIIssue(:return_via, sev, v.net_name, layers[ka], v.pos.x, v.pos.y, txt))
            else
                # different reference nets: the return current crosses through a capacitor
                nets_a = Set(pm.nets[n] for (_, n) in RA); nets_b = Set(pm.nets[n] for (_, n) in RB)
                dc = minimum((hypot(x - v.pos.x, y - v.pos.y) for (x, y, n1, n2) in caps
                              if (n1 in nets_a && n2 in nets_b) || (n2 in nets_a && n1 in nets_b)); init = Inf)
                dc <= cfg.stitch_cap_mm && continue
                push!(issues, SIIssue(:stitch_cap, sev, v.net_name, layers[ka], v.pos.x, v.pos.y,
                                      @sprintf("%s via at (%.2f, %.2f) changes reference %s → %s (different nets) with no stitching capacitor within %.1f mm",
                                               v.net_name, v.pos.x, v.pos.y, refa, refb, cfg.stitch_cap_mm)))
            end
        end
    end

    # ── nets
    bynet = Dict{String,Vector{SIPiece}}()
    for p in pieces
        push!(get!(bynet, p.net, SIPiece[]), p)
    end
    nets = NetSI[]
    netlen = Dict{String,Float64}()
    netdelay = Dict{String,Float64}()
    for n in signets
        ps = get(bynet, n, SIPiece[])
        tl = sum(p.len for p in ps; init = 0.0)
        vs = get(vias_on, n, Tuple{Float64,Float64,Float64,Int}[])
        vl = sum(v[1] for v in vs; init = 0.0)
        delay = sum(p.len * 1e-3 * p.delay for p in ps; init = 0.0) + vl * 1e-3 * sqrt(εavg) / C0_LIGHT
        zs = [(p.Z0, p.len) for p in ps if !isnan(p.Z0)]
        zmin = isempty(zs) ? NaN : minimum(first, zs)
        zmax = isempty(zs) ? NaN : maximum(first, zs)
        zavg = isempty(zs) ? NaN : sum(z * l for (z, l) in zs) / sum(l for (_, l) in zs)
        tgt = target_for(n)
        # target violations: runs of consecutive out-of-tolerance pieces (per segment order)
        viol = 0.0
        worst = nothing
        for p in ps
            isnan(p.target) && continue
            z = impedance_of(p)
            isnan(z) && continue
            dev = abs(z - p.target) / p.target * 100
            dev > p.tol || continue
            p.len >= cfg.z_min_len_mm || continue
            viol += p.len
            (worst === nothing || dev > worst[1]) && (worst = (dev, p, z))
        end
        if worst !== nothing
            _, p, z = worst
            push!(issues, SIIssue(:z, :warning, n, p.layer, (p.xa + p.xb) / 2, (p.ya + p.yb) / 2,
                                  @sprintf("%s: %s %.1f Ω vs target %.0f Ω ±%.0f%% (%.1f mm out of tolerance, %s, w %.3f mm%s)",
                                           n, isnan(p.Zdiff) ? "Z0" : "Zdiff", z, p.target, p.tol, viol, p.layer, p.w,
                                           isnan(p.gap) ? "" : @sprintf(", gap %.3f mm", p.gap))))
        end
        maxstub = maximum((v[2] for v in vs); init = 0.0)
        if maxstub > cfg.stub_mm && (tgt !== nothing || haskey(partner, n))
            push!(issues, SIIssue(:stub, :info, n, "", NaN, NaN,
                                  @sprintf("%s: via stub of %.2f mm (back-drill or use a blind via for high-speed nets)", n, maxstub)))
        end
        push!(nets, NetSI(n, get(pairname, n, ""), tl + vl, vl, length(vs), delay, sort!(unique([p.layer for p in ps]); by = layer_sort_key),
                          zmin, zmax, zavg, tgt === nothing ? NaN : tgt.z, viol, maxstub))
        netlen[n] = tl + vl
        netdelay[n] = delay
    end

    # ── pairs
    pres = PairSI[]
    for (nm, p, n) in pairs
        (haskey(netlen, p) && haskey(netlen, n)) || continue
        ps = vcat(get(bynet, p, SIPiece[]), get(bynet, n, SIPiece[]))
        tot = sum(x.len for x in ps; init = 0.0)
        cp = [(x.Zdiff, x.len) for x in ps if !isnan(x.Zdiff)]
        cl = sum(l for (_, l) in cp; init = 0.0)
        zd = isempty(cp) ? (NaN, NaN, NaN) : (minimum(first, cp), maximum(first, cp), sum(z * l for (z, l) in cp) / cl)
        tgt = target_for(p)
        tz = tgt === nothing || tgt.mode != :diff ? NaN : tgt.z
        tol = tgt === nothing || isnan(tgt.tol_pct) ? cfg.z_tol_pct : tgt.tol_pct
        skew = abs(netlen[p] - netlen[n])
        skew_ok = skew <= cfg.pair_skew_mm
        z_ok = isnan(tz) || all(abs(x.Zdiff - tz) / tz * 100 <= tol || x.len < cfg.z_min_len_mm for x in ps if !isnan(x.Zdiff))
        push!(pres, PairSI(nm, p, n, netlen[p], netlen[n], skew, abs(netdelay[p] - netdelay[n]), tot > 0 ? cl / tot : 0.0,
                           zd..., tz, tol, skew_ok, z_ok))
        skew_ok || push!(issues, SIIssue(:skew, :warning, p, "", NaN, NaN,
                                         @sprintf("Pair %s: intra-pair skew %.3f mm (%.1f ps), limit %.3f mm", nm, skew,
                                                  abs(netdelay[p] - netdelay[n]) * 1e12, cfg.pair_skew_mm)))
    end

    # ── length-match groups
    gres = GroupSI[]
    for g in groupdefs
        mem = [(n, netlen[n], netdelay[n]) for n in signets if any(pt -> globmatch(pt, n), g.patterns)]
        if isempty(mem)
            push!(msgs, "Group $(g.name): no routed net matches $(join(g.patterns, ", ")).")
            push!(gres, GroupSI(g.name, g.by, g.tol, mem, NaN, false))
            continue
        end
        vals = g.by == :delay ? [m[3] * 1e12 for m in mem] : [m[2] for m in mem]
        spread = maximum(vals) - minimum(vals)
        ok = spread <= g.tol
        push!(gres, GroupSI(g.name, g.by, g.tol, sort!(mem; by = m -> -m[2]), spread, ok))
        ok || push!(issues, SIIssue(:group, :warning, mem[argmin(vals)][1], "", NaN, NaN,
                                    @sprintf("Group %s: %s spread %.3f %s (limit %.3f), shortest %s", g.name,
                                             g.by == :delay ? "delay" : "length", spread, g.by == :delay ? "ps" : "mm",
                                             g.tol, mem[argmin(vals)][1])))
    end

    # ── impedance table
    rows = Dict{Any,XSRow}()
    for p in pieces
        key = (p.layer, p.ref, q(p.w, 1e-3), q(p.gap, 5e-3), q(p.cpw, 1e-2))
        if haskey(rows, key)
            r = rows[key]
            rows[key] = XSRow(r.layer, r.kind, r.ref, r.w, r.gap, r.cpw, r.Z0, r.Zdiff, r.εeff, r.delay, r.len + p.len)
        else
            εeff = (p.delay * C0_LIGHT)^2
            rows[key] = XSRow(p.layer, p.kind, p.ref, key[3], key[4], key[5], p.Z0, p.Zdiff, εeff, p.delay, p.len)
        end
    end
    xsecs = sort!(collect(values(rows)); by = r -> -r.len)

    sevrank(s) = s == :error ? 0 : s == :warning ? 1 : 2
    sort!(issues; by = i -> (sevrank(i.severity), i.kind, i.net))
    secs = time() - t0
    log(@sprintf("[si] done in %.1f s: %d issue(s)", secs, length(issues)))
    return SIResult(true, msgs, secs, cfg, stk, layers, pieces, nets, pres, gres, issues, xsecs, nsolved[])
end

# ─────────────────────────────────────────────────────────────────────────────
# Reporting helpers
# ─────────────────────────────────────────────────────────────────────────────
fmtz(z) = isnan(z) ? "—" : @sprintf("%.1f Ω", z)

function si_summary_lines(r::SIResult)
    r.ok || return vcat(["SI analysis failed:"], r.messages)
    out = String[]
    ne = count(i -> i.severity == :error, r.issues)
    nw = count(i -> i.severity == :warning, r.issues)
    ni = count(i -> i.severity == :info, r.issues)
    push!(out, @sprintf("SI: %d nets, %d pairs, %d cross-sections, %.1f s — %d error(s), %d warning(s), %d note(s)",
                        length(r.nets), length(r.pairs), r.nxs_solved, r.seconds, ne, nw, ni))
    for p in r.pairs
        push!(out, @sprintf("  pair %-24s Zdiff %s (%s … %s)%s  skew %.3f mm %s  coupled %.0f%%", p.name, fmtz(p.zd_avg),
                            fmtz(p.zd_min), fmtz(p.zd_max), isnan(p.target) ? "" : @sprintf(" target %.0f Ω %s", p.target, p.z_ok ? "✓" : "✗"),
                            p.skew, p.skew_ok ? "✓" : "✗", 100p.coupled))
    end
    important = [i for i in r.issues if i.severity != :info]
    for i in first(important, 12)
        push!(out, "  " * uppercase(string(i.severity)) * ": " * i.text)
    end
    length(important) > 12 && push!(out, "  … $(length(important) - 12) more (see the SI tab)")
    return out
end

"Lines describing one net (inspector)."
function si_net_report(r::SIResult, net::AbstractString)
    i = findfirst(n -> n.net == net, r.nets)
    i === nothing && return String[]
    n = r.nets[i]
    out = [@sprintf("Length %.2f mm (%d via%s, %.2f mm in vias) · delay %.1f ps", n.length, n.nvias, n.nvias == 1 ? "" : "s",
                    n.via_len, n.delay * 1e12),
           "Layers " * join(n.layers, ", "),
           @sprintf("Z0 %s … %s (avg %s)", fmtz(n.zmin), fmtz(n.zmax), fmtz(n.zavg))]
    isnan(n.target) || push!(out, @sprintf("Target %.0f Ω: %s", n.target, n.viol_len > 0 ? @sprintf("%.1f mm out of tolerance", n.viol_len) : "met ✓"))
    if !isempty(n.pair)
        j = findfirst(p -> p.name == n.pair, r.pairs)
        if j !== nothing
            p = r.pairs[j]
            push!(out, @sprintf("Pair %s: Zdiff %s, skew %.3f mm (%.1f ps), %.0f%% coupled", p.name, fmtz(p.zd_avg), p.skew,
                                p.delay_skew * 1e12, 100p.coupled))
        end
    end
    n.max_stub > 0.01 && push!(out, @sprintf("Longest via stub %.2f mm", n.max_stub))
    return out
end

end # module
