module BoardParser

using Printf

export Point, Trace, Via, Zone, Pad, Component, StackupLayer, BoardData
export parse_kicad_board

# ─────────────────────────────────────────────────────────────────────────────
# Data model
# ─────────────────────────────────────────────────────────────────────────────
struct Point
    x::Float64
    y::Float64
end

struct Trace
    start_pt::Point
    end_pt::Point
    width::Float64
    layer::String
    net_name::String
end

struct Via
    pos::Point
    size::Float64
    drill::Float64
    layers::Vector{String}
    net_name::String
end

struct Zone
    layer::String
    net_name::String
    boundary::Vector{Point}              # the zone's drawn outline
    fills::Vector{Vector{Point}}         # actual filled copper (with relief cuts, thermals, clearances)
end

struct StackupLayer
    name::String
    kind::String          # "copper", "core", "prepreg", "Top Solder Mask", ...
    thickness::Float64    # mm
    material::String
    epsilon_r::Float64
    loss_tangent::Float64
end

struct Pad
    pad_num::String
    pad_type::String
    shape::String
    local_pos::Point
    angle::Float64            # absolute pad orientation as stored by KiCad
    size_x::Float64
    size_y::Float64
    rratio::Float64           # roundrect corner ratio
    layers::Vector{String}    # e.g. ["F.Cu","F.Paste","F.Mask"] or ["*.Cu", ...]
    net_name::String
end

struct Component
    ref::String
    footprint_name::String
    value::String             # "10k", "100n", "STM32F405RGT6", … ("" if absent)
    pos::Point
    angle::Float64
    layer::String
    pads::Vector{Pad}
end

mutable struct BoardData
    width::Float64
    height::Float64
    nets::Set{String}
    components::Vector{Component}
    traces::Vector{Trace}
    vias::Vector{Via}
    zones::Vector{Zone}
    outline::Vector{Vector{Point}}   # Edge.Cuts polylines
    stackup::Vector{StackupLayer}    # empty if the board has no stackup defined
end

# ─────────────────────────────────────────────────────────────────────────────
# Small regex helpers
# ─────────────────────────────────────────────────────────────────────────────

# Matches (net 14 "GND")  |  (net "GND")  |  (net 14)
const NET_RE = r"\(net\s+(?:(\d+)\s*(?:\"([^\"]*)\")?|\"([^\"]*)\")\s*\)"

# Tokens that start a new top-level item in a .kicad_pcb (used to end a block)
const TOP_LEVEL = "(?:segment|via|arc|zone|gr_[a-z]+|footprint|module|dimension|group|target|generated)"

"Return the text of every top-level `(kind ...)` item."
function top_blocks(content::String, kind::AbstractString)
    re = Regex("\\(" * kind * "\\b.*?(?=\\(" * TOP_LEVEL * "\\b|\\z)", "s")
    return [m.match for m in eachmatch(re, content)]
end

function xy_of(blk::AbstractString, key::AbstractString)
    m = match(Regex("\\(" * key * "\\s+([-\\d.]+)\\s+([-\\d.]+)"), blk)
    m === nothing && return nothing
    return Point(parse(Float64, m.captures[1]), parse(Float64, m.captures[2]))
end

function num_of(blk::AbstractString, key::AbstractString, default = 0.0)
    m = match(Regex("\\(" * key * "\\s+([-\\d.]+)\\)"), blk)
    return m === nothing ? default : parse(Float64, m.captures[1])
end

function str_of(blk::AbstractString, key::AbstractString)
    m = match(Regex("\\(" * key * "\\s+\"([^\"]+)\"\\)"), blk)
    return m === nothing ? nothing : string(m.captures[1])
end

function layers_of(blk::AbstractString)
    m = match(r"\(layers\s+([^)]*)\)", blk)
    m === nothing && return String[]
    return [string(x.captures[1]) for x in eachmatch(r"\"([^\"]+)\"", m.captures[1])]
end

function net_name(blk::AbstractString, idmap::Dict{Int,String})
    m = match(NET_RE, blk)
    m === nothing && return "UNCONNECTED"
    m.captures[3] !== nothing && return string(m.captures[3])
    m.captures[2] !== nothing && return string(m.captures[2])
    id = parse(Int, m.captures[1])
    return get(idmap, id, "net$id")
end

