module PDNMesh

# Circuit mesh of the board's power-delivery copper, shared by the DC and AC solvers.
#
#   • Pours, planes and pads are rasterized per copper layer on a square grid (cell h);
#     neighbouring same-net cells are joined by a "plane" branch.
#   • Traces are 1-D branches between the copper (or junction) at their ends, subdivided.
#   • Vias and plated through-hole pads are "barrel" branches between consecutive layers.
#   • Elements hook onto their pads through ideal "tie" branches: VRM (Rout), series
#     R / L / ferrite / 0 Ω, and (AC only) capacitors. Sinks are recorded as pad groups.
#
# Each branch keeps what a solver needs to compute its impedance: kind, layer, length,
# width or drill, element index, and its DC conductance.

using Printf
using ..BoardParser: BoardData, Component, Pad
using ..Geometry
using ..SimSetups

export Grid, Mesh, build_mesh, cell_index, inbounds, fill_polygon!, BR_PLANE, BR_TRACE, BR_BARREL, BR_TIE,
       BR_VRM, BR_SERIES, BR_CAP, SERIES_KINDS, G_TIE

const BR_PLANE, BR_TRACE, BR_BARREL, BR_TIE, BR_VRM, BR_SERIES, BR_CAP = UInt8.(1:7)
const SERIES_KINDS = (:resistor, :inductor, :ferrite, :short)
const G_TIE = 1e5                    # S: pin-to-pad tie (effectively ideal)

# ─────────────────────────────────────────────────────────────────────────────
# Grid and rasterization
# ─────────────────────────────────────────────────────────────────────────────
struct Grid
    x0::Float64
    y0::Float64
    h::Float64
    nx::Int
    ny::Int
end
cell_index(g::Grid, x, y) = (floor(Int, (x - g.x0) / g.h) + 1, floor(Int, (y - g.y0) / g.h) + 1)
inbounds(g::Grid, i, j) = 1 <= i <= g.nx && 1 <= j <= g.ny

"Set every cell whose centre is inside polygon (xs, ys) (even-odd rule) to `val`; optionally collect the cells."
function fill_polygon!(M::Matrix{Int32}, g::Grid, xs, ys, val::Int32, cells = nothing)
    n = length(xs)
    n < 3 && return M
    ymin, ymax = extrema(ys)
    j0 = max(1, ceil(Int, (ymin - g.y0) / g.h + 0.5))
    j1 = min(g.ny, floor(Int, (ymax - g.y0) / g.h + 0.5))
    xsect = Float64[]
    for j in j0:j1
        yc = g.y0 + (j - 0.5) * g.h
        empty!(xsect)
        k = n
        for i in 1:n
            yi, yk = ys[i], ys[k]
            if (yi > yc) != (yk > yc)
                push!(xsect, xs[i] + (yc - yi) * (xs[k] - xs[i]) / (yk - yi))
            end
            k = i
        end
        sort!(xsect)
        for q in 1:2:length(xsect)-1
            i0 = max(1, ceil(Int, (xsect[q] - g.x0) / g.h + 0.5))
            i1 = min(g.nx, floor(Int, (xsect[q+1] - g.x0) / g.h + 0.5))
            for i in i0:i1
                M[i, j] = val
                cells === nothing || push!(cells, (i, j))
            end
        end
    end
    return M
end

"A point that must be a circuit node (pad / via centre on a layer): a grid cell, or a standalone node."
mutable struct Anchor
    layer::Int
    x::Float64
    y::Float64
    net::Int32
    i::Int            # grid cell (0 → standalone, e.g. the cell belongs to another net)
    j::Int
    node::Int
end

function anchor!(anchors, netcell, g, li, x, y, ni::Int32)
    i, j = cell_index(g, x, y)
    a = if inbounds(g, i, j) && (netcell[li][i, j] == 0 || netcell[li][i, j] == ni)
        netcell[li][i, j] = ni
        Anchor(li, x, y, ni, i, j, 0)
    else
        Anchor(li, x, y, ni, 0, 0, 0)
    end
    push!(anchors, a)
    return a
end

