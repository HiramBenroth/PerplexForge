module Inspector

# Selection-driven inspector (right dock): net class assignment, component details,
# and the lumped-element editor with its circuit symbol.

using GLMakie
using ..BoardParser: BoardData, Component
using ..SimSetups
using ..WorkbenchState
using ..Widgets

export build_inspector!, draw_symbol!, describe_net

const DIM   = RGBf(0.55, 0.55, 0.60)
const WIRE  = RGBf(0.82, 0.82, 0.88)
const NONE  = "(none)"

section!(p, h, r, text) = blk!(p, Label(h[r, 1:2], text; font = :bold, halign = :left, color = :gray65,
                                        fontsize = 12, tellwidth = false))
note!(p, h, r, text; color = :gray75, fontsize = 12) =
    blk!(p, Label(h[r, 1:2], text; halign = :left, justification = :left, color = color, fontsize = fontsize,
                  tellwidth = false))

"Plain-text statistics for a net."
function describe_net(board::BoardData, name)
    segs = [t for t in board.traces if t.net_name == name]
    len = sum(hypot(t.end_pt.x - t.start_pt.x, t.end_pt.y - t.start_pt.y) for t in segs; init = 0.0)
    npad = sum(count(p -> p.net_name == name, c.pads) for c in board.components; init = 0)
    nvia = count(v -> v.net_name == name, board.vias)
    npour = count(z -> z.net_name == name, board.zones)
    lays = sort!(unique([t.layer for t in segs]))
    return "Pads $npad · Vias $nvia · Pours $npour\nSegments $(length(segs)) · $(round(len, digits = 1)) mm" *
           (isempty(lays) ? "" : "\nLayers: " * join(lays, ", "))
end

function build_inspector!(p::DynPanel, st::UIState)
    kind, name = st.sel[]
    if kind == :net
        net_inspector!(p, st, name)
    elseif kind == :comp && haskey(st.comps, name)
        comp_inspector!(p, st, st.comps[name], nothing)
    elseif kind == :elem && (e = find_element(st, name)) !== nothing && haskey(st.comps, e.ref)
        comp_inspector!(p, st, st.comps[e.ref], e)
    else
        h = p.host
        section!(p, h, 1, "INSPECTOR")
        note!(p, h, 2, "Nothing selected.\n\n• Click copper in the 3D view to select its net.\n" *
                       "• Click a component body to open its lumped model.\n" *
                       "• Or pick from the Nets / Components / Setup lists.")
    end
    rowgap!(p.host, 6)
    return p
end

# ─────────────────────────────────────────────────────────────────────────────
# Net
# ─────────────────────────────────────────────────────────────────────────────
function net_inspector!(p::DynPanel, st::UIState, net::String)
    h = p.host
    cls = netclass(st.setup, net)
    r = 1
    section!(p, h, r, "NET"); r += 1
    blk!(p, Label(h[r, 1:2], net; font = :bold, fontsize = 18, halign = :left, tellwidth = false, color = :white)); r += 1
    note!(p, h, r, describe_net(st.board, net)); r += 1

    section!(p, h, r, "NET CLASS"); r += 1
    g = sub!(p, h[r, 1:2]); r += 1
    for (i, c) in enumerate(NET_CLASSES)
        active = c == cls
        b = blk!(p, Button(g[1, i]; label = CLASS_LABELS[c], padding = (4, 4, 5, 5), tellwidth = false, width = Relative(1),
                           buttoncolor = active ? darken(CLASS_COLORS[c], 0.7) : BTN_BG,
                           labelcolor = active ? :white : lighten(CLASS_COLORS[c], 0.3), fontsize = 13))
        on(b.clicks) do _
            if set_class!(st.setup, net, c)
                changed!(st; classes = true)
                st.say("Net $net → $(CLASS_LABELS[c])")
            end
            request!(st, :inspector)
        end
    end
    colgap!(g, 4)

    nf = length(st.filtered_nets)
    if 1 < nf < length(st.board.nets)
        b = blk!(p, Button(h[r, 1:2]; label = "Apply $(CLASS_LABELS[cls]) to all $nf filtered nets",
                           tellwidth = false, width = Relative(1), padding = (6, 6, 5, 5), fontsize = 12)); r += 1
        on(b.clicks) do _
            k = count(n -> set_class!(st.setup, n, cls), st.filtered_nets)
            k > 0 && changed!(st; classes = true)
            st.say("Set $k net(s) to $(CLASS_LABELS[cls]).")
            request!(st, :inspector)
        end
    end

    els = [e for e in st.setup.elements if e.net_pos == net || e.net_neg == net]
    section!(p, h, r, "ELEMENTS ON THIS NET ($(length(els)))"); r += 1
    if isempty(els)
        note!(p, h, r, "None. Select a component to add a VRM, sink or model."; color = DIM); r += 1
    end
    for e in first(els, 10)
        r = element_button!(p, st, h, r, e)
    end
    length(els) > 10 && (note!(p, h, r, "… $(length(els) - 10) more (see the Setup tab)"; color = DIM); r += 1)
