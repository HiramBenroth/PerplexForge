module ACSolver

# AC power-delivery-network impedance solver (frequency sweep), on the shared copper mesh.
#
# Every branch of the mesh gets a complex impedance:
#   plane cell    R_□(f) + jω·L_□       R_□ = ρ/t_eff (skin effect), L_□ = μ0·d/2
#                                       (half the loop inductance of a plane pair spaced d;
#                                        the return plane carries the other half)
#   trace piece   R(f)·ℓ + jω·L′·ℓ      L′ from the microstrip formula over the nearest plane
#   via barrel    R(f) + jω·L_partial   partial self-inductance of a cylinder
#   VRM           Rout + jω·Lout
#   series parts  R | DCR + jω·L
#   capacitor     ESR + jω·ESL + 1/(jω·C)
# plus plane-pair capacitance ε0·εr·h²/d (with dielectric loss tanδ) wherever cells of two
# different simulated nets overlap on adjacent copper layers.
#
# Each sink is a port: 1 A is driven into its + pads and out of its − pads, and
# Z(f) = mean V(+) − mean V(−). One LU factorization per frequency serves all ports.

using SparseArrays
using LinearAlgebra
using Printf
using ..BoardParser: BoardData
using ..SimSetups
using ..PDNMesh
using ..DCSolver: resistivity, dc_settings

export ACSettings, ACResult, ac_settings, solve_ac, ac_map, ac_summary_lines, AC_SETTING_SPECS, target_violations

const μ0 = 4π * 1e-7
const ε0 = 8.8541878128e-12

Base.@kwdef struct ACSettings
    f_start::Float64 = 1e3
    f_stop::Float64 = 1e9
    points_per_decade::Float64 = 10
    cell_mm::Float64 = 0.0           # 0 = automatic (about 120 cells across the board)
end

"(key, label, unit, hint) for the editable settings (values accept SI suffixes, e.g. 1k, 1G)."
const AC_SETTING_SPECS = [("f_start", "Start", "Hz", ""),
                          ("f_stop", "Stop", "Hz", ""),
                          ("points_per_decade", "Points/dec", "", ""),
                          ("cell_mm", "Cell size", "mm", "0 = auto")]

function ac_settings(s::SimSetup)
    g(k, def) = (x = get(s.ac, k, def); x isa Real ? Float64(x) : def)
    return ACSettings(f_start = g("f_start", 1e3), f_stop = g("f_stop", 1e9),
                      points_per_decade = g("points_per_decade", 10.0), cell_mm = g("cell_mm", 0.0))
end

struct ACResult
    ok::Bool
    messages::Vector{String}
    settings::ACSettings
    freqs::Vector{Float64}
    ports::Vector{Any}                     # (id, ref, net_pos, net_neg, Z, target, vnom)
    grid::Grid
    layers::Vector{String}
    nets::Vector{String}
    netcell::Vector{Matrix{Int32}}
    node::Vector{Matrix{Int32}}
    solve_at::Function                     # (f, port index) → node voltages (Vector{ComplexF64}, NaN off-circuit)
    nnodes::Int
    nplanecaps::Int
    cplane::Float64                        # total plane-pair capacitance (F)
    seconds::Float64
    cache::Dict{Tuple{Int,Float64},Any}    # ac_map results
end

failed(msgs, settings, t0) = ACResult(false, msgs, settings, Float64[], Any[], Grid(0, 0, 1, 0, 0), String[], String[],
                                      Matrix{Int32}[], Matrix{Int32}[], (f, p) -> ComplexF64[], 0, 0, 0.0, time() - t0,
                                      Dict{Tuple{Int,Float64},Any}())

# ─────────────────────────────────────────────────────────────────────────────
# Physics helpers (SI units)
# ─────────────────────────────────────────────────────────────────────────────
skin_depth(ρ, f) = sqrt(ρ / (π * f * μ0))
"Effective conducting thickness of a conductor of thickness t at skin depth δ."
t_eff(t, δ) = δ * (1 - exp(-t / δ))