"Points along the circular arc through start / mid / end."
function arc_points(s::Point, m::Point, e::Point; n::Int = 16)
    d = 2 * (s.x * (m.y - e.y) + m.x * (e.y - s.y) + e.x * (s.y - m.y))
    abs(d) < 1e-12 && return [s, e]
    s2 = s.x^2 + s.y^2; m2 = m.x^2 + m.y^2; e2 = e.x^2 + e.y^2
    ux = (s2 * (m.y - e.y) + m2 * (e.y - s.y) + e2 * (s.y - m.y)) / d
    uy = (s2 * (e.x - m.x) + m2 * (s.x - e.x) + e2 * (m.x - s.x)) / d
    r  = hypot(s.x - ux, s.y - uy)
    a0 = atan(s.y - uy, s.x - ux)
    a1 = atan(m.y - uy, m.x - ux)
    a2 = atan(e.y - uy, e.x - ux)
    ccw(a, b) = mod(b - a, 2π)
    total = ccw(a0, a1) <= ccw(a0, a2) ? ccw(a0, a2) : -mod(a0 - a2, 2π)
    return [Point(ux + r * cos(a0 + total * k / n), uy + r * sin(a0 + total * k / n)) for k in 0:n]
end

# ─────────────────────────────────────────────────────────────────────────────
# Section parsers
# ─────────────────────────────────────────────────────────────────────────────

function parse_outline(content::String)
    lines = Vector{Vector{Point}}()
    for blk in top_blocks(content, "gr_(?:line|rect|arc|circle)")
        occursin("Edge.Cuts", blk) || continue
        kind = match(r"^\(gr_(\w+)", blk).captures[1]
        if kind == "line"
            s, e = xy_of(blk, "start"), xy_of(blk, "end")
            (s === nothing || e === nothing) && continue
            push!(lines, [s, e])
        elseif kind == "rect"
            s, e = xy_of(blk, "start"), xy_of(blk, "end")
            (s === nothing || e === nothing) && continue
            push!(lines, [s, Point(e.x, s.y), e, Point(s.x, e.y), s])
        elseif kind == "arc"
            s, m, e = xy_of(blk, "start"), xy_of(blk, "mid"), xy_of(blk, "end")
            (s === nothing || m === nothing || e === nothing) && continue
            push!(lines, arc_points(s, m, e))
        elseif kind == "circle"
            c, e = xy_of(blk, "center"), xy_of(blk, "end")
            (c === nothing || e === nothing) && continue
            r = hypot(e.x - c.x, e.y - c.y)
            push!(lines, [Point(c.x + r * cos(2π * k / 48), c.y + r * sin(2π * k / 48)) for k in 0:48])
        end
    end
    return lines
end

function outline_size(outline)
    isempty(outline) && return 0.0, 0.0
    xs = [p.x for pl in outline for p in pl]
    ys = [p.y for pl in outline for p in pl]
    return maximum(xs) - minimum(xs), maximum(ys) - minimum(ys)
end

