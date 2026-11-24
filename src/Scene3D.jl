module Scene3D

# Board geometry and the 3D scene: free-orbit camera (no axis box, nothing clipped),
# fit/preset views, picking, layer / net-class coloring, element markers.

using GLMakie
using ..BoardParser: BoardData, Pad, Component
using ..Geometry
using ..SimSetups
using ..WorkbenchState
using ..DCSolver: DCResult, overlay_range, dc_probe, voltage_map
using ..ACSolver: ac_map
using ..SISolver: SIResult, impedance_of, si_overlay_range, piece_status, SI_KIND_LABEL

export LayerData, build_layers, stack_geometry, board_bounds, BoardScene, build_scene!, set_view!,
       refit_if_untouched!, pick_target, hover_info, layer_color, MAX_ZSCALE, SI_STATUS_COLORS, SI_KIND_COLORS

const GB = GLMakie.Makie.GeometryBasics
const MAX_ZSCALE = 20.0

_len(v) = sqrt(sum(abs2, v))
_unit(v) = v / _len(v)

# ─────────────────────────────────────────────────────────────────────────────
# Geometry helpers  (KiCad's Y axis points down: Y is negated once, in P)
# ─────────────────────────────────────────────────────────────────────────────
P(x, y) = Point2f(x, -y)

const LAYER_COLORS = Dict(
    "F.Cu"   => RGBf(0.86, 0.27, 0.27),
    "In1.Cu" => RGBf(0.85, 0.75, 0.25),
    "In2.Cu" => RGBf(0.25, 0.75, 0.65),
    "In3.Cu" => RGBf(0.70, 0.40, 0.85),
    "In4.Cu" => RGBf(0.45, 0.80, 0.35),
    "B.Cu"   => RGBf(0.30, 0.50, 0.90),
)
layer_color(name) = get(LAYER_COLORS, name, RGBf(0.7, 0.7, 0.7))
const HL_COLOR = RGBf(1.0, 0.95, 0.25)

const SI_STATUS_COLORS = Dict(:ok => RGBf(0.35, 0.85, 0.45), :off => RGBf(0.95, 0.30, 0.30),
                              :none => RGBf(0.45, 0.48, 0.55), :noref => RGBf(0.95, 0.30, 0.85))
const SI_KIND_COLORS = Dict(:microstrip => RGBf(0.35, 0.65, 1.0), :stripline => RGBf(0.40, 0.88, 0.55),
                            :embedded => RGBf(0.98, 0.70, 0.25), :none => RGBf(0.95, 0.30, 0.85))

# ── primitives → convex rings ────────────────────────────────────────────────
function stadium(a::Point2f, b::Point2f, r; n = 6)
    d = b - a
    α = (d[1] == 0 && d[2] == 0) ? 0.0 : atan(d[2], d[1])
    ring = Point2f[]
    for k in 0:n
        t = α - π / 2 + π * k / n
        push!(ring, Point2f(b[1] + r * cos(t), b[2] + r * sin(t)))
    end
    for k in 0:n
        t = α + π / 2 + π * k / n
        push!(ring, Point2f(a[1] + r * cos(t), a[2] + r * sin(t)))
    end
    return ring
end

circle_ring(cx, cy, r; n = 16) = [P(cx + r * cos(2π * k / n), cy + r * sin(2π * k / n)) for k in 0:n-1]

function pad_ring(p::Pad, cx, cy)
    ring = Point2f[]
    for (x, y) in pad_shape(p)
        rx, ry = rot(x, y, p.angle)
        push!(ring, P(cx + rx, cy + ry))
    end
    return ring
end

# ── per-layer geometry ───────────────────────────────────────────────────────
struct Prims
    rings::Vector{Vector{Point2f}}
    nets::Vector{String}
    refs::Vector{String}      # owning component (pads only)
end
Prims() = Prims(Vector{Point2f}[], String[], String[])
add!(p::Prims, ring, net, ref = "") = (push!(p.rings, ring); push!(p.nets, net); push!(p.refs, ref))

struct LayerData
    name::String
    idx::Int
    color::RGBf
    traces::Prims
    pads::Prims
    vias::Prims
    pours::Vector{Vector{Point2f}}    # filled-copper polygons (non-convex, with relief cuts)
    pour_nets::Vector{String}
end

function build_layers(board::BoardData)
    names = copper_layers(board)
    index = Dict(n => i for (i, n) in enumerate(names))
    data = [LayerData(n, i, layer_color(n), Prims(), Prims(), Prims(), Vector{Point2f}[], String[])
            for (i, n) in enumerate(names)]

    for t in board.traces
        haskey(index, t.layer) || continue
        a, b = P(t.start_pt.x, t.start_pt.y), P(t.end_pt.x, t.end_pt.y)
        add!(data[index[t.layer]].traces, stadium(a, b, t.width / 2), t.net_name)
    end

    for c in board.components, p in c.pads
        (p.size_x <= 0 || p.size_y <= 0) && continue
        cx, cy = pad_center(c, p)
        ring = pad_ring(p, cx, cy)
        for L in data
            pad_on(p.layers, L.name) && add!(L.pads, ring, p.net_name, c.ref)
        end
    end

    for v in board.vias
        ids = [index[l] for l in v.layers if haskey(index, l)]
        isempty(ids) && continue
        lo, hi = extrema(ids)
        ring = circle_ring(v.pos.x, v.pos.y, v.size / 2)
        for L in data
            lo <= L.idx <= hi && add!(L.vias, ring, v.net_name)
        end
    end

    unfilled = 0
    for z in board.zones
        haskey(index, z.layer) || continue
        polys = isempty(z.fills) ? [z.boundary] : z.fills     # unfilled zone → show its boundary
        isempty(z.fills) && (unfilled += 1)
        L = data[index[z.layer]]
        for poly in polys
            if length(poly) >= 3
                push!(L.pours, [P(p.x, p.y) for p in poly])
                push!(L.pour_nets, z.net_name)
            end
        end
    end
    return data, unfilled
