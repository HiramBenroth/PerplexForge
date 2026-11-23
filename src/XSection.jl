module XSection

# 2-D electrostatic cross-section solver for PCB transmission lines (quasi-TEM).
#
# A cross-section is a stack of horizontal dielectric slabs between optional reference
# planes, an optional conformal coating (solder mask), and one or more rectangular
# conductors. Laplace's equation ∇·(ε∇φ) = 0 is solved by finite volumes on a
# non-uniform tensor grid that is refined towards conductor edges and material
# interfaces. From the capacitance matrices with (C) and without (C0) the dielectrics:
#
#     L = μ0 ε0 · C0⁻¹      Z = √(L / C)      εeff = C / C0      delay = √(L C)
#
# For two conductors the odd / even modes give the differential and common-mode
# impedance. Lengths are in mm; per-unit-length results are SI (F/m, H/m, s/m).
# No GUI dependency: unit-tested against the exact zero-thickness stripline and
# coupled-stripline solutions (Cohn) and the Hammerstad–Jensen microstrip formula.

using SparseArrays
using LinearAlgebra

export Slab, Conductor, CrossSection, LineParams, PairParams, solve_cross_section, solve_extrapolated, line_params, pair_params,
       C0_LIGHT, cohn_stripline_z0, cohn_coupled_stripline, hammerstad_microstrip

const C0_LIGHT = 299_792_458.0          # m/s
const ε0 = 8.8541878128e-12             # F/m

"A horizontal dielectric layer spanning the whole width: y0 < y < y1 (mm)."
struct Slab
    y0::Float64
    y1::Float64
    εr::Float64
end

"A rectangular conductor (a trace): x0..x1 × y0..y1 (mm). y0 == y1 is a zero-thickness strip."
struct Conductor
    x0::Float64
    x1::Float64
    y0::Float64
    y1::Float64
end

"""
    CrossSection(; slabs, conductors, plane_bottom, plane_top, coat_t, coat_εr, coat_surface)

- `plane_bottom` / `plane_top`: y (mm) of a reference plane, or `nothing` (open, air above).
- `coat_t > 0`: a conformal coating (solder mask) of that thickness on the surface at
  `coat_surface` and around the conductors that sit on it (outer layers).
- `grounds`: grounded conductors at 0 V, e.g. a coplanar ground pour beside the trace.
"""
Base.@kwdef struct CrossSection
    slabs::Vector{Slab}
    conductors::Vector{Conductor}
    grounds::Vector{Conductor} = Conductor[]
    plane_bottom::Union{Nothing,Float64} = 0.0
    plane_top::Union{Nothing,Float64} = nothing
    coat_t::Float64 = 0.0
    coat_εr::Float64 = 1.0
    coat_surface::Float64 = NaN
end

# ─────────────────────────────────────────────────────────────────────────────
# Non-uniform grid lines
# ─────────────────────────────────────────────────────────────────────────────
"""
Grid coordinates on [lo, hi] that include every key point and whose local spacing
follows `min(hmax, min_k(h_k + γ·|x − x_k|))` (fine at keys, growing away from them).
"""
function graded_lines(lo, hi, keys::Vector{Tuple{Float64,Float64}}; γ = 0.25, hmax = Inf)
    pts = sort!(unique!(vcat([lo, hi], [clamp(k, lo, hi) for (k, _) in keys])))
    spacing(x) = min(hmax, minimum((hk + γ * abs(x - k) for (k, hk) in keys); init = hmax))
    out = Float64[pts[1]]
    for q in 1:length(pts)-1
        a, b = pts[q], pts[q+1]
        b - a < 1e-12 && continue
        # equidistribute: n cells with ∫ dx / spacing(x) cells each of equal weight
        ns = 64
        xs = range(a, b; length = ns + 1)
        dens = [1 / spacing(x) for x in xs]
        cum = zeros(ns + 1)
        for k in 1:ns
            cum[k+1] = cum[k] + (dens[k] + dens[k+1]) / 2 * (xs[k+1] - xs[k])
        end
        n = max(1, ceil(Int, cum[end]))
        for m in 1:n-1
            target = cum[end] * m / n
            k = clamp(searchsortedlast(cum, target), 1, ns)
            t = (target - cum[k]) / max(cum[k+1] - cum[k], eps())
            push!(out, xs[k] + t * (xs[k+1] - xs[k]))
        end
        push!(out, b)
    end
    return out
end