function parse_components(content::String, idmap::Dict{Int,String})
    components = Component[]
    fp_re = r"\((?:footprint|module)\s+\"([^\"]+)\"(.*?)\)(?=\s*\((?:footprint|module|gr_|segment|via|arc|zone|dimension|target)|$)"s
    for fp_match in eachmatch(fp_re, content)
        fp_name = fp_match.captures[1]
        fp_body = fp_match.captures[2]

        ref_m = match(r"\(fp_text\s+reference\s+\"([^\"]+)\"", fp_body)
        if ref_m === nothing
            ref_m = match(r"\(property\s+\"Reference\"\s+\"([^\"]+)\"", fp_body)  # KiCad 8+
        end
        ref = ref_m !== nothing ? string(ref_m.captures[1]) : "UNKNOWN"

        val_m = match(r"\(property\s+\"Value\"\s+\"([^\"]*)\"", fp_body)            # KiCad 8+
        val_m === nothing && (val_m = match(r"\(fp_text\s+value\s+\"?([^\"\s)]*)", fp_body))
        value = val_m !== nothing ? string(val_m.captures[1]) : ""

        at_m = match(r"\(at\s+([-\d.]+)\s+([-\d.]+)(?:\s+([-\d.]+))?\)", fp_body)
        layer_m = match(r"\(layer\s+\"([^\"]+)\"\)", fp_body)
        at_m === nothing && continue

        x = parse(Float64, at_m.captures[1])
        y = parse(Float64, at_m.captures[2])
        angle = at_m.captures[3] !== nothing ? parse(Float64, at_m.captures[3]) : 0.0
        layer = layer_m !== nothing ? string(layer_m.captures[1]) : "UNKNOWN"

        pads = Pad[]
        for pm in eachmatch(r"\(pad\s+\"([^\"]*)\"\s+([a-zA-Z_]+)\s+([a-zA-Z_]+)(.*?)(?=\(pad\s|\z)"s, fp_body)
            pad_body = pm.captures[4]

            at = match(r"\(at\s+([-\d.]+)\s+([-\d.]+)(?:\s+([-\d.]+))?\)", pad_body)
            px = at !== nothing ? parse(Float64, at.captures[1]) : 0.0
            py = at !== nothing ? parse(Float64, at.captures[2]) : 0.0
            pa = (at !== nothing && at.captures[3] !== nothing) ? parse(Float64, at.captures[3]) : 0.0

            size_m = match(r"\(size\s+([-\d.]+)\s+([-\d.]+)\)", pad_body)
            sx = size_m !== nothing ? parse(Float64, size_m.captures[1]) : 0.0
            sy = size_m !== nothing ? parse(Float64, size_m.captures[2]) : 0.0

            rr = num_of(pad_body, "roundrect_rratio", 0.25)

            push!(pads, Pad(string(pm.captures[1]), string(pm.captures[2]), string(pm.captures[3]),
                            Point(px, py), pa, sx, sy, rr, layers_of(pad_body),
                            net_name(pad_body, idmap)))
        end

        push!(components, Component(ref, string(fp_name), value, Point(x, y), angle, layer, pads))
    end
    return components
end

function parse_traces(content::String, idmap::Dict{Int,String})
    traces = Trace[]
    for blk in top_blocks(content, "segment")
        s, e = xy_of(blk, "start"), xy_of(blk, "end")
        layer = str_of(blk, "layer")
        (s === nothing || e === nothing || layer === nothing) && continue
        push!(traces, Trace(s, e, num_of(blk, "width"), layer, net_name(blk, idmap)))
    end
    # Curved tracks (KiCad 6+) → approximate with short straight segments
    for blk in top_blocks(content, "arc")
        s, m, e = xy_of(blk, "start"), xy_of(blk, "mid"), xy_of(blk, "end")
        layer = str_of(blk, "layer")
        (s === nothing || m === nothing || e === nothing || layer === nothing) && continue
        pts = arc_points(s, m, e; n = 12)
        w, nn = num_of(blk, "width"), net_name(blk, idmap)
        for i in 1:length(pts)-1
            push!(traces, Trace(pts[i], pts[i+1], w, layer, nn))
        end
    end
    return traces
end

function parse_vias(content::String, idmap::Dict{Int,String})
    vias = Via[]
    for blk in top_blocks(content, "via")
        at = xy_of(blk, "at")
        at === nothing && continue
        lays = layers_of(blk)
        isempty(lays) && (lays = ["F.Cu", "B.Cu"])
        push!(vias, Via(at, num_of(blk, "size", 0.6), num_of(blk, "drill", 0.3), lays, net_name(blk, idmap)))
    end
    return vias
end

function parse_zones(content::String, idmap::Dict{Int,String})
    zones = Zone[]
    for blk in top_blocks(content, "zone")
        nm = str_of(blk, "net_name")
        net = nm !== nothing ? nm : net_name(blk, idmap)

        occursin("(keepout", blk) && continue      # rule areas are not copper

        # The zone's drawn outline
        pr = findfirst(r"\(polygon\b", blk)
        outline_pts = pr === nothing ? Point[] : xy_list(balanced(blk, first(pr)))

        # The real copper: one filled_polygon per island, per layer
        fills = Dict{String,Vector{Vector{Point}}}()
        for fm in eachmatch(r"\(filled_polygon\b", blk)
            fblk = balanced(blk, fm.offset)          # balanced parens: keeps the last point
            fl = str_of(fblk, "layer")
            fl === nothing && continue
            poly = xy_list(fblk)
            length(poly) >= 3 && push!(get!(fills, fl, Vector{Vector{Point}}()), poly)
        end

        lays = layers_of(blk)
        if isempty(lays)
            l = str_of(blk, "layer")
            l === nothing && continue
            lays = [l]
        end
        for l in lays
            push!(zones, Zone(l, net, outline_pts, get(fills, l, Vector{Point}[])))
        end
    end
    return zones