end

# ── rings → meshes / lines ───────────────────────────────────────────────────
# Each mesh also returns `vring`: for every vertex, the index of the ring it came from
# (0 for the placeholder), so a picked vertex can be mapped back to its net.
const EMPTY_MD = (Point2f[Point2f(0, 0), Point2f(0, 0), Point2f(0, 0)], [GB.GLTriangleFace(1, 2, 3)], Int32[0, 0, 0])

"Convex rings (traces, pads, vias) → triangle fans."
function mesh_data(rings)
    isempty(rings) && return EMPTY_MD
    verts = Point2f[]
    faces = GB.GLTriangleFace[]
    vring = Int32[]
    for (ri, ring) in enumerate(rings)
        n = length(ring)
        base = length(verts)
        push!(verts, sum(ring) / n)
        append!(verts, ring)
        append!(vring, fill(Int32(ri), n + 1))
        for i in 1:n
            j = i == n ? 1 : i + 1
            push!(faces, GB.GLTriangleFace(base + 1, base + 1 + i, base + 1 + j))
        end
    end
    return verts, faces, vring
end

_cross(o, a, b) = (a[1] - o[1]) * (b[2] - o[2]) - (a[2] - o[2]) * (b[1] - o[1])

"""
Ear-clipping triangulation of one polygon (no external dependencies).
Handles concave shapes, either winding direction, and KiCad's "bridged" polygons
(holes joined to the outline by zero-width slits). Returns index triples into `ring`.
"""
function earclip(ring::Vector{Point2f})
    n = length(ring)
    n > 1 && ring[1] == ring[end] && (n -= 1)          # drop explicit closing point
    n < 3 && return NTuple{3,Int}[]

    area = 0.0
    for i in 1:n
        j = i == n ? 1 : i + 1
        area += Float64(ring[i][1]) * ring[j][2] - Float64(ring[j][1]) * ring[i][2]
    end
    idx = area > 0 ? collect(1:n) : collect(n:-1:1)     # make it counter-clockwise
    P = [(Float64(ring[i][1]), Float64(ring[i][2])) for i in idx]

    scale = max(maximum(abs(p[1]) for p in P), maximum(abs(p[2]) for p in P), 1.0)
    eps = 1e-12 * scale * scale

    prv = [k == 1 ? n : k - 1 for k in 1:n]
    nxt = [k == n ? 1 : k + 1 for k in 1:n]
    tris = NTuple{3,Int}[]
    m = n
    k = 1
    stall = 0

    function is_ear(a, b, c)
        pa, pb, pc = P[a], P[b], P[c]
        _cross(pa, pb, pc) <= eps && return false
        minx, maxx = min(pa[1], pb[1], pc[1]), max(pa[1], pb[1], pc[1])
        miny, maxy = min(pa[2], pb[2], pc[2]), max(pa[2], pb[2], pc[2])
        q = nxt[c]
        while q != a
            p = P[q]
            if minx <= p[1] <= maxx && miny <= p[2] <= maxy && p != pa && p != pb && p != pc
                if _cross(pa, pb, p) >= 0 && _cross(pb, pc, p) >= 0 && _cross(pc, pa, p) >= 0
                    return false
                end
            end
            q = nxt[q]
        end
        return true
    end

    while m > 3
        a, b, c = prv[k], k, nxt[k]
        if abs(_cross(P[a], P[b], P[c])) <= eps            # collinear / slit spike → drop silently
            nxt[a] = c; prv[c] = a; m -= 1; k = a; stall = 0
        elseif is_ear(a, b, c)
            push!(tris, (idx[a], idx[b], idx[c]))
            nxt[a] = c; prv[c] = a; m -= 1; k = c; stall = 0
        else
            k = nxt[k]
            stall += 1
            if stall > m                                   # no ear found (bad geometry): force progress
                a, b, c = prv[k], k, nxt[k]
                _cross(P[a], P[b], P[c]) > eps && push!(tris, (idx[a], idx[b], idx[c]))
                nxt[a] = c; prv[c] = a; m -= 1; k = c; stall = 0
            end
        end
    end
    if m == 3
        a, b, c = prv[k], k, nxt[k]
        _cross(P[a], P[b], P[c]) > eps && push!(tris, (idx[a], idx[b], idx[c]))
    end
    return tris
end

"Non-convex polygons (copper pours) → triangle mesh. Returns ((verts, faces, vring), failures)."
function tri_data(polys)
    verts = Point2f[]
    faces = GB.GLTriangleFace[]
    vring = Int32[]
    nfail = 0
    for (ri, ring) in enumerate(polys)
        length(ring) < 3 && continue
        try
            tris = earclip(ring)
            if isempty(tris)
                nfail += 1
                continue
            end
            base = length(verts)
            append!(verts, ring)
            append!(vring, fill(Int32(ri), length(ring)))
            for (i, j, k) in tris
                push!(faces, GB.GLTriangleFace(base + i, base + j, base + k))
            end
        catch err
            nfail += 1
            nfail == 1 && @warn "Pour triangulation error" exception = (err, catch_backtrace())
        end
    end
    isempty(verts) && return EMPTY_MD, nfail
    return (verts, faces, vring), nfail