end

function element_button!(p, st, h, r, e::Element; active = false)
    b = blk!(p, Button(h[r, 1:2]; label = KIND_TAGS[e.kind] * "  " * element_summary(e), tellwidth = false,
                       width = Relative(1), padding = (6, 6, 4, 4), fontsize = 12, halign = :left,
                       buttoncolor = active ? BTN_ACTIVE : RGBf(0.17, 0.17, 0.21),
                       labelcolor = lighten(KIND_COLORS[e.kind], 0.2)))
    id = e.id
    on(b.clicks) do _
        st.sel[] = (:elem, id)
    end
    return r + 1
end

# ─────────────────────────────────────────────────────────────────────────────
# Component (+ element editor)
# ─────────────────────────────────────────────────────────────────────────────
function comp_inspector!(p::DynPanel, st::UIState, c::Component, sel_el::Union{Nothing,Element})
    h = p.host
    s = st.setup
    r = 1
    section!(p, h, r, "COMPONENT"); r += 1
    blk!(p, Label(h[r, 1:2], rich(rich(c.ref; font = :bold, fontsize = 18, color = :white),
                                  rich("   " * c.value; color = :gray80, fontsize = 14));
                  halign = :left, tellwidth = false)); r += 1
    side = startswith(c.layer, "B") ? "bottom" : "top"
    note!(p, h, r, "$(c.footprint_name)\n$(side) side · $(length(c.pads)) pads"; color = DIM, fontsize = 11); r += 1

    nets = component_nets(c)
    if sel_el === nothing
        section!(p, h, r, "NETS ($(length(nets)))"); r += 1
        shown = sort(nets; by = x -> (findfirst(==(netclass(s, x[1])), NET_CLASSES), -x[2]))
        for (n, k) in first(shown, 8)
            cl = netclass(s, n)
            blk!(p, Label(h[r, 1:2], rich(rich(rpad(CLASS_TAGS[cl], 5); color = CLASS_COLORS[cl], font = :bold),
                                          rich(n), rich("   ×$k"; color = DIM));
                          halign = :left, tellwidth = false, fontsize = 12)); r += 1
        end
        length(shown) > 8 && (note!(p, h, r, "… $(length(shown) - 8) more"; color = DIM); r += 1)
    end

    mine = [e for e in s.elements if e.ref == c.ref]
    section!(p, h, r, "LUMPED ELEMENTS ($(length(mine)))"); r += 1
    for e in mine
        r = element_button!(p, st, h, r, e; active = sel_el !== nothing && e.id == sel_el.id)
    end

    g = sub!(p, h[r, 1:2]); r += 1
    opts = [(KIND_SPECS[k].label, k) for k in KIND_ORDER]
    guess = guess_kind(c, s)
    m = blk!(p, Menu(g[1, 1]; options = opts, default = KIND_SPECS[guess].label, tellwidth = false, width = Relative(1)))
    b = blk!(p, Button(g[1, 2]; label = "+ Add", padding = (12, 12, 5, 5), buttoncolor = RGBf(0.13, 0.42, 0.25)))
    colgap!(g, 6)
    on(b.clicks) do _
        kind = something(m.selection[], guess)
        e = default_element(kind, c, s)
        push!(s.elements, e)
        changed!(st)
        st.say("Added $(KIND_SPECS[kind].label) $(e.id) on $(c.ref): $(isempty(e.net_pos) ? "?" : e.net_pos) → $(isempty(e.net_neg) ? "?" : e.net_neg)")
        st.sel[] = (:elem, e.id)
    end

    sel_el === nothing || element_editor!(p, st, h, r, c, sel_el)
end