# ─────────────────────────────────────────────────────────────────────────────
# Solver
# ─────────────────────────────────────────────────────────────────────────────
struct XSResult
    C::Matrix{Float64}       # F/m, Maxwell capacitance matrix with dielectrics
    C0::Matrix{Float64}      # F/m, same in vacuum
    nodes::Int
end

"Relative permittivity at a point (cell centre)."
function eps_at(xs::CrossSection, x, y)
    if xs.coat_t > 0
        s = xs.coat_surface
        if s <= y <= s + xs.coat_t
            return xs.coat_εr
        end
        for c in Iterators.flatten((xs.conductors, xs.grounds))   # conformal shell around copper on the coated surface
            abs(c.y0 - s) < 1e-9 || continue
            if c.x0 - xs.coat_t <= x <= c.x1 + xs.coat_t && s <= y <= c.y1 + xs.coat_t
                return xs.coat_εr
            end
        end
    end
    for sl in xs.slabs
        sl.y0 <= y <= sl.y1 && return sl.εr
    end
    return 1.0
end

"""
    solve_cross_section(xs; fine = 1.0) -> XSResult

`fine` scales the mesh density (2.0 = twice as many lines per mm).
"""
function solve_cross_section(xs::CrossSection; fine::Real = 1.0)
    cs = xs.conductors
    isempty(cs) && error("cross-section has no conductors")
    xmin = minimum(c.x0 for c in cs); xmax = maximum(c.x1 for c in cs)
    ylo = something(xs.plane_bottom, minimum(c.y0 for c in cs))
    # characteristic size: distance from the conductors to the nearest plane
    hb = xs.plane_bottom === nothing ? Inf : minimum(c.y0 for c in cs) - xs.plane_bottom
    ht = xs.plane_top === nothing ? Inf : xs.plane_top - maximum(c.y1 for c in cs)
    hchar = max(min(hb, ht), 0.01)
    hchar = isfinite(hchar) ? hchar : max(xmax - xmin, 0.1)
    wmin = minimum(c.x1 - c.x0 for c in cs)
    tmin = minimum((c.y1 - c.y0 for c in cs if c.y1 > c.y0); init = Inf)

    # domain: far enough for open boundaries (Dirichlet 0 there)
    side = max(12 * hchar, 4 * (xmax - xmin))
    x_lo, x_hi = xmin - side, xmax + side
    y_lo = xs.plane_bottom === nothing ? ylo - max(15 * hchar, 2.0) : xs.plane_bottom
    y_hi = xs.plane_top === nothing ? maximum(c.y1 for c in cs) + max(15 * hchar, 2.0) : xs.plane_top

    hf = min(wmin, hchar, isfinite(tmin) ? 4 * tmin : Inf) / (12 * fine)      # finest spacing near edges
    hm = hchar / (6 * fine)                                                  # near material interfaces
    kx = Tuple{Float64,Float64}[]
    for c in cs
        push!(kx, (c.x0, hf), (c.x1, hf))
        if xs.coat_t > 0 && abs(c.y0 - xs.coat_surface) < 1e-9
            push!(kx, (c.x0 - xs.coat_t, hm), (c.x1 + xs.coat_t, hm))
        end
    end
    for g in xs.grounds
        push!(kx, (g.x0, hf), (g.x1, hm))
    end
    ky = Tuple{Float64,Float64}[]
    for c in cs
        push!(ky, (c.y0, hf), (c.y1, hf))
        xs.coat_t > 0 && push!(ky, (c.y1 + xs.coat_t, hm))
    end
    for s in xs.slabs
        push!(ky, (s.y0, hm), (s.y1, hm))
    end
    xs.coat_t > 0 && push!(ky, (xs.coat_surface + xs.coat_t, hm))
    X = graded_lines(x_lo, x_hi, kx; hmax = 2 * hchar)
    Y = graded_lines(y_lo, y_hi, filter(k -> y_lo <= k[1] <= y_hi, ky); hmax = 2 * hchar)
    nx, ny = length(X), length(Y)

    # conductor id per node (0 = free, -1 = ground: planes and the outer box)
    tol = 1e-9
    fixed = zeros(Int, nx, ny)
    for j in 1:ny, i in 1:nx
        if i == 1 || i == nx || j == 1 || j == ny
            fixed[i, j] = -1
        end
    end
    for (ci, c) in enumerate(cs)
        for j in 1:ny
            c.y0 - tol <= Y[j] <= c.y1 + tol || continue
            for i in 1:nx
                c.x0 - tol <= X[i] <= c.x1 + tol && (fixed[i, j] = ci)
            end
        end
    end
    for g in xs.grounds
        for j in 1:ny
            g.y0 - tol <= Y[j] <= g.y1 + tol || continue
            for i in 1:nx
                g.x0 - tol <= X[i] <= g.x1 + tol && (fixed[i, j] = -1)
            end
        end
    end
    for ci in 1:length(cs)
        any(==(ci), fixed) || error("conductor $ci is thinner than the mesh")
    end

    # cell permittivities (cell (i,j) spans X[i]..X[i+1] × Y[j]..Y[j+1])
    epsc = [eps_at(xs, (X[i] + X[i+1]) / 2, (Y[j] + Y[j+1]) / 2) for i in 1:nx-1, j in 1:ny-1]

    free = findall(==(0), fixed)
    idx = zeros(Int, nx, ny)
    for (k, I) in enumerate(free)
        idx[I] = k
    end
    nfree = length(free)

    function coeffs(ε)
        # face coefficients between node (i,j) and its east / north neighbour
        aE = zeros(nx - 1, ny)
        aN = zeros(nx, ny - 1)
        for j in 1:ny, i in 1:nx-1
            dx = X[i+1] - X[i]
            s = 0.0
            j > 1 && (s += ε[i, j-1] * (Y[j] - Y[j-1]) / 2)
            j < ny && (s += ε[i, j] * (Y[j+1] - Y[j]) / 2)
            aE[i, j] = s / dx
        end
        for j in 1:ny-1, i in 1:nx
            dy = Y[j+1] - Y[j]
            s = 0.0
            i > 1 && (s += ε[i-1, j] * (X[i] - X[i-1]) / 2)
            i < nx && (s += ε[i, j] * (X[i+1] - X[i]) / 2)
            aN[i, j] = s / dy
        end
        return aE, aN
    end

    function capmatrix(ε)
        aE, aN = coeffs(ε)
        Is = Int[]; Js = Int[]; Vs = Float64[]
        nc = length(cs)
        B = zeros(nfree, nc)                     # RHS per conductor excitation
        diag = zeros(nfree)
        function couple!(p, q, a)                # p, q: CartesianIndex
            kp, kq = idx[p], idx[q]
            if kp > 0
                diag[kp] += a
                if kq > 0
                    push!(Is, kp); push!(Js, kq); push!(Vs, -a)
                elseif fixed[q] > 0
                    B[kp, fixed[q]] += a
                end
            end
        end
        for j in 1:ny, i in 1:nx-1
            p, q = CartesianIndex(i, j), CartesianIndex(i + 1, j)
            couple!(p, q, aE[i, j]); couple!(q, p, aE[i, j])
        end
        for j in 1:ny-1, i in 1:nx
            p, q = CartesianIndex(i, j), CartesianIndex(i, j + 1)
            couple!(p, q, aN[i, j]); couple!(q, p, aN[i, j])
        end
        append!(Is, 1:nfree); append!(Js, 1:nfree); append!(Vs, diag)
        A = sparse(Is, Js, Vs, nfree, nfree)
        F = cholesky(Symmetric(A))
        Φ = F \ B
        # charge on conductor a for excitation b: flux out of a's nodes
        Q = zeros(nc, nc)
        pot(I, b) = (k = idx[I]; k > 0 ? Φ[k, b] : (fixed[I] == b ? 1.0 : 0.0))
        for b in 1:nc
            for j in 1:ny, i in 1:nx
                a = fixed[i, j]
                a > 0 || continue
                v = pot(CartesianIndex(i, j), b)
                for (di, dj, coef) in ((1, 0, i < nx ? aE[i, j] : 0.0), (-1, 0, i > 1 ? aE[i-1, j] : 0.0),
                                       (0, 1, j < ny ? aN[i, j] : 0.0), (0, -1, j > 1 ? aN[i, j-1] : 0.0))
                    coef == 0 && continue
                    q = CartesianIndex(i + di, j + dj)
                    fixed[q] == a && continue
                    Q[a, b] += coef * (v - pot(q, b))
                end
            end
        end
        Q .*= ε0
        return (Q + Q') / 2
    end

    C = capmatrix(epsc)
    C0 = capmatrix(ones(size(epsc)))
    return XSResult(C, C0, nx * ny)
end

"""
    solve_extrapolated(xs; base = 4.0) -> XSResult

Solves at mesh densities `base` and `2base` and Richardson-extrapolates the capacitance
matrices, assuming the O(√h) error of the field singularity at the strip edges. Within
±0.5 % of the exact stripline / coupled-stripline solutions in the tests.
"""
function solve_extrapolated(xs::CrossSection; base::Real = 4.0)
    r1 = solve_cross_section(xs; fine = base)
    r2 = solve_cross_section(xs; fine = 2base)
    k = 1 / (sqrt(2) - 1)
    return XSResult(r2.C .+ k .* (r2.C .- r1.C), r2.C0 .+ k .* (r2.C0 .- r1.C0), r2.nodes)
end

# ─────────────────────────────────────────────────────────────────────────────
# Line parameters
# ─────────────────────────────────────────────────────────────────────────────
"Single-ended line: Z0 (Ω), εeff, delay (s/m), L (H/m), C (F/m)."
struct LineParams
    Z0::Float64
    εeff::Float64
    delay::Float64
    L::Float64
    C::Float64
end

"Coupled pair: odd/even mode Z (Ω), differential (2·Zodd) and common-mode (Zeven/2) Z, modal delays (s/m)."
struct PairParams
    Zodd::Float64
    Zeven::Float64
    Zdiff::Float64
    Zcomm::Float64
    delay_odd::Float64
    delay_even::Float64
    εeff_odd::Float64
end

function line_params(r::XSResult)
    C, C0 = r.C[1, 1], r.C0[1, 1]
    L = 1 / (C0_LIGHT^2 * C0)
    return LineParams(sqrt(L / C), C / C0, sqrt(L * C), L, C)
end

function pair_params(r::XSResult)
    size(r.C, 1) == 2 || error("pair_params needs two conductors")
    L = inv(r.C0) ./ C0_LIGHT^2
    C = r.C
    Lo, Co = (L[1, 1] - L[1, 2] + L[2, 2] - L[2, 1]) / 2, (C[1, 1] - C[1, 2] + C[2, 2] - C[2, 1]) / 2
    Le, Ce = (L[1, 1] + L[1, 2] + L[2, 2] + L[2, 1]) / 2, (C[1, 1] + C[1, 2] + C[2, 2] + C[2, 1]) / 2
    C0o = (r.C0[1, 1] - r.C0[1, 2] + r.C0[2, 2] - r.C0[2, 1]) / 2
    Zo, Ze = sqrt(Lo / Co), sqrt(Le / Ce)
    return PairParams(Zo, Ze, 2Zo, Ze / 2, sqrt(Lo * Co), sqrt(Le * Ce), Co / C0o)
end

# ─────────────────────────────────────────────────────────────────────────────
# Closed-form references (used by the tests)
# ─────────────────────────────────────────────────────────────────────────────
function agm(a, b)
    for _ in 1:60
        a, b = (a + b) / 2, sqrt(a * b)
        abs(a - b) < 1e-15 * a && break
    end
    return a
end
"Complete elliptic integral of the first kind K(k), modulus k."
ellipK(k) = π / (2 * agm(1.0, sqrt(1 - k^2)))

"Exact Z0 of a zero-thickness strip of width w centred between planes b apart (Cohn)."
function cohn_stripline_z0(w, b, εr)
    k = sech(π * w / (2b))
    return 30π / sqrt(εr) * ellipK(k) / ellipK(sqrt(1 - k^2))
end

"Exact (Zeven, Zodd) of zero-thickness edge-coupled striplines, width w, gap s, plane spacing b (Cohn)."
function cohn_coupled_stripline(w, s, b, εr)
    ke = tanh(π * w / (2b)) * tanh(π * (w + s) / (2b))
    ko = tanh(π * w / (2b)) * coth(π * (w + s) / (2b))
    z(k) = 30π / sqrt(εr) * ellipK(sqrt(1 - k^2)) / ellipK(k)
    return z(ke), z(ko)
end

"Hammerstad–Jensen microstrip (zero thickness): (Z0, εeff). Accurate to ~0.2 %."
function hammerstad_microstrip(w, h, εr)
    u = w / h
    a = 1 + log((u^4 + (u / 52)^2) / (u^4 + 0.432)) / 49 + log(1 + (u / 18.1)^3) / 18.7
    b = 0.564 * ((εr - 0.9) / (εr + 3))^0.053
    εeff = (εr + 1) / 2 + (εr - 1) / 2 * (1 + 10 / u)^(-a * b)
    f = 6 + (2π - 6) * exp(-(30.666 / u)^0.7528)
    η0 = 376.730313668
    Z01 = η0 / (2π) * log(f / u + sqrt(1 + 4 / u^2))
    return Z01 / sqrt(εeff), εeff
end

end # module