"Loop inductance per metre of a trace of width w at height d over a plane."
function trace_Lp(w, d)
    u = w / d
    return u <= 1 ? μ0 / (2π) * log(8 / u + u / 4) : μ0 / (u + 1.393 + 0.667 * log(u + 1.444))
end

"Partial self-inductance of a straight cylinder (via barrel) of length h and radius r."
barrel_L(h, r) = μ0 / (2π) * (h * log((h + sqrt(h^2 + r^2)) / r) - sqrt(h^2 + r^2) + r)

"Dielectric (thickness mm, εr, tanδ) between two adjacent copper layers, from the stackup."
function dielectric_between(board::BoardData, la, lb, zcu)
    names = [s.name for s in board.stackup]
    ia, ib = findfirst(==(la), names), findfirst(==(lb), names)
    if ia !== nothing && ib !== nothing
        lo, hi = minmax(ia, ib)
        t = et = tt = 0.0
        for s in board.stackup[lo+1:hi-1]
            s.thickness > 0 || continue
            t += s.thickness
            et += s.thickness * (s.epsilon_r > 0 ? s.epsilon_r : 4.5)
            tt += s.thickness * (s.loss_tangent > 0 ? s.loss_tangent : 0.02)
        end
        t > 0 && return (d = t, er = et / t, tand = tt / t)
    end
    return (d = max(abs(zcu[la] - zcu[lb]), 0.05), er = 4.5, tand = 0.02)
end

"Frequency ranges (lo, hi) where |Z| is above the target."
function target_violations(freqs, Z, target)
    bands = Tuple{Float64,Float64}[]
    (isnan(target) || target <= 0) && return bands
    inside = false
    lo = 0.0
    for (f, z) in zip(freqs, Z)
        over = abs(z) > target
        if over && !inside
            inside, lo = true, f
        elseif !over && inside
            inside = false
            push!(bands, (lo, f))
        end
    end
    inside && push!(bands, (lo, freqs[end]))
    return bands
end