function element_editor!(p::DynPanel, st::UIState, h, r, c::Component, e::Element)
    s = st.setup
    spec = KIND_SPECS[e.kind]
    section!(p, h, r, "ELEMENT  $(e.id)"); r += 1

    # kind (changing it keeps the terminals, resets the values)
    g = sub!(p, h[r, 1:2]); r += 1
    blk!(p, Label(g[1, 1], "Kind"; halign = :left, width = 60))
    km = blk!(p, Menu(g[1, 2]; options = [(KIND_SPECS[k].label, k) for k in KIND_ORDER], default = spec.label,
                      tellwidth = false, width = Relative(1)))
    on(km.selection) do k
        (k === nothing || k == e.kind) && return
        ne = default_element(k, c, s)
        isempty(e.net_pos) || (ne.net_pos = e.net_pos)
        isempty(e.net_neg) || (ne.net_neg = e.net_neg)
        i = findfirst(x -> x === e, s.elements)
        i === nothing || (s.elements[i] = ne)
        changed!(st)
        st.say("$(e.id) is now $(KIND_SPECS[k].label) $(ne.id)")
        st.sel[] = (:elem, ne.id)
    end

    # circuit symbol
    ax = blk!(p, Axis(h[r, 1:2]; height = 170, backgroundcolor = PANEL_BG, limits = (-3.4, 3.4, -1.9, 1.75),
                      tellwidth = false)); r += 1
    hidedecorations!(ax); hidespines!(ax)
    for k in (:rectanglezoom, :scrollzoom, :dragpan, :limitreset)
        try deregister_interaction!(ax, k) catch end
    end
    draw_symbol!(ax, e)

    # terminals
    netopts = [n for (n, _) in component_nets(c)]
    if spec.group != :passive                         # sources may attach to a rail they don't touch directly
        for n in sort!(collect(keys(s.netclass)))
            s.netclass[n] in (:power, :ground) && !(n in netopts) && push!(netopts, n)
        end
    end
    opts = vcat([NONE], netopts)
    g = sub!(p, h[r, 1:2]); r += 1
    for (i, (field, tname)) in enumerate(((:net_pos, spec.terminals[1]), (:net_neg, spec.terminals[2])))
        cur = getfield(e, field)
        blk!(p, Label(g[i, 1], tname; halign = :left, width = 60))
        mm = blk!(p, Menu(g[i, 2]; options = opts, default = isempty(cur) ? NONE : cur, tellwidth = false, width = Relative(1)))
        on(mm.selection) do v
            v === nothing && return
            nv = v == NONE ? "" : v
            nv == getfield(e, field) && return
            setfield!(e, field, nv)
            changed!(st)
            request!(st, :inspector)
        end
    end
    rowgap!(g, 4)

    # parameters
    g = sub!(p, h[r, 1:2]); r += 1
    for (i, ps) in enumerate(spec.params)
        tag, tagc = ps.scope == :dc ? ("DC", RGBf(0.5, 0.85, 0.55)) : ps.scope == :ac ? ("AC", RGBf(0.55, 0.7, 0.95)) :
                                                                                   ("DC+AC", RGBf(0.8, 0.8, 0.5))
        blk!(p, Label(g[i, 1], ps.name; halign = :left, font = :bold, width = 40))
        v = get(e.params, ps.name, ps.default)
        tb = blk!(p, Textbox(g[i, 2]; stored_string = replace(format_si(v, ""), " " => ""), width = 90,
                             validator = str -> parse_si(str) !== nothing, tellwidth = false))
        blk!(p, Label(g[i, 3], ps.unit; halign = :left, width = 18))
        blk!(p, Label(g[i, 4], rich(rich(tag; color = tagc, font = :bold), rich("  " * ps.label; color = DIM));
                      halign = :left, fontsize = 11, tellwidth = false))
        name = ps.name
        on(tb.stored_string) do str
            nv = parse_si(something(str, ""))
            (nv === nothing || nv == get(e.params, name, NaN)) && return
            e.params[name] = nv
            changed!(st)
            request!(st, :inspector)
        end
    end
    colgap!(g, 6); rowgap!(g, 4)
    note!(p, h, r, e.kind == :capacitor ? "Open circuit in DC analysis; used for AC impedance." :
                   e.kind == :sink ? "Current is drawn from the + net and returned on the − net, split over the pads." :
                   e.kind == :vrm ? "Ideal source V behind Rout (DC); Lout is used for AC." : "Values accept 4.7u, 10k, 1k5, 100nF …";
          color = DIM, fontsize = 11); r += 1

    g = sub!(p, h[r, 1:2]); r += 1
    bd = blk!(p, Button(g[1, 1]; label = "Delete $(e.id)", buttoncolor = RGBf(0.45, 0.15, 0.15), padding = (10, 10, 5, 5)))
    bb = blk!(p, Button(g[1, 2]; label = "Back to $(c.ref)", padding = (10, 10, 5, 5)))
    on(bd.clicks) do _
        filter!(x -> x !== e, s.elements)
        changed!(st)
        st.say("Deleted $(e.id)")
        st.sel[] = (:comp, c.ref)
    end
    on(bb.clicks) do _
        st.sel[] = (:comp, c.ref)
    end
    return r
end