end

to_mesh3(md) = GB.Mesh([Point3f(p[1], p[2], 0f0) for p in md[1]], md[2])

function ring_lines(rings)
    pts = Point3f[]
    for r in rings
        for p in r; push!(pts, Point3f(p[1], p[2], 0)); end
        push!(pts, Point3f(r[1][1], r[1][2], 0))
        push!(pts, Point3f(NaN, NaN, NaN))
    end
    return pts
end

function hl_rings(L::LayerData, kind::Symbol, name::AbstractString)
    rings = Vector{Point2f}[]
    if kind == :net
        for pr in (L.traces, L.pads, L.vias), (r, n) in zip(pr.rings, pr.nets)
            n == name && push!(rings, r)
        end
    elseif kind == :comp
        for (r, c) in zip(L.pads.rings, L.pads.refs)
            c == name && push!(rings, r)
        end
    end
    return rings
end

# ── stackup → z positions ────────────────────────────────────────────────────
"Returns (copper z by layer [mm from bottom], dielectric slabs [(zbot, ztop, name)], dielectric_defined)."
Geometry.stack_geometry(board::BoardData, layers::Vector{LayerData}) = stack_geometry(board, [L.name for L in layers])

function board_bounds(board::BoardData, layers)
    xs = Float64[]; ys = Float64[]
    for pl in board.outline, p in pl
        push!(xs, p.x); push!(ys, -p.y)
    end
    if isempty(xs)
        for L in layers, pr in (L.traces, L.pads), r in pr.rings, p in r
            push!(xs, p[1]); push!(ys, p[2])
        end
    end
    isempty(xs) && return (0.0, 100.0, 0.0, 100.0)
    return (minimum(xs), maximum(xs), minimum(ys), maximum(ys))
end

# ── nominal component body (like the black blocks ADS generates) ─────────────
"""
Oriented box around a component's pads, in plot space. Returns (4 base corners, height)
or `nothing` if the component has no usable pads. Height is a nominal guess from the
footprint size, since the real 3D model is not read.
"""
function body_box(c::Component)
    x0 = y0 = Inf
    x1 = y1 = -Inf
    for p in c.pads
        (p.size_x <= 0 || p.size_y <= 0) && continue
        θ = deg2rad(p.angle - c.angle)                   # pad orientation in the footprint frame
        hx = (abs(p.size_x * cos(θ)) + abs(p.size_y * sin(θ))) / 2
        hy = (abs(p.size_x * sin(θ)) + abs(p.size_y * cos(θ))) / 2
        x0 = min(x0, p.local_pos.x - hx); x1 = max(x1, p.local_pos.x + hx)
        y0 = min(y0, p.local_pos.y - hy); y1 = max(y1, p.local_pos.y + hy)
    end
    isfinite(x0) || return nothing
    m = 0.1                                              # small margin around the pads
    x0 -= m; y0 -= m; x1 += m; y1 += m
    ring = Point2f[]
    for (x, y) in ((x0, y0), (x1, y0), (x1, y1), (x0, y1))
        rx, ry = rot(x, y, c.angle)
        push!(ring, P(c.pos.x + rx, c.pos.y + ry))
    end
    return ring, Float32(clamp(0.3 * min(x1 - x0, y1 - y0), 0.25, 2.5))
end

# ─────────────────────────────────────────────────────────────────────────────
# The scene
# ─────────────────────────────────────────────────────────────────────────────
mutable struct BoardScene
    ls::LScene
    scene::Scene
    cam::Any
    pickmap::IdDict{Any,Any}           # plot → (:net, layer, vertex nets) | (:comp, ref)
    bbox::Function                     # () → Rect3f around everything at the current z-scale
    raycast::Function                  # () → (net, layer, x, y) of the copper under the cursor, or nothing
    last_fit_eye::Base.RefValue{Any}
    view::Base.RefValue{Symbol}
end

"Even-odd point-in-polygon (works for KiCad's bridged pour polygons too)."
function inpoly(x, y, ring)
    inside = false
    n = length(ring)
    j = n
    for i in 1:n
        xi, yi = ring[i][1], ring[i][2]
        xj, yj = ring[j][1], ring[j][2]
        if (yi > y) != (yj > y) && x < (xj - xi) * (y - yi) / (yj - yi) + xi
            inside = !inside
        end
        j = i
    end
    return inside
end

ring_bbox(r) = (minimum(p[1] for p in r), minimum(p[2] for p in r), maximum(p[1] for p in r), maximum(p[2] for p in r))

const VIEWS = Dict(
    :top    => (Vec3d(0, 0, 1), Vec3d(0, 1, 0)),
    :bottom => (Vec3d(0, 0, -1), Vec3d(0, 1, 0)),
    :iso    => (_unit(Vec3d(-0.45, -0.85, 0.75)), Vec3d(0, 0, 1)),
    :side   => (_unit(Vec3d(0, -1, 0.02)), Vec3d(0, 0, 1)),
)