# ─────────────────────────────────────────────────────────────────────────────
# Solver
# ─────────────────────────────────────────────────────────────────────────────
"""
    solve_ac(board, setup; settings = ac_settings(setup), log = s -> nothing) -> ACResult

Sweeps the PDN impedance seen at every sink. Copper temperature, plating and thickness
come from the DC settings.
"""
function solve_ac(board::BoardData, setup::SimSetup; settings::ACSettings = ac_settings(setup), log = (s -> nothing))
    t0 = time()
    any(e -> e.kind == :sink, setup.elements) || return failed(["No sinks: each sink is an impedance port."], settings, t0)
    (settings.f_start > 0 && settings.f_stop > settings.f_start) || return failed(["Invalid frequency range."], settings, t0)
    dcs = dc_settings(setup)
    ρ = resistivity(dcs.temperature_c)
    m = build_mesh(board, setup; h = settings.cell_mm, auto_div = 120, h_min = 0.1, h_max = 2.0, ρ = ρ,
                   cu_thickness_um = dcs.cu_thickness_um, plating_um = dcs.via_plating_um, include_caps = true,
                   tag = "[ac]", log = log)
    msgs = copy(m.messages)
    isempty(m.sink_t) && return failed(vcat(msgs, ["No usable sinks (check their pads and nets)."]), settings, t0)
    g, layers, L = m.grid, m.layers, length(m.layers)
    EA, EB, EK, EG, EL, EP1, EP2, EE = m.EA, m.EB, m.EK, m.EG, m.EL, m.EP1, m.EP2, m.EE
    N = m.nn

    # ── stackup-derived per-layer quantities
    diel = [dielectric_between(board, layers[l], layers[l+1], m.zcu) for l in 1:L-1]
    dret = [min(l > 1 ? diel[l-1].d : Inf, l < L ? diel[l].d : Inf) for l in 1:L]
    dret = [isfinite(d) ? d : 1.6 for d in dret]                         # mm, distance to the return plane
    Lsq = μ0 .* dret .* 1e-3 ./ 2                                        # H per square

    # ── plane-pair capacitance between overlapping cells of different nets on adjacent layers
    CA = Int[]; CB = Int[]; CC = Float64[]; CT = Float64[]
    for l in 1:L-1
        dd = diel[l]
        Ccell = ε0 * dd.er * (g.h * 1e-3)^2 / (dd.d * 1e-3)
        M1, M2, N1, N2 = m.nodeid[l], m.nodeid[l+1], m.netcell[l], m.netcell[l+1]
        for j in 1:g.ny, i in 1:g.nx
            a, b = M1[i, j], M2[i, j]
            if a != 0 && b != 0 && N1[i, j] != N2[i, j]
                push!(CA, a); push!(CB, b); push!(CC, Ccell); push!(CT, dd.tand)
            end
        end
    end
    log(@sprintf("[ac] %d plane-pair capacitance cells, %s total; %d capacitor(s), %d port(s)",
                 length(CA), format_si(sum(CC; init = 0.0), "F"), length(m.cap_t), length(m.sink_t)))

    # ── connectivity (every branch conducts at AC) and references
    parent = collect(1:N)
    function root(x)
        while parent[x] != x
            parent[x] = parent[parent[x]]
            x = parent[x]
        end
        return x
    end
    union!(a, b) = (ra = root(a); rb = root(b); ra != rb && (parent[ra] = rb))
    foreach(k -> union!(EA[k], EB[k]), eachindex(EA))
    foreach(k -> union!(CA[k], CB[k]), eachindex(CA))
    ref_of = Dict{Int,Int}()
    for t in m.vrm_t
        r = root(t.tn)
        haskey(ref_of, r) || (ref_of[r] = t.tn)
    end
    ports_t = NamedTuple[]
    for t in m.sink_t
        # use the pins whose copper is part of a circuit with a VRM
        P = [k for k in t.P if haskey(ref_of, root(k))]
        Nn = [k for k in t.N if haskey(ref_of, root(k)) && any(p -> root(p) == root(k), P)]
        if isempty(P) || isempty(Nn)
            # no VRM: reference the port's own − pins, if any are in the same circuit as its + pins
            pair = nothing
            for kp in t.P, kn in t.N
                root(kp) == root(kn) && (pair = (kp, kn); break)
            end
            if pair === nothing
                push!(msgs, "$(t.e.id): $(t.e.ref)'s pins aren't connected to the rest of the circuit; port skipped.")
                continue
            end
            r = root(pair[1])
            haskey(ref_of, r) || (ref_of[r] = pair[2])
            P = [k for k in t.P if root(k) == r]
            Nn = [k for k in t.N if root(k) == r]
            push!(msgs, "$(t.e.id): no VRM connected; impedance referenced to its own − pins.")
        end
        (length(P) < length(t.P) || length(Nn) < length(t.N)) &&
            push!(msgs, "$(t.e.id): some of $(t.e.ref)'s pin copper isn't connected; the port uses the connected pins only.")
        push!(ports_t, (e = t.e, P = P, N = Nn))
    end
    newidx = zeros(Int, N)
    nk = 0
    for k in 1:N
        r = root(k)
        haskey(ref_of, r) && ref_of[r] != k && (nk += 1; newidx[k] = nk)
    end

    # ── matrix pattern (fixed), values per frequency
    nb = length(EA)
    nbr = nb + length(CA)
    ent_i = Int[]; ent_j = Int[]; ent_b = Int[]; ent_s = Float64[]
    function pattern!(k, a, c)
        a > 0 && (push!(ent_i, a); push!(ent_j, a); push!(ent_b, k); push!(ent_s, 1.0))
        c > 0 && (push!(ent_i, c); push!(ent_j, c); push!(ent_b, k); push!(ent_s, 1.0))
        if a > 0 && c > 0
            push!(ent_i, a); push!(ent_j, c); push!(ent_b, k); push!(ent_s, -1.0)
            push!(ent_i, c); push!(ent_j, a); push!(ent_b, k); push!(ent_s, -1.0)
        end
    end
    for k in 1:nb
        pattern!(k, newidx[EA[k]], newidx[EB[k]])
    end
    for k in eachindex(CA)
        pattern!(nb + k, newidx[CA[k]], newidx[CB[k]])
    end

    elems = m.elems
    plate = dcs.via_plating_um * 1e-6
    yb = zeros(ComplexF64, nbr)
    function admittances!(f)
        ω = 2π * f
        δ = skin_depth(ρ, f)
        @inbounds for k in 1:nb
            kind = EK[k]
            yb[k] = if kind == BR_PLANE
                l = EL[k]
                1 / (ρ / t_eff(m.tmm[l] * 1e-3, δ) + im * ω * Lsq[l])
            elseif kind == BR_TRACE
                l = EL[k]
                len, w = EP1[k] * 1e-3, EP2[k] * 1e-3
                1 / (ρ * len / (w * t_eff(m.tmm[l] * 1e-3, δ)) + im * ω * trace_Lp(w, dret[l] * 1e-3) * len)
            elseif kind == BR_BARREL
                h, r = EP1[k] * 1e-3, EP2[k] * 0.5e-3
                te = min(t_eff(plate, δ), r)
                1 / (ρ * h / (π * (r^2 - (r - te)^2)) + im * ω * barrel_L(h, r))
            elseif kind == BR_TIE
                complex(EG[k])
            else
                p = elems[EE[k]].params
                kind2 = elems[EE[k]].kind
                zel = if kind == BR_VRM
                    max(p["Rout"], 1e-6) + im * ω * get(p, "Lout", 0.0)
                elseif kind == BR_CAP
                    max(p["ESR"], 1e-9) + im * ω * p["ESL"] + 1 / (im * ω * max(p["C"], 1e-18))
                elseif kind2 in (:resistor, :short)
                    complex(max(p["R"], 1e-6))
                else
                    max(p["DCR"], 1e-6) + im * ω * get(p, "L", 0.0)
                end
                1 / zel
            end
        end
        @inbounds for k in eachindex(CA)
            ωC = ω * CC[k]
            yb[nb+k] = complex(ωC * CT[k], ωC)
        end
        return yb
    end
    assemble(f) = (admittances!(f); sparse(ent_i, ent_j, ent_s .* yb[ent_b], nk, nk))

    # right-hand sides: 1 A into the + pads, out of the − pads
    np = length(ports_t)
    B = zeros(ComplexF64, nk, np)
    for (p, t) in enumerate(ports_t)
        for k in t.P
            newidx[k] > 0 && (B[newidx[k], p] += 1 / length(t.P))
        end
        for k in t.N
            newidx[k] > 0 && (B[newidx[k], p] -= 1 / length(t.N))
        end
    end
    vnode(X, k, p) = newidx[k] > 0 ? X[newidx[k], p] : (haskey(ref_of, root(k)) ? zero(ComplexF64) : complex(NaN))
    portV(X, t, p) = sum(vnode(X, k, p) for k in t.P) / length(t.P) - sum(vnode(X, k, p) for k in t.N) / length(t.N)

    nf = max(2, round(Int, log10(settings.f_stop / settings.f_start) * settings.points_per_decade) + 1)
    freqs = collect(10 .^ range(log10(settings.f_start), log10(settings.f_stop); length = nf))
    log(@sprintf("[ac] %d unknowns, %d branches, %d frequencies (%s – %s), built in %.2f s", nk, nbr, nf,
                 format_si(freqs[1], "Hz"), format_si(freqs[end], "Hz"), time() - t0))

    Z = [zeros(ComplexF64, nf) for _ in 1:np]
    t1 = time()
    F = nothing
    for (fi, f) in enumerate(freqs)
        Y = assemble(f)
        F = F === nothing ? lu(Y) : (try lu!(F, Y) catch; lu(Y) end)
        X = F \ B
        for p in 1:np
            Z[p][fi] = portV(X, ports_t[p], p)
        end
        fi % max(1, nf ÷ 4) == 0 && log(@sprintf("[ac]   %3d%%  (%s)", round(Int, 100fi / nf), format_si(f, "Hz")))
    end
    log(@sprintf("[ac] sweep solved in %.2f s", time() - t1))

    # targets: V_rail · ripple / step
    ports = Any[]
    for (p, t) in enumerate(ports_t)
        e = t.e
        vi = findfirst(x -> x.e.net_pos == e.net_pos, m.vrm_t)
        vnom = vi !== nothing ? m.vrm_t[vi].e.params["V"] : something(SimSetups.rail_voltage(e.net_pos), NaN)
        step = get(e.params, "Istep", 0.0)
        target = step > 0 ? vnom * get(e.params, "Ripple", 3.0) / 100 / step : NaN
        push!(ports, (id = e.id, ref = e.ref, net_pos = e.net_pos, net_neg = e.net_neg, Z = Z[p], target = target, vnom = vnom))
    end

    function solve_at(f, p)
        Y = assemble(f)
        X = lu(Y) \ B[:, p:p]
        return [vnode(X, k, 1) for k in 1:N]
    end
    secs = time() - t0
    log(@sprintf("[ac] done in %.2f s", secs))
    return ACResult(true, msgs, settings, freqs, ports, g, layers, m.nets, m.netcell, m.nodeid, solve_at, N,
                    length(CA), sum(CC; init = 0.0), secs, Dict{Tuple{Int,Float64},Any}())