end

# ─────────────────────────────────────────────────────────────────────────────
# Entry point (prints a launch log while it works)
# ─────────────────────────────────────────────────────────────────────────────
xy_list(s::AbstractString) =
    [Point(parse(Float64, m.captures[1]), parse(Float64, m.captures[2]))
     for m in eachmatch(r"\(xy\s+([-\d.]+)\s+([-\d.]+)\)", s)]

"The balanced-parenthesis item that starts at byte index `start`."
function balanced(s::AbstractString, start::Int)
    depth = 0
    i = start
    n = lastindex(s)
    while i <= n
        c = s[i]
        if c == '('
            depth += 1
        elseif c == ')'
            depth -= 1
            depth == 0 && return String(s[start:i])
        end
        i = nextind(s, i)
    end
    return String(s[start:end])
end

function parse_stackup(content::String)
    st = StackupLayer[]
    r = findfirst("(stackup", content)
    r === nothing && return st
    block = balanced(content, first(r))
    num(b, key) = (m = match(Regex("\\(" * key * "\\s+([-\\d.]+)"), b); m === nothing ? 0.0 : parse(Float64, m.captures[1]))
    pos = 1
    while true
        m = match(r"\(layer\s+\"([^\"]+)\"", block, pos)
        m === nothing && break
        blk = balanced(block, m.offset)
        pos = m.offset + ncodeunits(blk)
        push!(st, StackupLayer(string(m.captures[1]),
                               something(str_of(blk, "type"), ""),
                               num(blk, "thickness"),
                               something(str_of(blk, "material"), ""),
                               num(blk, "epsilon_r"),
                               num(blk, "loss_tangent")))
    end
    return st
end

function parse_kicad_board(file_path::String; verbose::Bool = true, echo_nets::Bool = true, logger = nothing)
    t0 = time()
    function say(msg)
        line = @sprintf("[%7.2fs] %s", time() - t0, msg)
        verbose && println(line)
        logger === nothing || logger(line)
    end

    say("Reading $(basename(file_path))")
    content = read(file_path, String)
    say("  $(round(sizeof(content) / 1024, digits = 1)) KB loaded")

    # 1. Nets (also builds the id → name table for KiCad versions that use numeric ids)
    say("Scanning nets...")
    idmap = Dict{Int,String}()
    nets = Set{String}()
    for m in eachmatch(NET_RE, content)
        name = m.captures[3] !== nothing ? m.captures[3] : m.captures[2]
        name === nothing && continue
        name = string(name)
        isempty(name) && continue
        m.captures[1] !== nothing && (idmap[parse(Int, m.captures[1])] = name)
        if !(name in nets)
            push!(nets, name)
            verbose && echo_nets && println("            + net ", lpad(length(nets), 4), "  ", name)
        end
    end
    say("  $(length(nets)) unique nets")

    say("Parsing board outline (Edge.Cuts)...")
    outline = parse_outline(content)
    width, height = outline_size(outline)
    say("  $(length(outline)) outline pieces, $(round(width, digits = 2)) × $(round(height, digits = 2)) mm")

    say("Parsing footprints and pads...")
    components = parse_components(content, idmap)
    npads = sum(length(c.pads) for c in components; init = 0)
    say("  $(length(components)) components, $npads pads")

    say("Parsing copper traces...")
    traces = parse_traces(content, idmap)
    say("  $(length(traces)) trace segments")

    say("Parsing vias...")
    vias = parse_vias(content, idmap)
    say("  $(length(vias)) vias")

    say("Parsing zones...")
    zones = parse_zones(content, idmap)
    nfill = sum(length(z.fills) for z in zones; init = 0)
    say("  $(length(zones)) zone/layer entries, $nfill filled polygons")
    for z in zones
        isempty(z.fills) && say("  WARNING: zone on $(z.layer) (net $(z.net_name)) has no fill data; refill (B) in KiCad and save")
    end

    say("Reading stackup...")
    stackup = parse_stackup(content)
    say(isempty(stackup) ? "  no stackup defined" : "  $(length(stackup)) stackup entries")

    say("Board parsed.")
    return BoardData(width, height, nets, components, traces, vias, zones, outline, stackup)
end

end # module
