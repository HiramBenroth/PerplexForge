module DCSolver

# DC (IR-drop) power-integrity solver, on the shared copper mesh (see Mesh.jl).
#
#   • VRM: ideal V behind Rout (Norton form). Sink: current drawn evenly over the cells of
#     its + pads and returned over its − pads. Series R / L / ferrite / 0 Ω: DC resistance.
#     Capacitors are open at DC.
#   • Each connected circuit is referenced to its VRM's − terminal (0 V) and the sparse
#     conductance system is solved with a Cholesky factorization.

using SparseArrays
using LinearAlgebra
using Printf
using ..BoardParser: BoardData
using ..SimSetups
using ..PDNMesh

export DCSettings, DCResult, dc_settings, solve_dc, overlay_range, dc_probe, dc_summary_lines,
       DC_SETTING_SPECS, resistivity, default_rail, voltage_rails, voltage_map

const RHO_CU_20C = 1.72e-8          # Ω·m, PCB copper at 20 °C
const ALPHA_CU = 0.00393             # 1/K

Base.@kwdef struct DCSettings
    cell_mm::Float64 = 0.0           # grid cell size; 0 = automatic
    temperature_c::Float64 = 25.0
    via_plating_um::Float64 = 25.0
    cu_thickness_um::Float64 = 0.0   # 0 = use the board stackup (35 µm where missing)
end

"(key, label, unit, hint) for the editable settings."
const DC_SETTING_SPECS = [("cell_mm", "Cell size", "mm", "0 = auto"),
                          ("temperature_c", "Temperature", "°C", ""),
                          ("via_plating_um", "Via plating", "µm", ""),
                          ("cu_thickness_um", "Cu thickness", "µm", "0 = stackup")]

function dc_settings(s::SimSetup)
    g(k, def) = (x = get(s.dc, k, def); x isa Real ? Float64(x) : def)
    return DCSettings(cell_mm = g("cell_mm", 0.0), temperature_c = g("temperature_c", 25.0),
                      via_plating_um = g("via_plating_um", 25.0), cu_thickness_um = g("cu_thickness_um", 0.0))
end

resistivity(T) = RHO_CU_20C * (1 + ALPHA_CU * (T - 20))

# ─────────────────────────────────────────────────────────────────────────────
# Result
# ─────────────────────────────────────────────────────────────────────────────
struct DCResult
    ok::Bool
    messages::Vector{String}
    settings::DCSettings
    grid::Grid
    layers::Vector{String}
    thickness::Vector{Float64}             # mm per layer
    nets::Vector{String}
    nominal::Vector{Float64}               # per net (V), NaN if unknown
    netcell::Vector{Matrix{Int32}}
    node::Vector{Matrix{Int32}}
    v::Vector{Float64}                     # node voltages (NaN: not solved / floating)
    drop::Vector{Matrix{Float32}}          # |nominal − V| per cell, mV (NaN: no copper)
    jden::Vector{Matrix{Float32}}          # current density per cell, A/mm²
    traces::Vector{Any}                    # (layer, xa, ya, xb, yb, net, width, I, J, drop_a, drop_b, va, vb)
    vias::Vector{Any}                      # (label, x, y, net, layer_a, layer_b, I)
    vrms::Vector{Any}
    sinks::Vector{Any}
    series::Vector{Any}
    rails::Vector{Any}                     # per net: (net, nominal, vmin, vmax, maxdrop_mV)
    ploss::Float64                         # W dissipated in copper (planes, traces, vias)
    nnodes::Int
    seconds::Float64
end

failed(msgs, settings, t0) = DCResult(false, msgs, settings, Grid(0, 0, 1, 0, 0), String[], Float64[], String[], Float64[],
                                      Matrix{Int32}[], Matrix{Int32}[], Float64[], Matrix{Float32}[], Matrix{Float32}[],
                                      Any[], Any[], Any[], Any[], Any[], Any[], 0.0, 0, time() - t0)