"""
    set_view!(bs, view = :keep)

Frame everything (board + component bodies at the current z-scale). `view` is one of
:top, :bottom, :iso, :side, or :keep (same direction as now: plain "Fit").
"""
function set_view!(bs::BoardScene, view::Symbol = :keep)
    cam, scene = bs.cam, bs.scene
    if view == :keep
        d = cam.eyeposition[] - cam.lookat[]
        dir = _len(d) > 0 ? _unit(Vec3d(d)) : VIEWS[:iso][1]
        up = Vec3d(cam.upvector[])
    else
        dir, up = VIEWS[view]
        bs.view[] = view
    end
    rect = bs.bbox()
    c = Vec3d(GB.origin(rect) + widths(rect) / 2)
    r = 0.5 * _len(Vec3d(widths(rect)))
    vp = widths(scene.viewport[])
    aspect = vp[1] / max(vp[2], 1)
    # the bounding sphere is conservative for a flat board, so frame a bit tighter than it
    dist = r / tand(cam.fov[] / 2) / min(1.0, aspect) * 0.95
    update_cam!(scene, cam, rect, false)                 # bounding sphere → clip planes
    update_cam!(scene, cam, c + dist * dir, c, up)
    bs.last_fit_eye[] = cam.eyeposition[]
    return bs
end

"Refit only if the user has not moved the camera since the last fit."
function refit_if_untouched!(bs::BoardScene)
    e = bs.last_fit_eye[]
    (e === nothing || _len(Vec3d(bs.cam.eyeposition[]) - Vec3d(e)) < 1e-6) && set_view!(bs, :keep)
end

const NO_KEY = (up_key = false, down_key = false, left_key = false, right_key = false, forward_key = false,
                backward_key = false, zoom_in_key = false, zoom_out_key = false, increase_fov_key = false,
                decrease_fov_key = false, pan_left_key = false, pan_right_key = false, tilt_up_key = false,
                tilt_down_key = false, roll_clockwise_key = false, roll_counterclockwise_key = false,
                fix_x_key = false, fix_y_key = false, fix_z_key = false)

class_cat_color(cat, cls) = (c = CLASS_COLORS[cls];
    cat == :pours ? darken(c, 0.6) : cat == :pads ? lighten(c, 0.25) : cat == :vias ? lighten(c, 0.5) : c)
layer_cat_color(cat, L) =
    cat == :pours ? darken(L.color, 0.8) : cat == :pads ? lighten(L.color, 0.45) : cat == :vias ? lighten(L.color, 0.7) : L.color

"Is a result overlay drawn on the copper right now (so the plain copper should step back)?"
function overlay_active(st::UIState)
    m = st.result_mode[]
    ok(r) = r !== nothing && r.ok
    m == "Off" && return false
    m == AC_MODE && return ok(st.ac_result[]) && st.ac_freq[] > 0
    is_si_mode(m) && return ok(st.si_result[])
    return ok(st.result[])
end

const DIM_COPPER = RGBf(0.36, 0.37, 0.40)

function vertex_colors(st::UIState, vnets, cat, L, mode, alpha)
    # under an overlay the copper is neutral grey (pads a little lighter), so the result colours stand out
    overlay_active(st) && return fill(rgba(cat == :pads ? lighten(DIM_COPPER, 0.25) : cat == :pours ? darken(DIM_COPPER, 0.7) :
                                           DIM_COPPER, alpha), length(vnets))
    if mode != "Net class"
        return fill(rgba(layer_cat_color(cat, L), alpha), length(vnets))
    end
    cache = Dict{String,RGBAf}()
    return [get!(() -> rgba(class_cat_color(cat, netclass(st.setup, n)), alpha), cache, n) for n in vnets]
end