# ─────────────────────────────────────────────────────────────────────────────
# Mesh
# ─────────────────────────────────────────────────────────────────────────────
mutable struct Mesh
    grid::Grid
    layers::Vector{String}
    zcu::Dict{String,Float64}
    tmm::Vector{Float64}                  # copper thickness per layer (mm)
    ρ::Float64                            # resistivity used for EG (Ω·m)
    nets::Vector{String}
    netidx::Dict{String,Int32}
    netcell::Vector{Matrix{Int32}}        # net index per cell (0: none)
    nodeid::Vector{Matrix{Int32}}         # node per cell (0: none)
    node_net::Vector{Int32}
    ngrid::Int                            # nodes 1:ngrid are grid cells
    nn::Int                               # total nodes
    # branches (parallel arrays)
    EA::Vector{Int}
    EB::Vector{Int}
    EK::Vector{UInt8}                     # BR_* kind
    EG::Vector{Float64}                   # DC conductance (0 for capacitors)
    EL::Vector{Int16}                     # layer (plane / trace)
    EP1::Vector{Float32}                  # trace: length mm   · barrel: length mm
    EP2::Vector{Float32}                  # trace: width mm    · barrel: drill mm
    EE::Vector{Int32}                     # element index into `elems` (VRM / series / cap)
    tsegs::Vector{NamedTuple}             # trace pieces (for display)
    viasegs::Vector{NamedTuple}           # barrels (for reporting)
    elems::Vector{Element}
    vrm_t::Vector{NamedTuple}             # (e, tp, tn, branch)
    sink_t::Vector{NamedTuple}            # (e, P, N)
    series_t::Vector{NamedTuple}          # (e, ta, tb, branch)
    cap_t::Vector{NamedTuple}             # (e, ta, tb, branch)
    messages::Vector{String}
end

function edge!(m::Mesh, a, b, g, kind; layer = 0, p1 = 0, p2 = 0, elem = 0)
    push!(m.EA, a); push!(m.EB, b); push!(m.EG, g); push!(m.EK, kind)
    push!(m.EL, Int16(layer)); push!(m.EP1, Float32(p1)); push!(m.EP2, Float32(p2)); push!(m.EE, Int32(elem))
    return length(m.EA)
end

newnode!(m::Mesh, ni) = (m.nn += 1; push!(m.node_net, Int32(ni)); m.nn)