# ─────────────────────────────────────────────────────────────────────────────
# Solver
# ─────────────────────────────────────────────────────────────────────────────
"""
    solve_dc(board, setup; settings = dc_settings(setup), log = s -> nothing) -> DCResult

Builds the resistive network for the nets used by the setup's VRMs, sinks and series
elements, solves it, and returns maps and per-element results. `log` receives progress lines.
"""
function solve_dc(board::BoardData, setup::SimSetup; settings::DCSettings = dc_settings(setup), log = (s -> nothing))
    t0 = time()
    any(e -> e.kind == :vrm, setup.elements) || return failed(["No VRM defined."], settings, t0)
    ρ = resistivity(settings.temperature_c)
    σ = 1 / ρ
    log(@sprintf("[dc] ρ = %.3g Ω·m (%.0f °C)", ρ, settings.temperature_c))
    m = build_mesh(board, setup; h = settings.cell_mm, ρ = ρ, cu_thickness_um = settings.cu_thickness_um,
                   plating_um = settings.via_plating_um, include_caps = false, tag = "[dc]", log = log)
    msgs = copy(m.messages)
    isempty(m.vrm_t) && return failed(vcat(msgs, ["No usable VRM (check its terminal nets)."]), settings, t0)
    g, layers, nets, netidx, nodeid, netcell, tmm = m.grid, m.layers, m.nets, m.netidx, m.nodeid, m.netcell, m.tmm
    L = length(layers)
    EA, EB, EG, EK = m.EA, m.EB, m.EG, m.EK
    N = m.nn

    # ── connected circuits; each needs a reference (its VRM − terminal = 0 V)
    parent = collect(1:N)
    function root(x)
        while parent[x] != x
            parent[x] = parent[parent[x]]
            x = parent[x]
        end
        return x
    end
    for k in eachindex(EA)
        EG[k] > 0 || continue
        ra, rb = root(EA[k]), root(EB[k])
        ra != rb && (parent[ra] = rb)
    end
    ref_of = Dict{Int,Int}()
    for t in m.vrm_t
        r = root(t.tn)
        haskey(ref_of, r) || (ref_of[r] = t.tn)
    end
    # sinks: draw current only from the pins whose copper actually reaches a VRM
    sinks_used = NamedTuple[]
    for t in m.sink_t
        P = [k for k in t.P if haskey(ref_of, root(k))]
        Nn = [k for k in t.N if haskey(ref_of, root(k))]
        if isempty(P) || isempty(Nn)
            push!(msgs, "$(t.e.id): no copper path from $(t.e.ref)'s $(isempty(P) ? t.e.net_pos : t.e.net_neg) pins to any VRM; it is ignored.")
            continue
        end
        (length(P) < length(t.P) || length(Nn) < length(t.N)) &&
            push!(msgs, "$(t.e.id): some of $(t.e.ref)'s pin copper isn't connected; its current is drawn from the connected pins only.")
        push!(sinks_used, (e = t.e, P = P, N = Nn))
    end

    # sources: VRM Norton currents, sink draws
    b = zeros(N)
    for t in m.vrm_t
        R, V = max(t.e.params["Rout"], 1e-6), t.e.params["V"]
        b[t.tp] += V / R
        b[t.tn] -= V / R
    end
    for t in sinks_used
        I = t.e.params["I"]
        foreach(k -> (b[k] -= I / length(t.P)), t.P)
        foreach(k -> (b[k] += I / length(t.N)), t.N)
    end
    newidx = zeros(Int, N)
    nk = 0
    floating = Set{Int}()
    for k in 1:N
        r = root(k)
        if haskey(ref_of, r)
            ref_of[r] != k && (nk += 1; newidx[k] = nk)
        elseif k <= m.ngrid
            push!(floating, r)
        end
    end
    isempty(floating) || push!(msgs, "$(length(floating)) copper island(s) of the simulated nets are not connected to a VRM and were left out.")

    Is = Int[]; Js = Int[]; Vs = Float64[]
    sizehint!(Is, 4length(EA)); sizehint!(Js, 4length(EA)); sizehint!(Vs, 4length(EA))
    for k in eachindex(EA)
        gk = EG[k]
        gk > 0 || continue
        a, c = newidx[EA[k]], newidx[EB[k]]
        a > 0 && (push!(Is, a); push!(Js, a); push!(Vs, gk))
        c > 0 && (push!(Is, c); push!(Js, c); push!(Vs, gk))
        if a > 0 && c > 0
            push!(Is, a); push!(Js, c); push!(Vs, -gk)
            push!(Is, c); push!(Js, a); push!(Vs, -gk)
        end
    end
    A = sparse(Is, Js, Vs, nk, nk)
    rhs = zeros(nk)
    for k in 1:N
        newidx[k] > 0 && (rhs[newidx[k]] = b[k])
    end
    log(@sprintf("[dc] %d unknowns (%d plane cells), %d conductances, built in %.2f s", nk, m.ngrid, length(EA), time() - t0))

    t1 = time()
    x = try
        cholesky(Symmetric(A)) \ rhs
    catch err
        err isa PosDefException || rethrow()
        push!(msgs, "Matrix not positive definite; used a general solver.")
        A \ rhs
    end
    log(@sprintf("[dc] solved in %.2f s", time() - t1))

    v = fill(NaN, N)
    for k in 1:N
        newidx[k] > 0 && (v[k] = x[newidx[k]])
    end
    for r in values(ref_of)
        v[r] = 0.0
    end

    # ── nominal rail voltages (VRM set points, propagated through series elements)
    nominal = fill(NaN, length(nets))
    for t in m.vrm_t
        isnan(nominal[netidx[t.e.net_pos]]) && (nominal[netidx[t.e.net_pos]] = t.e.params["V"])
        isnan(nominal[netidx[t.e.net_neg]]) && (nominal[netidx[t.e.net_neg]] = 0.0)
    end
    for (i, n) in enumerate(nets)
        isnan(nominal[i]) && netclass(setup, n) == :ground && (nominal[i] = 0.0)
    end
    grow = true
    while grow
        grow = false
        for t in m.series_t
            a, c = netidx[t.e.net_pos], netidx[t.e.net_neg]
            if isnan(nominal[a]) != isnan(nominal[c])
                isnan(nominal[a]) ? (nominal[a] = nominal[c]) : (nominal[c] = nominal[a])
                grow = true
            end
        end
    end

    # ── maps
    drop = [fill(NaN32, g.nx, g.ny) for _ in 1:L]
    jden = [fill(NaN32, g.nx, g.ny) for _ in 1:L]
    for li in 1:L
        M, C = nodeid[li], netcell[li]
        for j in 1:g.ny, i in 1:g.nx
            k = M[i, j]
            k == 0 && continue
            vk = v[k]
            isnan(vk) && continue
            nm = nominal[C[i, j]]
            isnan(nm) || (drop[li][i, j] = Float32(abs(nm - vk) * 1e3))
            gx = _grad(M, C, v, i, j, 1, 0, g)
            gy = _grad(M, C, v, i, j, 0, 1, g)
            jden[li][i, j] = Float32(σ * hypot(gx, gy) * 1e-3)        # V/mm → A/mm²
        end
    end
    dropv(k, ni) = (isnan(v[k]) || isnan(nominal[ni])) ? NaN32 : Float32(abs(nominal[ni] - v[k]) * 1e3)
    traces = Any[]
    for s in m.tsegs
        I = s.g * (v[s.a] - v[s.b])
        push!(traces, (layer = s.layer, xa = s.xa, ya = s.ya, xb = s.xb, yb = s.yb, net = nets[s.net], width = s.w,
                       I = I, J = abs(I) / (s.w * tmm[s.layer]), drop_a = dropv(s.a, s.net), drop_b = dropv(s.b, s.net),
                       va = Float32(v[s.a]), vb = Float32(v[s.b])))
    end
    vias = Any[]
    for s in m.viasegs
        push!(vias, (label = s.label, x = s.x, y = s.y, net = nets[s.net], layer_a = layers[s.la], layer_b = layers[s.lb],
                     I = EG[s.branch] * (v[s.a] - v[s.b])))
    end
    vrms = Any[]
    for t in m.vrm_t
        R, V = max(t.e.params["Rout"], 1e-6), t.e.params["V"]
        push!(vrms, (id = t.e.id, ref = t.e.ref, net_pos = t.e.net_pos, net_neg = t.e.net_neg, V = V,
                     vout = v[t.tp] - v[t.tn], I = (V - (v[t.tp] - v[t.tn])) / R))
    end
    mean(xs) = sum(xs) / length(xs)
    sinks = Any[]
    for t in sinks_used
        vp, vn = mean(v[t.P]), mean(v[t.N])
        nneg = nominal[netidx[t.e.net_neg]]
        nom = nominal[netidx[t.e.net_pos]] - (isnan(nneg) ? 0.0 : nneg)
        push!(sinks, (id = t.e.id, ref = t.e.ref, net_pos = t.e.net_pos, net_neg = t.e.net_neg, I = t.e.params["I"],
                      vpos = vp, vneg = vn, v = vp - vn, worst = minimum(v[t.P]) - maximum(v[t.N]), nominal = nom,
                      drop_mV = (nom - (vp - vn)) * 1e3, pct = 100 * (nom - (vp - vn)) / nom))
    end
    series = Any[]
    for t in m.series_t
        R = 1 / EG[t.branch]
        push!(series, (id = t.e.id, ref = t.e.ref, kind = t.e.kind, net_pos = t.e.net_pos, net_neg = t.e.net_neg,
                       R = R, I = (v[t.ta] - v[t.tb]) / R, vdrop = v[t.ta] - v[t.tb]))
    end
    rails = Any[]
    for (i, n) in enumerate(nets)
        vs = [v[k] for k in 1:N if m.node_net[k] == i && !isnan(v[k])]
        isempty(vs) && continue
        lo, hi = extrema(vs)
        nm = nominal[i]
        push!(rails, (net = n, nominal = nm, vmin = lo, vmax = hi,
                      maxdrop_mV = isnan(nm) ? NaN : 1e3 * max(abs(nm - lo), abs(nm - hi))))
    end
    ploss = 0.0
    for k in eachindex(EA)
        EK[k] in (BR_PLANE, BR_TRACE, BR_BARREL) || continue
        d = v[EA[k]] - v[EB[k]]
        isnan(d) || (ploss += EG[k] * d^2)
    end
    secs = time() - t0
    log(@sprintf("[dc] done in %.2f s", secs))
    return DCResult(true, msgs, settings, g, layers, tmm, nets, nominal, netcell, nodeid, v, drop, jden,
                    traces, vias, vrms, sinks, series, rails, ploss, N, secs)