"Build the 3D view into grid position `pos`."
function build_scene!(pos, st::UIState, layers::Vector{LayerData}, zcu, slabs, bounds; say = println)
    board = st.board
    bx0, bx1, by0, by1 = bounds
    span = max(bx1 - bx0, by1 - by0, 10.0)
    u = span * 0.0005                                    # tiny z offsets to stop z-fighting
    zmin, zmax = extrema(values(zcu))
    exag = st.exag

    ls = LScene(pos; show_axis = false,
                scenekw = (camera = s -> cam3d!(s; projectiontype = Makie.Perspective, fixed_axis = true,
                                                center = false, clipping_mode = :adaptive, NO_KEY...),
                           backgroundcolor = RGBf(0.09, 0.09, 0.11), clear = true))
    scene = ls.scene
    cam = cameracontrols(scene)
    pickmap = IdDict{Any,Any}()

    bindz!(plt, zb, off) = on(exag; update = true) do e
        translate!(plt, 0, 0, zb * e + off)
    end

    # ── copper ───────────────────────────────────────────────────────────────
    nfail = 0
    for L in layers
        zb = zcu[L.name]
        lon = st.layer_on[L.name]
        V(cat, want) = lift((on_, m) -> on_ && m == want, lon, st.modes[cat])

        parts = Tuple{Symbol,Any,Vector{String},Any}[]          # (cat, meshdata, ring nets, outline rings)
        if !isempty(L.pours)
            md, nf = tri_data(L.pours)
            nfail += nf
            push!(parts, (:pours, md, L.pour_nets, L.pours))
        end
        for (cat, prims) in ((:traces, L.traces), (:vias, L.vias), (:pads, L.pads))
            isempty(prims.rings) || push!(parts, (cat, mesh_data(prims.rings), prims.nets, prims.rings))
        end
        offs = Dict(:pours => 0.0, :traces => 2u, :vias => 3u, :pads => 4u)

        for (cat, md, rnets, rings) in parts
            vnets = [r == 0 ? "" : rnets[r] for r in md[3]]
            m3 = to_mesh3(md)
            cols = lift((mode, _...) -> vertex_colors(st, vnets, cat, L, mode, 1f0), st.color_by, st.class_rev, st.result_mode,
                        st.result, st.ac_result, st.si_result, st.ac_freq)
            p = mesh!(scene, m3; color = cols, shading = NoShading, visible = V(cat, "Solid"))
            bindz!(p, zb, offs[cat]); pickmap[p] = (:net, L.name, vnets)
            if cat == :pours
                tcols = lift((mode, _...) -> vertex_colors(st, vnets, cat, L, mode, 0.3f0), st.color_by, st.class_rev,
                             st.result_mode, st.result, st.ac_result, st.si_result, st.ac_freq)
                p = mesh!(scene, m3; color = tcols, shading = NoShading, transparency = true, visible = V(cat, "Translucent"))
                bindz!(p, zb, offs[cat]); pickmap[p] = (:net, L.name, vnets)
            end
            lc = cat == :pours ? lighten(L.color, 0.3) : layer_cat_color(cat, L)
            pl = lines!(scene, ring_lines(rings); color = lc, linewidth = 1, visible = V(cat, "Wireframe"))
            bindz!(pl, zb, offs[cat] + u)
        end

        hl = lift(st.sel) do s
            kind, name = s
            ref = sel_component(st, s)
            rings = ref !== nothing ? hl_rings(L, :comp, ref) : kind == :net ? hl_rings(L, :net, name) : Vector{Point2f}[]
            to_mesh3(mesh_data(rings))
        end
        p = mesh!(scene, hl; color = HL_COLOR, shading = NoShading, visible = lon)
        bindz!(p, zb, 7u)
    end
    nfail > 0 && say("WARNING: $nfail pour polygon(s) could not be triangulated (use Wireframe mode for them).")

    # ── component bodies (nominal blocks over the pads; click one to select it) ─
    body_top = 0.0
    body_bot = 0.0
    bodyinfo = Dict{String,Tuple{Float32,Float32,String,Float32,Float32}}()   # ref → (x, y, layer, h, sign)
    edge_pts = Dict{String,Vector{Point3f}}()
    for c in board.components
        haskey(st.layer_on, c.layer) || continue
        bb = body_box(c)
        bb === nothing && continue
        ring, h = bb
        sgn = startswith(c.layer, "B") ? -1f0 : 1f0      # bottom-side parts hang below the board
        sgn > 0 ? (body_top = max(body_top, h)) : (body_bot = max(body_bot, h))
        ctr = sum(ring) / 4
        bodyinfo[c.ref] = (ctr[1], ctr[2], c.layer, h, sgn)
        vs = Point3f[Point3f(p[1], p[2], 0f0) for p in ring]
        append!(vs, Point3f[Point3f(p[1], p[2], sgn * h) for p in ring])
        fs = [GB.GLTriangleFace(1, 2, 3), GB.GLTriangleFace(1, 3, 4),
              GB.GLTriangleFace(5, 6, 7), GB.GLTriangleFace(5, 7, 8)]
        ep = get!(edge_pts, c.layer, Point3f[])
        for i in 1:4
            j = i % 4 + 1
            push!(fs, GB.GLTriangleFace(i, j, 4 + j), GB.GLTriangleFace(i, 4 + j, 4 + i))
            push!(ep, vs[i], vs[j], vs[4 + i], vs[4 + j], vs[i], vs[4 + i])
        end
        vis = lift((a, m) -> a && m == "Solid", st.layer_on[c.layer], st.modes[:bodies])
        colr = lift(s -> sel_component(st, s) == c.ref ? RGBf(0.72, 0.62, 0.10) : RGBf(0.05, 0.05, 0.06), st.sel)
        plt = mesh!(scene, GB.Mesh(vs, fs); color = colr, shading = NoShading, visible = vis)
        bindz!(plt, zcu[c.layer], 8u)
        pickmap[plt] = (:comp, c.ref)
    end
    for (lname, pts) in edge_pts
        vis = lift((a, m) -> a && m != "Off", st.layer_on[lname], st.modes[:bodies])
        p = linesegments!(scene, pts; color = RGBf(0.5, 0.5, 0.56), linewidth = 1, visible = vis)
        bindz!(p, zcu[lname], 8u)
    end

    # ── via barrels ──────────────────────────────────────────────────────────
    idx = Dict(L.name => L.idx for L in layers)
    barrels = Tuple{Float32,Float32,String,String}[]
    for v in board.vias
        ids = [(idx[l], l) for l in v.layers if haskey(idx, l)]
        length(ids) < 2 && continue
        (a, la), (b, lb) = minimum(ids), maximum(ids)
        a == b && continue
        push!(barrels, (Float32(v.pos.x), Float32(-v.pos.y), la, lb))
    end
    if !isempty(barrels)
        bpts = lift(exag) do e
            [p for (x, y, la, lb) in barrels for p in (Point3f(x, y, zcu[la] * e), Point3f(x, y, zcu[lb] * e))]
        end
        linesegments!(scene, bpts; color = RGBf(0.8, 0.8, 0.8), linewidth = 1.0,
                      visible = lift(m -> m != "Off", st.modes[:vias]))
    end

    # ── board outline at top and bottom copper ───────────────────────────────
    opts = Point3f[]
    for pl in board.outline
        for p in pl; push!(opts, Point3f(p.x, -p.y, 0)); end
        push!(opts, Point3f(NaN, NaN, NaN))
    end
    if !isempty(opts)
        for L in unique([layers[1], layers[end]])
            p = lines!(scene, opts; color = :yellow, linewidth = 1.5, visible = st.show_outline)
            bindz!(p, zcu[L.name], 8u)
        end
    end

    # ── dielectric slabs (board bounding box; translucent) ───────────────────
    if !isempty(slabs)
        w, h = bx1 - bx0, by1 - by0
        edges = Point3f[]
        corners = [Point3f(bx0, by0, 0), Point3f(bx1, by0, 0), Point3f(bx1, by1, 0), Point3f(bx0, by1, 0)]
        for i in 1:4
            ci, cj = corners[i], corners[i == 4 ? 1 : i + 1]
            push!(edges, ci, cj, Point3f(ci[1], ci[2], 1), Point3f(cj[1], cj[2], 1), ci, Point3f(ci[1], ci[2], 1))
        end
        for (zbot, ztop, _) in slabs
            th = ztop - zbot
            bx = mesh!(scene, Rect3f(Vec3f(bx0, by0, 0), Vec3f(w, h, 1)); color = RGBAf(0.25, 0.65, 0.35, 0.10),
                       shading = NoShading, transparency = true, visible = st.show_diel)
            ed = linesegments!(scene, edges; color = RGBAf(0.4, 0.8, 0.5, 0.5), linewidth = 1, visible = st.show_diel)
            for p in (bx, ed)
                on(exag; update = true) do e
                    scale!(p, 1, 1, th * e)
                    translate!(p, 0, 0, zbot * e)
                end
            end
        end
    end

    # ── scale bar (under the board, bottom-left) ─────────────────────────────
    target = (bx1 - bx0) / 5
    nice = [1, 2, 5, 10, 20, 25, 50, 100, 200, 500]
    L_bar = Float32(nice[argmin(abs.(nice .- target))])
    ybar = Float32(by0 - 0.06 * span)
    bar = lift(exag) do e
        z = Float32(zmin * e)
        Point3f[Point3f(bx0, ybar, z), Point3f(bx0 + L_bar, ybar, z),
                Point3f(bx0, ybar - 0.4, z), Point3f(bx0, ybar + 0.4, z),
                Point3f(bx0 + L_bar, ybar - 0.4, z), Point3f(bx0 + L_bar, ybar + 0.4, z)]
    end
    linesegments!(scene, bar; color = :gray80, linewidth = 2)
    text!(scene, lift(b -> b[1] + Point3f(L_bar / 2, -0.8, 0), bar); text = "$(Int(L_bar)) mm",
          align = (:center, :top), color = :gray80, fontsize = 13)

    # ── element markers (float above the part) ───────────────────────────────
    mk = lift(st.rev, exag, st.show_passive_markers) do _, e, showp
        pts = Point3f[]; cols = RGBf[]
        nper = Dict{String,Int}()
        for el in st.setup.elements
            KIND_SPECS[el.kind].group == :passive && !showp && continue
            bi = get(bodyinfo, el.ref, nothing)
            bi === nothing && continue
            x, y, lname, h, sgn = bi
            k = nper[el.ref] = get(nper, el.ref, 0) + 1
            push!(pts, Point3f(x + (k - 1) * 0.9f0, y, zcu[lname] * e + sgn * (h + 0.5f0)))
            push!(cols, KIND_COLORS[el.kind])
        end
        isempty(pts) && (push!(pts, Point3f(NaN, NaN, NaN)); push!(cols, RGBf(1, 1, 1)))
        (pts, cols)
    end
    scatter!(scene, lift(m -> m[1], mk); color = lift(m -> m[2], mk), markersize = 14,
             strokecolor = :white, strokewidth = 1, depth_shift = -0.01f0)

    bbox() = begin
        e = exag[]
        zlo = zmin * e - body_bot - 0.3
        zhi = zmax * e + body_top + 1.0
        Rect3f(Vec3f(bx0, ybar - 2, zlo), Vec3f(bx1 - bx0, by1 - ybar + 2, zhi - zlo))
    end

    # CPU picking of copper: cast the cursor ray onto each visible copper plane (nearest
    # first) and test pads → vias → traces → pours. Unlike GPU picking this is not blocked
    # by the translucent dielectric or line overlays.
    pickdata = [[(cat, rings, nets, map(ring_bbox, rings))
                 for (cat, rings, nets) in ((:pads, L.pads.rings, L.pads.nets), (:vias, L.vias.rings, L.vias.nets),
                                            (:traces, L.traces.rings, L.traces.nets), (:pours, L.pours, L.pour_nets))
                 if !isempty(rings)] for L in layers]
    function raycast()
        ray = GLMakie.Makie.ray_at_cursor(scene)
        o, d = ray.origin, ray.direction
        abs(d[3]) < 1e-12 && return nothing
        e = exag[]
        cands = Tuple{Float64,Int}[]
        for (i, L) in enumerate(layers)
            st.layer_on[L.name][] || continue
            t = (zcu[L.name] * e - o[3]) / d[3]
            t > 0 && push!(cands, (t, i))
        end
        sort!(cands)
        for (t, i) in cands
            x, y = o[1] + t * d[1], o[2] + t * d[2]
            for (cat, rings, nets, bbs) in pickdata[i]
                st.modes[cat][] == "Off" && continue
                for k in eachindex(rings)
                    b = bbs[k]
                    (b[1] <= x <= b[3] && b[2] <= y <= b[4]) || continue
                    if inpoly(x, y, rings[k]) && !isempty(nets[k])
                        return (net = nets[k], layer = layers[i].name, x = x, y = -y)
                    end
                end
            end
        end
        return nothing
    end
    # ── DC result overlay: a colour image per copper layer + coloured traces ─
    # Drawn opaque (fully transparent cells are discarded by the shaders, so only copper
    # shows) and twice: just above each layer for viewing from the top, and just below it
    # for viewing from the bottom.
    overlay_plots = Any[]
    cmap = OVERLAY_CMAP
    function set_overlay!(_...)
        foreach(p -> delete!(scene, p), overlay_plots)
        empty!(overlay_plots)
        mode = st.result_mode[]
        mode == "Off" && return
        mode == AC_MODE && return set_ac_overlay!()
        is_si_mode(mode) && return set_si_overlay!()
        res = st.result[]
        (res === nothing || !res.ok) && return
        rail = shown_rail(st, res)
        lo, hi = overlay_range(res, mode; net = rail)
        logscale = mode == "Current density"
        frac(x) = logscale ? (log10(max(x, lo)) - log10(lo)) / (log10(hi) - log10(lo)) : (x - lo) / (hi - lo)
        col(x) = isnan(x) ? RGBAf(0, 0, 0, 0) : (c = cmap[clamp(frac(x), 0, 1)]; RGBAf(c.r, c.g, c.b, 1))
        gr = res.grid
        xr = gr.x0 .. (gr.x0 + gr.nx * gr.h)
        yr = -(gr.y0 + gr.ny * gr.h) .. -gr.y0                  # plot y = −KiCad y
        for (li, lname) in enumerate(res.layers)
            haskey(st.layer_on, lname) || continue
            data = mode == "Voltage" ? voltage_map(res, li, rail) : mode == "IR drop" ? res.drop[li] : res.jden[li]
            if any(!isnan, data)
                img = [col(data[i, gr.ny + 1 - j]) for i in 1:gr.nx, j in 1:gr.ny]
                for side in (1, -1)
                    p = image!(scene, xr, yr, img; interpolate = false, visible = st.layer_on[lname])
                    bindz!(p, zcu[lname], side * 5u)
                    push!(overlay_plots, p)
                end
            end
            pts = Point3f[]; cs = RGBAf[]
            for t in res.traces
                t.layer == li || continue
                mode == "Voltage" && t.net != rail && continue
                push!(pts, Point3f(t.xa, -t.ya, 0), Point3f(t.xb, -t.yb, 0))
                if mode == "Voltage"
                    push!(cs, col(t.va), col(t.vb))
                elseif mode == "IR drop"
                    push!(cs, col(t.drop_a), col(t.drop_b))
                else
                    c = col(Float32(t.J)); push!(cs, c, c)
                end
            end
            if !isempty(pts)
                for side in (1, -1)
                    p = linesegments!(scene, pts; color = cs, linewidth = 4, visible = st.layer_on[lname])
                    bindz!(p, zcu[lname], side * 6u)
                    push!(overlay_plots, p)
                end
            end
        end
    end
    # AC: |V| per cell for 1 A driven at the selected port, at the selected frequency
    function set_ac_overlay!()
        res = st.ac_result[]
        (res === nothing || !res.ok || isempty(res.ports) || st.ac_freq[] <= 0) && return
        p = clamp(st.ac_port[], 1, length(res.ports))
        maps, (lo, hi) = ac_map(res, p, st.ac_freq[])
        col(x) = isnan(x) ? RGBAf(0, 0, 0, 0) : (c = cmap[clamp((x - lo) / (hi - lo), 0, 1)]; RGBAf(c.r, c.g, c.b, 1))
        gr = res.grid
        xr = gr.x0 .. (gr.x0 + gr.nx * gr.h)
        yr = -(gr.y0 + gr.ny * gr.h) .. -gr.y0
        for (li, lname) in enumerate(res.layers)
            (haskey(st.layer_on, lname) && any(!isnan, maps[li])) || continue
            img = [col(maps[li][i, gr.ny + 1 - j]) for i in 1:gr.nx, j in 1:gr.ny]
            for side in (1, -1)
                pl = image!(scene, xr, yr, img; interpolate = false, visible = st.layer_on[lname])
                bindz!(pl, zcu[lname], side * 5u)
                push!(overlay_plots, pl)
            end
        end
    end
    # SI: signal traces coloured by impedance / target check / reference type, and finding markers
    function set_si_overlay!()
        res = st.si_result[]
        (res === nothing || !res.ok) && return
        mode = st.result_mode[]
        lo, hi = si_overlay_range(res)
        zcol(z) = isnan(z) ? rgba(SI_STATUS_COLORS[:noref]) : (c = cmap[clamp((z - lo) / (hi - lo), 0, 1)]; RGBAf(c.r, c.g, c.b, 1))
        for lname in res.layers
            haskey(st.layer_on, lname) || continue
            pts = Point3f[]; cs = RGBAf[]
            for p in res.pieces
                p.layer == lname || continue
                push!(pts, Point3f(p.xa, -p.ya, 0), Point3f(p.xb, -p.yb, 0))
                c = mode == "SI impedance" ? zcol(impedance_of(p)) :
                    mode == "SI vs target" ? rgba(SI_STATUS_COLORS[piece_status(p)]) : rgba(SI_KIND_COLORS[p.kind])
                push!(cs, c, c)
            end
            isempty(pts) && continue
            for side in (1, -1)
                pl = linesegments!(scene, pts; color = cs, linewidth = 4, visible = st.layer_on[lname])
                bindz!(pl, zcu[lname], side * 6u)
                push!(overlay_plots, pl)
            end
        end
        # finding markers (located findings only), the highlighted one ringed
        sel = st.si_issue[]
        notes = get(st.setup.view, "si_show_notes", false) == true
        for (k, iss) in enumerate(res.issues)
            isempty(iss.spots) && continue
            iss.severity == :info && !notes && k != sel && continue
            lname = isempty(iss.layer) ? first(res.layers) : iss.layer
            haskey(zcu, lname) || continue
            pts = [Point3f(x, -y, 0) for (x, y) in iss.spots]
            c = SEVERITY_COLORS[iss.severity]
            pl = scatter!(scene, pts; color = rgba(c, k == sel ? 1f0 : 0.85f0), markersize = k == sel ? 20 : 11,
                          marker = :diamond, strokecolor = k == sel ? :white : RGBf(0.1, 0.1, 0.1), strokewidth = k == sel ? 2 : 1,
                          depth_shift = -0.05f0, visible = st.layer_on[lname])
            bindz!(pl, zcu[lname], 8u)
            push!(overlay_plots, pl)
        end
    end
    onany(set_overlay!, st.result, st.result_mode, st.result_net, st.ac_result, st.ac_freq, st.ac_port,
          st.si_result, st.si_issue)

    return BoardScene(ls, scene, cam, pickmap, bbox, raycast, Ref{Any}(nothing), Ref(:iso))