# ─────────────────────────────────────────────────────────────────────────────
# Circuit symbols (drawn into a decoration-free Axis, data limits ≈ ±3.4 × ±1.8)
# ─────────────────────────────────────────────────────────────────────────────
function param_lines(e::Element)
    spec = KIND_SPECS[e.kind]
    return [(ps.name * " = " * format_si(get(e.params, ps.name, ps.default), ps.unit) * (ps.scope == :ac ? "  (AC)" : ""),
             ps.scope == :ac ? DIM : RGBf(0.92, 0.92, 0.95)) for ps in spec.params]
end

function draw_symbol!(ax, e::Element)
    spec = KIND_SPECS[e.kind]
    col = KIND_COLORS[e.kind]
    lw = 2.5
    pos = isempty(e.net_pos) ? "?" : e.net_pos
    neg = isempty(e.net_neg) ? "?" : e.net_neg
    W(xs, ys; color = WIRE) = lines!(ax, Float32.(xs), Float32.(ys); color = color, linewidth = lw)

    if spec.group == :passive
        # horizontal: terminal 1 left, terminal 2 right
        W([-2.8, -1.0], [0.5, 0.5]); W([1.0, 2.8], [0.5, 0.5])
        scatter!(ax, Point2f[(-2.8, 0.5), (2.8, 0.5)]; color = WIRE, markersize = 9)
        text!(ax, Point2f(-2.8, 0.85); text = pos, align = (:left, :bottom), fontsize = 12, color = :white)
        text!(ax, Point2f(2.8, 0.85); text = neg, align = (:right, :bottom), fontsize = 12, color = :white)
        if e.kind == :resistor
            xs = range(-1.0, 1.0; length = 9)
            ys = 0.5 .+ [0, 0.3, -0.3, 0.3, -0.3, 0.3, -0.3, 0.3, 0]
            W(xs, ys; color = col)
        elseif e.kind == :inductor
            pts = Point2f[]
            for k in 0:3
                cx = -0.75 + 0.5k
                for t in range(π, 0; length = 12)
                    push!(pts, Point2f(cx + 0.25cos(t), 0.5 + 0.35sin(t)))
                end
            end
            lines!(ax, pts; color = col, linewidth = lw)
        elseif e.kind == :ferrite
            W([-1.0, 1.0], [0.5, 0.5])
            poly!(ax, Rect2f(-0.8, 0.22, 1.6, 0.56); color = darken(col, 0.6), strokecolor = col, strokewidth = 2)
        elseif e.kind == :short
            W([-1.0, 1.0], [0.5, 0.5]; color = col)
            text!(ax, Point2f(0, 0.65); text = "0 Ω", align = (:center, :bottom), fontsize = 12, color = col)
        elseif e.kind == :capacitor
            W([-1.0, -0.18], [0.5, 0.5]); W([0.18, 1.0], [0.5, 0.5])
            W([-0.18, -0.18], [-0.05, 1.05]; color = col); W([0.18, 0.18], [-0.05, 1.05]; color = col)
        end
        for (i, (txt, c)) in enumerate(param_lines(e))
            text!(ax, Point2f(0, -0.35 - 0.42 * (i - 1)); text = txt, align = (:center, :center), fontsize = 13, color = c)
        end
    else
        # vertical source: + terminal on top, − at the bottom
        cx = -2.0
        W([cx, cx], [0.75, 1.45]); W([cx, cx], [-0.75, -1.45])
        scatter!(ax, Point2f[(cx, 1.45), (cx, -1.45)]; color = WIRE, markersize = 9)
        θ = range(0, 2π; length = 48)
        lines!(ax, Point2f.(cx .+ 0.75cos.(θ), 0.75sin.(θ)); color = col, linewidth = lw)
        if e.kind == :vrm
            text!(ax, Point2f(cx, 0.32); text = "+", align = (:center, :center), fontsize = 18, color = col, font = :bold)
            text!(ax, Point2f(cx, -0.32); text = "−", align = (:center, :center), fontsize = 18, color = col, font = :bold)
        else
            W([cx, cx], [0.45, -0.3]; color = col)
            poly!(ax, Point2f[(cx - 0.18, -0.22), (cx + 0.18, -0.22), (cx, -0.5)]; color = col)
        end
        text!(ax, Point2f(cx + 0.2, 1.45); text = pos, align = (:left, :center), fontsize = 12, color = :white)
        text!(ax, Point2f(cx + 0.2, -1.45); text = neg, align = (:left, :center), fontsize = 12, color = :white)
        text!(ax, Point2f(-0.9, 0.95); text = KIND_SPECS[e.kind].label * "  " * e.id, align = (:left, :center),
              fontsize = 13, color = col, font = :bold)
        for (i, (txt, c)) in enumerate(param_lines(e))
            text!(ax, Point2f(-0.9, 0.45 - 0.42 * (i - 1)); text = txt, align = (:left, :center), fontsize = 13, color = c)
        end
    end
    return ax
end

end # module