end

"Voltage gradient (V/mm) along (di, dj) at a cell, using same-net neighbours."
function _grad(M, C, v, i, j, di, dj, g)
    nx, ny = size(M)
    c = C[i, j]
    ok(ii, jj) = 1 <= ii <= nx && 1 <= jj <= ny && M[ii, jj] != 0 && C[ii, jj] == c && !isnan(v[M[ii, jj]])
    fwd, bwd = ok(i + di, j + dj), ok(i - di, j - dj)
    if fwd && bwd
        return (v[M[i+di, j+dj]] - v[M[i-di, j-dj]]) / (2g.h)
    elseif fwd
        return (v[M[i+di, j+dj]] - v[M[i, j]]) / g.h
    elseif bwd
        return (v[M[i, j]] - v[M[i-di, j-dj]]) / g.h
    end
    return 0.0
end

# ─────────────────────────────────────────────────────────────────────────────
# Helpers for display
# ─────────────────────────────────────────────────────────────────────────────
"The rail shown by default in the voltage view: the first VRM's + net."
default_rail(r::DCResult) = isempty(r.vrms) ? (isempty(r.nets) ? "" : r.nets[1]) : r.vrms[1].net_pos

"Rails that can be shown in the voltage view (default rail first)."
voltage_rails(r::DCResult) = sort([x.net for x in r.rails]; by = n -> (n == default_rail(r) ? 0 : 1, n))