end

# ─────────────────────────────────────────────────────────────────────────────
# Picking
# ─────────────────────────────────────────────────────────────────────────────
function _picked(bs::BoardScene)
    plt, i = pick(bs.scene)
    plt === nothing && return nothing
    info = get(bs.pickmap, plt, nothing)
    info === nothing && return nothing
    return plt, i, info
end

"GPU pick, but only if it landed on a component body."
function _picked_body(bs::BoardScene)
    r = _picked(bs)
    (r === nothing || r[3][1] != :comp) && return nothing
    return r
end

"What is under the cursor: (:comp, ref) for a component body, else (:net, name) for copper, else nothing."
function pick_target(bs::BoardScene)
    r = _picked_body(bs)
    r !== nothing && return (:comp, r[3][2])
    h = bs.raycast()
    return h === nothing ? nothing : (:net, h.net)
end

fmt_xy(x, y) = "x $(round(x, digits = 2))  y $(round(y, digits = 2)) mm"

"Status-bar text for the cursor position, or nothing when not over the board."
function hover_info(bs::BoardScene, st::UIState)
    r = _picked_body(bs)
    if r !== nothing
        plt, i, info = r
        p = try
            GLMakie.Makie.position_on_plot(plt, i)
        catch
            Point3d(NaN)
        end
        c = get(st.comps, info[2], nothing)
        what = info[2] * (c === nothing || isempty(c.value) ? "" : " ($(c.value))")
        return any(isnan, p) ? what : fmt_xy(p[1], -p[2]) * "  ·  " * what
    end
    h = bs.raycast()
    h === nothing && return nothing
    s = fmt_xy(h.x, h.y) * "  ·  " * h.layer * "  ·  " * h.net * " [" * CLASS_TAGS[netclass(st.setup, h.net)] * "]"
    acr = st.ac_result[]
    if st.result_mode[] == AC_MODE && acr !== nothing && acr.ok && st.ac_freq[] > 0
        li = findfirst(==(h.layer), acr.layers)
        maps, _ = ac_map(acr, clamp(st.ac_port[], 1, length(acr.ports)), st.ac_freq[])
        i, j = floor(Int, (h.x - acr.grid.x0) / acr.grid.h) + 1, floor(Int, (h.y - acr.grid.y0) / acr.grid.h) + 1
        if li !== nothing && 1 <= i <= acr.grid.nx && 1 <= j <= acr.grid.ny && !isnan(maps[li][i, j])
            s *= "  ·  |V| " * format_si(maps[li][i, j], "Ω") * " per A at " * format_si(st.ac_freq[], "Hz")
        end
        return s
    end
    sir = st.si_result[]
    if is_si_mode(st.result_mode[]) && sir !== nothing && sir.ok
        best, bd = nothing, Inf
        for p in sir.pieces
            (p.net == h.net && p.layer == h.layer) || continue
            vx, vy = p.xb - p.xa, p.yb - p.ya
            t = clamp(((h.x - p.xa) * vx + (h.y - p.ya) * vy) / max(vx^2 + vy^2, 1e-12), 0, 1)
            d = hypot(h.x - p.xa - t * vx, h.y - p.ya - t * vy)
            d < bd && (best = p; bd = d)
        end
        if best !== nothing && bd <= best.w / 2 + 0.05
            p = best
            z = isnan(p.Zdiff) ? (isnan(p.Z0) ? "no reference" : "Z0 " * string(round(p.Z0, digits = 1)) * " Ω") :
                                 "Zdiff " * string(round(p.Zdiff, digits = 1)) * " Ω (gap " * string(round(p.gap, digits = 3)) * ")"
            s *= "  ·  " * z * "  ·  " * SI_KIND_LABEL[p.kind] * (isempty(p.ref) ? "" : " → " * p.ref) *
                 (isnan(p.cpw) ? "" : "  ·  coplanar gap " * string(round(p.cpw, digits = 2))) *
                 "  ·  w " * string(round(p.w, digits = 3)) * "  ·  " * string(round(p.delay * 1e9, digits = 2)) * " ps/mm" *
                 (isnan(p.target) ? "" : "  ·  target " * string(round(Int, p.target)) * " Ω")
        end
        return s
    end
    res = st.result[]
    if res !== nothing && st.result_mode[] in ("Voltage", "IR drop", "Current density")
        pr = dc_probe(res, h.layer, h.x, h.y)
        if pr !== nothing && pr.net == h.net
            s *= "  ·  " * format_si(pr.V, "V"; digits = 6) *
                 (isnan(pr.drop_mV) ? "" : "  Δ " * format_si(pr.drop_mV * 1e-3, "V")) *
                 "  J " * string(round(pr.J; sigdigits = 3)) * " A/mm²"
        end
    end
    return s
end

end # module
