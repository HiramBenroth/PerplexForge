module Geometry

# GUI-free board geometry shared by the 3D view and the solvers. All coordinates here
# are KiCad's (mm, Y pointing down) unless a function says otherwise.

using ..BoardParser: BoardData, Pad, Component

export rot, pad_shape, pad_center, pad_polygon, pad_on, circle_polygon, layer_sort_key, copper_layers,
       stack_geometry, copper_thickness, board_extent

"KiCad rotation of a local offset by `deg` (counter-clockwise on screen, Y down)."
function rot(x, y, deg)
    θ = deg2rad(deg)
    c, s = cos(θ), sin(θ)
    return (x * c + y * s, -x * s + y * c)
end

"Pad outline in its own frame (unrotated), as (x, y) tuples."
function pad_shape(p::Pad)
    w, h = p.size_x / 2, p.size_y / 2
    pts = Tuple{Float64,Float64}[]
    if p.shape == "circle"
        for k in 0:19
            t = 2π * k / 20
            push!(pts, (w * cos(t), h * sin(t)))
        end
    elseif p.shape == "oval" || p.shape == "roundrect"
        r = p.shape == "oval" ? min(w, h) : 2 * min(w, h) * p.rratio
        r = clamp(r, 0.0, min(w, h))
        corners = ((w - r, h - r), (-(w - r), h - r), (-(w - r), -(h - r)), (w - r, -(h - r)))
        for (q, (cx, cy)) in enumerate(corners), k in 0:4
            t = (q - 1) * π / 2 + k * (π / 2) / 4
            push!(pts, (cx + r * cos(t), cy + r * sin(t)))
        end
    else
        pts = [(w, h), (-w, h), (-w, -h), (w, -h)]
    end
    return pts
end

"Absolute pad centre."
function pad_center(c::Component, p::Pad)
    lx, ly = rot(p.local_pos.x, p.local_pos.y, c.angle)
    return c.pos.x + lx, c.pos.y + ly
end

"Absolute pad outline: (xs, ys)."
function pad_polygon(c::Component, p::Pad)
    cx, cy = pad_center(c, p)
    xs = Float64[]; ys = Float64[]
    for (x, y) in pad_shape(p)
        rx, ry = rot(x, y, p.angle)          # pad angle in the file is already absolute
        push!(xs, cx + rx); push!(ys, cy + ry)
    end
    return xs, ys
end

"Is a pad with layer list `pl` present on copper layer `lname`?"
function pad_on(pl::Vector{String}, lname)
    for l in pl
        (l == "*.Cu" || l == lname) && return true
        l == "F&B.Cu" && (lname == "F.Cu" || lname == "B.Cu") && return true
    end
    return false
end

circle_polygon(cx, cy, r; n = 16) = ([cx + r * cos(2π * k / n) for k in 0:n-1], [cy + r * sin(2π * k / n) for k in 0:n-1])

function layer_sort_key(n)
    n == "F.Cu" && return (0, 0)
    n == "B.Cu" && return (2, 0)
    m = match(r"^In(\d+)\.Cu$", n)
    return (1, m === nothing ? 999 : parse(Int, m.captures[1]))
end

"Copper layers used by the board, top to bottom."
function copper_layers(board::BoardData)
    s = Set{String}()
    is_cu(n) = endswith(n, ".Cu") && !startswith(n, "*") && !occursin("&", n)
    wildcard = false
    for t in board.traces;  is_cu(t.layer) && push!(s, t.layer); end
    for z in board.zones;   is_cu(z.layer) && push!(s, z.layer); end
    for v in board.vias, l in v.layers
        is_cu(l) && push!(s, l)
    end
    for c in board.components, p in c.pads, l in p.layers
        is_cu(l) && push!(s, l)
        (l == "*.Cu" || l == "F&B.Cu") && (wildcard = true)
    end
    for st in board.stackup
        st.kind == "copper" && is_cu(st.name) && push!(s, st.name)
    end
    wildcard && (push!(s, "F.Cu"); push!(s, "B.Cu"))
    isempty(s) && push!(s, "F.Cu")
    return sort!(collect(s); by = layer_sort_key)
end

"""
    stack_geometry(board, layer_names) -> (zcu, slabs, dielectric_defined)

Copper z (mm from the bottom, layer mid-plane) by layer name, dielectric slabs
[(zbot, ztop, name)], and whether the board has a real stackup. Without one, layers
are spread evenly over a nominal 1.6 mm.
"""
function stack_geometry(board::BoardData, names::Vector{String})
    zcu = Dict{String,Float64}()
    slabs = Tuple{Float64,Float64,String}[]
    phys = [s for s in board.stackup
            if s.kind == "copper" || s.kind == "core" || s.kind == "prepreg" || startswith(s.name, "dielectric")]
    if !isempty(phys)
        total = sum(s.thickness for s in phys)
        d = 0.0
        for s in phys
            if s.kind == "copper"
                zcu[s.name] = total - (d + s.thickness / 2)
            else
                push!(slabs, (total - d - s.thickness, total - d, s.name))
            end
            d += s.thickness
        end
    end
    nl = length(names)
    for (i, n) in enumerate(names)
        haskey(zcu, n) || (zcu[n] = nl == 1 ? 0.0 : (nl - i) * 1.6 / (nl - 1))
    end
    return zcu, slabs, !isempty(slabs)
end

"Copper thickness (mm) of a layer from the stackup, or `default`."
function copper_thickness(board::BoardData, lname; default = 0.035)
    for s in board.stackup
        s.name == lname && s.kind == "copper" && s.thickness > 0 && return s.thickness
    end
    return default
end

"Board extent in KiCad coordinates (x0, x1, y0, y1): the Edge.Cuts outline, else the copper."
function board_extent(board::BoardData)
    xs = Float64[]; ys = Float64[]
    for pl in board.outline, p in pl
        push!(xs, p.x); push!(ys, p.y)
    end
    if isempty(xs)
        for t in board.traces
            push!(xs, t.start_pt.x, t.end_pt.x); push!(ys, t.start_pt.y, t.end_pt.y)
        end
        for z in board.zones, poly in z.fills, p in poly
            push!(xs, p.x); push!(ys, p.y)
        end
        for c in board.components
            push!(xs, c.pos.x); push!(ys, c.pos.y)
        end
    end
    isempty(xs) && return (0.0, 100.0, 0.0, 100.0)
    return (minimum(xs), maximum(xs), minimum(ys), maximum(ys))
end

end # module