end

"""
    ac_map(r, port, f) -> (maps, (lo, hi))

|V| per cell on every layer (V per 1 A driven at the port, i.e. transfer impedance in Ω)
at frequency f, plus its range. Cached per (port, f).
"""
function ac_map(r::ACResult, port::Int, f::Real)
    get!(r.cache, (port, Float64(f))) do
        v = r.solve_at(f, port)
        maps = [begin
                    out = fill(NaN32, r.grid.nx, r.grid.ny)
                    M = r.node[li]
                    for j in 1:r.grid.ny, i in 1:r.grid.nx
                        k = M[i, j]
                        (k != 0 && !isnan(real(v[k]))) && (out[i, j] = Float32(abs(v[k])))
                    end
                    out
                end for li in eachindex(r.layers)]
        vals = [x for M in maps for x in M if !isnan(x)]
        (maps, isempty(vals) ? (0f0, 1f0) : (0f0, max(maximum(vals), 1f-12)))
    end
end

fmt_band((lo, hi)) = format_si(lo, "Hz") * " – " * format_si(hi, "Hz")

"Human-readable summary for the console."
function ac_summary_lines(r::ACResult)
    r.ok || return ["AC analysis failed:"; ["  " * m for m in r.messages]]
    out = [@sprintf("Swept %d frequencies on %d nodes in %.1f s. Plane-pair capacitance %s.", length(r.freqs), r.nnodes,
                    r.seconds, format_si(r.cplane, "F"))]
    for p in r.ports
        mag = abs.(p.Z)
        imax, imin = argmax(mag), argmin(mag)
        line = @sprintf("Port %-6s %-5s %s: |Z| %s at %s · max %s at %s · min %s at %s", p.id, p.ref, p.net_pos,
                        format_si(mag[1], "Ω"), format_si(r.freqs[1], "Hz"), format_si(mag[imax], "Ω"),
                        format_si(r.freqs[imax], "Hz"), format_si(mag[imin], "Ω"), format_si(r.freqs[imin], "Hz"))
        push!(out, line)
        if !isnan(p.target)
            bands = target_violations(r.freqs, p.Z, p.target)
            push!(out, "     target " * format_si(p.target, "Ω") *
                       (isempty(bands) ? ": met over the whole sweep" : ": exceeded " * join(fmt_band.(bands), ", ")))
        end
    end
    append!(out, ["Note: " * m for m in r.messages])
    return out
end

end # module