"Node voltage (V) of every cell of `net` on layer `li` (NaN elsewhere)."
function voltage_map(r::DCResult, li::Int, net::AbstractString)
    ni = findfirst(==(net), r.nets)
    out = fill(NaN32, r.grid.nx, r.grid.ny)
    ni === nothing && return out
    M, C = r.node[li], r.netcell[li]
    for j in 1:r.grid.ny, i in 1:r.grid.nx
        k = M[i, j]
        (k != 0 && C[i, j] == ni) && (out[i, j] = Float32(r.v[k]))
    end
    return out
end

"""
Colour range (lo, hi) for an overlay mode: \"Voltage\" (V, for rail `net`, up to its nominal),
\"IR drop\" (mV) or \"Current density\" (A/mm²).
"""
function overlay_range(r::DCResult, mode::AbstractString; net::AbstractString = default_rail(r))
    vals = Float32[]
    if mode == "Voltage"
        i = findfirst(x -> x.net == net, r.rails)
        i === nothing && return (0f0, 1f0)
        rl = r.rails[i]
        lo, hi = rl.vmin, isnan(rl.nominal) ? rl.vmax : max(rl.vmax, rl.nominal)
        hi - lo < 1e-9 && (lo -= 1e-6; hi += 1e-6)
        return (Float32(lo), Float32(hi))
    elseif mode == "IR drop"
        for M in r.drop, x in M
            isnan(x) || push!(vals, x)
        end
        for t in r.traces, x in (t.drop_a, t.drop_b)
            isnan(x) || push!(vals, x)
        end
        hi = isempty(vals) ? 1f0 : maximum(vals)
    else
        for M in r.jden, x in M
            isnan(x) || push!(vals, x)
        end
        for t in r.traces
            push!(vals, Float32(t.J))
        end
        # current crowds at pins/vias; clip the extreme tail so the plane is readable
        hi = isempty(vals) ? 1f0 : sort!(vals)[clamp(ceil(Int, 0.995 * length(vals)), 1, length(vals))]
    end
    return (0f0, max(hi, 1f-6))