"""
    build_mesh(board, setup; h, ρ, cu_thickness_um, plating_um, include_caps, log) -> Mesh

`h` is the cell size in mm (0 = automatic with `auto_div` cells over the board's long side).
Simulated nets: VRM / sink terminal nets, grown through series elements. With
`include_caps`, capacitors between simulated nets are hooked up too.
"""
function build_mesh(board::BoardData, setup::SimSetup; h::Float64 = 0.0, auto_div::Real = 400, h_min = 0.05, h_max = 0.5,
                    ρ::Float64, cu_thickness_um::Float64 = 0.0, plating_um::Float64 = 25.0,
                    include_caps::Bool = false, max_cells::Int = 4_000_000, tag::String = "[mesh]", log = (s -> nothing))
    msgs = String[]
    kinds = include_caps ? (:vrm, :sink, :capacitor, SERIES_KINDS...) : (:vrm, :sink, SERIES_KINDS...)
    elems = [e for e in setup.elements if e.kind in kinds]
    compidx = Dict(c.ref => i for (i, c) in enumerate(board.components))

    netset = Set{String}()
    for e in elems, n in (e.net_pos, e.net_neg)
        e.kind in (:vrm, :sink) && !isempty(n) && push!(netset, n)
    end
    grow = true
    while grow
        grow = false
        for e in elems
            (e.kind in SERIES_KINDS && !isempty(e.net_pos) && !isempty(e.net_neg)) || continue
            a, b = e.net_pos in netset, e.net_neg in netset
            if a != b
                push!(netset, a ? e.net_neg : e.net_pos)
                grow = true
            end
        end
    end
    nets = sort!(collect(netset))
    netidx = Dict(n => Int32(i) for (i, n) in enumerate(nets))

    layers = copper_layers(board)
    L = length(layers)
    lidx = Dict(l => i for (i, l) in enumerate(layers))
    zcu, _, _ = stack_geometry(board, layers)
    tmm = [cu_thickness_um > 0 ? cu_thickness_um / 1000 : copper_thickness(board, l) for l in layers]
    σ = 1 / ρ

    bx0, bx1, by0, by1 = board_extent(board)
    mg = 0.5
    bx0 -= mg; by0 -= mg; bx1 += mg; by1 += mg
    W, H = bx1 - bx0, by1 - by0
    hh = h > 0 ? h : clamp(round(max(W, H) / auto_div; digits = 3), h_min, h_max)
    while ceil(W / hh) * ceil(H / hh) * L > max_cells
        hh *= 1.25
    end
    g = Grid(bx0, by0, hh, ceil(Int, W / hh), ceil(Int, H / hh))
    log(@sprintf("%s grid %d × %d cells × %d layers, cell %.3f mm", tag, g.nx, g.ny, L, hh))
    isempty(nets) || log("$tag nets: " * join(nets, ", "))

    # ── rasterize pours, pads, via pads
    netcell = [zeros(Int32, g.nx, g.ny) for _ in 1:L]
    anchors = Anchor[]
    for z in board.zones
        ni = get(netidx, z.net_name, Int32(0)); ni == 0 && continue
        li = get(lidx, z.layer, 0); li == 0 && continue
        if isempty(z.fills)
            push!(msgs, "Zone on $(z.layer) ($(z.net_name)) has no fill data: refill zones (B) in KiCad and save.")
            continue
        end
        for poly in z.fills
            fill_polygon!(netcell[li], g, [p.x for p in poly], [p.y for p in poly], ni)
        end
    end

    padrec = Dict{Tuple{Int,Int},NamedTuple}()          # (component, pad) → (cells, anchors, drill)
    for (ci, c) in enumerate(board.components), (pi, p) in enumerate(c.pads)
        ni = get(netidx, p.net_name, Int32(0)); ni == 0 && continue
        cx, cy = pad_center(c, p)
        xs, ys = (p.size_x > 0 && p.size_y > 0) ? pad_polygon(c, p) : (Float64[], Float64[])
        cells = Tuple{Int,Int,Int}[]
        anc = Anchor[]
        for (li, ln) in enumerate(layers)
            pad_on(p.layers, ln) || continue
            tmp = Tuple{Int,Int}[]
            fill_polygon!(netcell[li], g, xs, ys, ni, tmp)
            append!(cells, ((li, i, j) for (i, j) in tmp))
            push!(anc, anchor!(anchors, netcell, g, li, cx, cy, ni))
        end
        isempty(anc) && continue
        padrec[(ci, pi)] = (cells = cells, anchors = anc, drill = 0.6 * min(p.size_x, p.size_y))
    end

    viarec = NamedTuple[]
    for v in board.vias
        ni = get(netidx, v.net_name, Int32(0)); ni == 0 && continue
        ids = [lidx[l] for l in v.layers if haskey(lidx, l)]
        isempty(ids) && continue
        lo, hi = extrema(ids)
        xs, ys = circle_polygon(v.pos.x, v.pos.y, v.size / 2)
        anc = Anchor[]
        for li in lo:hi
            fill_polygon!(netcell[li], g, xs, ys, ni)
            push!(anc, anchor!(anchors, netcell, g, li, v.pos.x, v.pos.y, ni))
        end
        push!(viarec, (x = v.pos.x, y = v.pos.y, net = ni, anchors = anc, drill = v.drill))
    end

    # ── number the nodes
    nodeid = [zeros(Int32, g.nx, g.ny) for _ in 1:L]
    node_net = Int32[]
    nn = 0
    for li in 1:L, j in 1:g.ny, i in 1:g.nx
        ni = netcell[li][i, j]
        ni == 0 && continue
        nn += 1
        nodeid[li][i, j] = nn
        push!(node_net, ni)
    end
    m = Mesh(g, layers, zcu, tmm, ρ, nets, netidx, netcell, nodeid, node_net, nn, nn,
             Int[], Int[], UInt8[], Float64[], Int16[], Float32[], Float32[], Int32[],
             NamedTuple[], NamedTuple[], elems, NamedTuple[], NamedTuple[], NamedTuple[], NamedTuple[], msgs)
    for a in anchors
        a.node = a.i > 0 ? Int(nodeid[a.layer][a.i, a.j]) : newnode!(m, a.net)
    end

    # ── plane branches
    for li in 1:L
        gs = σ * tmm[li] * 1e-3
        M, C = nodeid[li], netcell[li]
        for j in 1:g.ny, i in 1:g.nx
            a = M[i, j]
            a == 0 && continue
            i < g.nx && M[i+1, j] != 0 && C[i+1, j] == C[i, j] && edge!(m, a, M[i+1, j], gs, BR_PLANE; layer = li)
            j < g.ny && M[i, j+1] != 0 && C[i, j+1] == C[i, j] && edge!(m, a, M[i, j+1], gs, BR_PLANE; layer = li)
        end
    end

    # standalone pad anchors: tie them to the pad's own cells on that layer
    for rec in values(padrec), a in rec.anchors
        a.i == 0 || continue
        for (l, i, j) in rec.cells
            l == a.layer && nodeid[l][i, j] != 0 && edge!(m, a.node, nodeid[l][i, j], G_TIE, BR_TIE)
        end
    end

    # ── barrels (vias and plated pads)
    plate = plating_um / 1000
    function barrel_g(drill, dz)
        r = max(drill, 0.05) / 2
        t = min(plate, r)
        A = π * (r^2 - (r - t)^2)                            # mm²
        return (A * 1e-6) / (ρ * max(dz, 0.005) * 1e-3)
    end
    function barrels!(anc, drill, net, label, x, y)
        for k in 1:length(anc)-1
            a, b = anc[k], anc[k+1]
            dz = abs(zcu[layers[a.layer]] - zcu[layers[b.layer]])
            gv = barrel_g(drill, dz)
            bi = edge!(m, a.node, b.node, gv, BR_BARREL; p1 = max(dz, 0.005), p2 = max(drill, 0.05))
            push!(m.viasegs, (label = label, x = x, y = y, net = net, la = a.layer, lb = b.layer, a = a.node, b = b.node, branch = bi))
        end
    end
    for vr in viarec
        barrels!(vr.anchors, vr.drill, vr.net, "via", vr.x, vr.y)
    end
    for ((ci, pi), rec) in padrec
        length(rec.anchors) > 1 || continue
        c = board.components[ci]
        barrels!(sort(rec.anchors; by = a -> a.layer), rec.drill, rec.anchors[1].net,
                 "pad $(c.ref).$(c.pads[pi].pad_num)", rec.anchors[1].x, rec.anchors[1].y)
    end

    # ── traces: 1-D branches, subdivided for display
    junction = Dict{Tuple{Int,Int,Int},Int}()
    function endpoint(li, x, y, ni)
        i, j = cell_index(g, x, y)
        inbounds(g, i, j) && netcell[li][i, j] == ni && return Int(nodeid[li][i, j])
        return get!(() -> newnode!(m, ni), junction, (li, round(Int, x * 1e4), round(Int, y * 1e4)))
    end
    for t in board.traces
        ni = get(netidx, t.net_name, Int32(0)); ni == 0 && continue
        li = get(lidx, t.layer, 0); li == 0 && continue
        xa, ya, xb, yb = t.start_pt.x, t.start_pt.y, t.end_pt.x, t.end_pt.y
        len = hypot(xb - xa, yb - ya)
        len < 1e-6 && continue
        w = max(t.width, 0.01)
        a, b = endpoint(li, xa, ya, ni), endpoint(li, xb, yb, ni)
        ns = max(1, ceil(Int, len / (3hh)))
        piece = len / ns
        gseg = (w * 1e-3) * (tmm[li] * 1e-3) / (ρ * piece * 1e-3)
        prev, px, py = a, xa, ya
        for k in 1:ns
            qx, qy = xa + (xb - xa) * k / ns, ya + (yb - ya) * k / ns
            nxt = k == ns ? b : newnode!(m, ni)
            edge!(m, prev, nxt, gseg, BR_TRACE; layer = li, p1 = piece, p2 = w)
            push!(m.tsegs, (layer = li, xa = px, ya = py, xb = qx, yb = qy, net = ni, w = w, a = prev, b = nxt, g = gseg))
            prev, px, py = nxt, qx, qy
        end
    end

    # ── elements
    function pad_nodes(ci, net)
        c = board.components[ci]
        side = get(lidx, c.layer, 0)
        nodes = Int[]
        for (pi, p) in enumerate(c.pads)
            p.net_name == net || continue
            rec = get(padrec, (ci, pi), nothing)
            rec === nothing && continue
            use = any(a -> a.layer == side, rec.anchors) ? (l -> l == side) : (l -> true)
            for (l, i, j) in rec.cells
                use(l) && nodeid[l][i, j] != 0 && push!(nodes, nodeid[l][i, j])
            end
            for a in rec.anchors
                use(a.layer) && push!(nodes, a.node)
            end
        end
        return unique!(nodes)
    end
    function nearest_pad_nodes(c, net)
        best, bd = nothing, Inf
        for (cj, c2) in enumerate(board.components), (pj, p) in enumerate(c2.pads)
            (p.net_name == net && haskey(padrec, (cj, pj))) || continue
            x, y = pad_center(c2, p)
            d = hypot(x - c.pos.x, y - c.pos.y)
            d < bd && ((bd, best) = (d, (cj, pj)))
        end
        best === nothing && return Int[], ""
        cj, pj = best
        return pad_nodes(cj, net), "$(board.components[cj].ref).$(board.components[cj].pads[pj].pad_num)"
    end
    function terminal(e, net, allow_nearest)
        ci = compidx[e.ref]
        nodes = pad_nodes(ci, net)
        if isempty(nodes) && allow_nearest
            nodes, lbl = nearest_pad_nodes(board.components[ci], net)
            isempty(nodes) || push!(msgs, "$(e.id): $(e.ref) has no pad on $net, attached at the nearest $net pad ($lbl).")
        end
        isempty(nodes) && push!(msgs, "$(e.id): no copper found for $net at $(e.ref); element skipped.")
        return nodes
    end
    function hook!(e, pos, neg)
        ta, tb = newnode!(m, netidx[e.net_pos]), newnode!(m, netidx[e.net_neg])
        foreach(k -> edge!(m, ta, k, G_TIE, BR_TIE), pos)
        foreach(k -> edge!(m, tb, k, G_TIE, BR_TIE), neg)
        return ta, tb
    end

    for (ei, e) in enumerate(elems)
        haskey(compidx, e.ref) || (push!(msgs, "$(e.id): component $(e.ref) not on the board; skipped."); continue)
        (isempty(e.net_pos) || isempty(e.net_neg)) && (push!(msgs, "$(e.id): terminal net not set; skipped."); continue)
        if !(e.net_pos in netset && e.net_neg in netset)
            e.kind == :capacitor || push!(msgs, "$(e.id): nets not simulated; skipped.")
            continue
        end
        if e.kind == :vrm
            P = terminal(e, e.net_pos, true); N = terminal(e, e.net_neg, true)
            (isempty(P) || isempty(N)) && continue
            tp, tn = hook!(e, P, N)
            bi = edge!(m, tp, tn, 1 / max(e.params["Rout"], 1e-6), BR_VRM; elem = ei)
            push!(m.vrm_t, (e = e, tp = tp, tn = tn, branch = bi))
        elseif e.kind == :sink
            P = terminal(e, e.net_pos, false); N = terminal(e, e.net_neg, false)
            (isempty(P) || isempty(N)) && continue
            push!(m.sink_t, (e = e, P = P, N = N))
        elseif e.kind == :capacitor
            A = terminal(e, e.net_pos, false); B = terminal(e, e.net_neg, false)
            (isempty(A) || isempty(B)) && continue
            ta, tb = hook!(e, A, B)
            bi = edge!(m, ta, tb, 0.0, BR_CAP; elem = ei)
            push!(m.cap_t, (e = e, ta = ta, tb = tb, branch = bi))
        else
            A = terminal(e, e.net_pos, false); B = terminal(e, e.net_neg, false)
            (isempty(A) || isempty(B)) && continue
            R = max(e.kind in (:resistor, :short) ? e.params["R"] : e.params["DCR"], 1e-6)
            ta, tb = hook!(e, A, B)
            bi = edge!(m, ta, tb, 1 / R, BR_SERIES; elem = ei)
            push!(m.series_t, (e = e, ta = ta, tb = tb, branch = bi))
        end
    end
    return m
end

end # module