end

"Values at a point on a layer: (net, V, drop_mV, J) or nothing."
function dc_probe(r::DCResult, layer::AbstractString, x, y)
    r.ok || return nothing
    li = findfirst(==(layer), r.layers)
    li === nothing && return nothing
    i, j = cell_index(r.grid, x, y)
    inbounds(r.grid, i, j) || return nothing
    k = r.node[li][i, j]
    (k == 0 || isnan(r.v[k])) && return nothing
    return (net = r.nets[r.netcell[li][i, j]], V = r.v[k], drop_mV = r.drop[li][i, j], J = r.jden[li][i, j])
end

"Human-readable summary for the console."
function dc_summary_lines(r::DCResult)
    out = String[]
    r.ok || return ["DC analysis failed:"; ["  " * m for m in r.messages]]
    push!(out, @sprintf("Solved %d nodes in %.2f s (cell %.3f mm). Copper loss %s.", r.nnodes, r.seconds, r.grid.h,
                        format_si(r.ploss, "W")))
    for t in r.vrms
        push!(out, @sprintf("VRM  %-6s %-5s %s → %s: %s out, %s at its pads", t.id, t.ref, t.net_pos, t.net_neg,
                            format_si(t.I, "A"), format_si(t.vout, "V"; digits = 5)))
    end
    for s in r.sinks
        push!(out, @sprintf("Sink %-6s %-5s %s: %s at pins (−%.2f mV, %.3f%%), worst pin %s", s.id, s.ref, s.net_pos,
                            format_si(s.v, "V"; digits = 5), s.drop_mV, s.pct, format_si(s.worst, "V"; digits = 5)))
    end
    for s in r.series
        push!(out, @sprintf("%-4s %-6s %s → %s: %s, %s across", uppercase(string(s.kind))[1:min(4, end)], s.id, s.net_pos,
                            s.net_neg, format_si(s.I, "A"), format_si(s.vdrop, "V")))
    end
    if !isempty(r.vias)
        top = sort(r.vias; by = x -> -abs(x.I))[1]
        push!(out, @sprintf("Highest barrel current: %s at (%.2f, %.2f) %s %s→%s: %s", top.label, top.x, top.y, top.net,
                            top.layer_a, top.layer_b, format_si(abs(top.I), "A")))
    end
    append!(out, ["Note: " * m for m in r.messages])
    return out
end

end # module
