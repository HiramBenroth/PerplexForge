module Widgets

export ListPanel, set_items!, log!, Splitter, TabBar, DynPanel, rebuild!, blk!, sub!, obs!,
       CheckRow, TablePanel, set_rows!, PANEL_BG, ACCENT, BTN_BG, BTN_ACTIVE

using GLMakie
const GLB = GLMakie.Makie.GridLayoutBase

const PANEL_BG   = RGBf(0.07, 0.07, 0.09)
const ACCENT     = RGBf(0.20, 0.45, 0.85)
const BTN_BG     = RGBf(0.25, 0.25, 0.30)
const BTN_ACTIVE = RGBf(0.20, 0.40, 0.75)

# ─────────────────────────────────────────────────────────────────────────────
# ListPanel: scrollable, clickable text list that fills the cell it is placed in.
# Optional per-row tag (short colored label in front of the text).
# ─────────────────────────────────────────────────────────────────────────────
mutable struct ListPanel
    ax::Axis
    items::Observable{Vector{String}}
    tags::Observable{Vector{String}}
    tagcolors::Observable{Vector{RGBf}}
    offset::Observable{Int}        # first visible row (0-based)
    selected::Observable{Int}      # index into items, 0 = none
    nrows::Observable{Int}         # follows the panel height
    rowpx::Int
    autoscroll::Bool
end

function ListPanel(pos; rowpx = 17, fontsize = 12, selectable::Bool = true, autoscroll::Bool = false,
                   textcolor = RGBf(0.85, 0.87, 0.90), tagpx = 38, minrows = 3)
    ax = Axis(pos; backgroundcolor = PANEL_BG, tellheight = false, tellwidth = false, limits = (0, 1, 0, minrows))
    hidedecorations!(ax)
    hidespines!(ax)
    for k in (:rectanglezoom, :scrollzoom, :dragpan, :limitreset)
        try
            deregister_interaction!(ax, k)
        catch
        end
    end

    items = Observable(String[])
    tags = Observable(String[])
    tagcolors = Observable(RGBf[])
    offset = Observable(0)
    selected = Observable(0)
    nrows = Observable(minrows)

    on(ax.scene.viewport) do vp
        n = max(minrows, floor(Int, widths(vp)[2] / rowpx))
        n != nrows[] && (nrows[] = n)
    end
    on(nrows; update = true) do n
        limits!(ax, 0, 1, 0, n)
    end

    # selection highlight (row r occupies y ∈ [n-r, n-r+1])
    sel_rect = lift(selected, offset, nrows) do s, off, n
        row = s - off
        1 <= row <= n ? Rect2f(0, n - row, 1, 1) : Rect2f(0, -10, 1, 1)
    end
    poly!(ax, sel_rect; color = RGBAf(0.2, 0.5, 0.95, 0.35))

    # x where the main text starts: after the tag column (in data units, from the pixel width)
    textx = lift(tags, ax.scene.viewport) do tg, vp
        isempty(tg) ? 0.015f0 : Float32(0.015 + tagpx / max(widths(vp)[1], 1))
    end
    rows = lift(items, tags, tagcolors, offset, nrows, textx) do its, tg, tc, off, n, tx
        i1 = min(off + n, length(its))
        txt = Tuple{String,Point2f}[]
        tagt = Tuple{String,Point2f}[]
        tagc = RGBf[]
        for (k, i) in enumerate((off + 1):i1)
            y = n - k + 0.5
            push!(txt, (its[i], Point2f(tx, y)))
            if i <= length(tg)
                push!(tagt, (tg[i], Point2f(0.015, y)))
                push!(tagc, i <= length(tc) ? tc[i] : textcolor)
            end
        end
        isempty(txt) && push!(txt, (" ", Point2f(0.015, n - 0.5)))
        isempty(tagt) && (push!(tagt, (" ", Point2f(0.015, n - 0.5))); push!(tagc, textcolor))
        (txt, tagt, tagc)
    end
    text!(ax, lift(r -> r[1], rows); align = (:left, :center), fontsize = fontsize, color = textcolor)
    text!(ax, lift(r -> r[2], rows); align = (:left, :center), fontsize = fontsize, font = :bold,
          color = lift(r -> r[3], rows))

    lp = ListPanel(ax, items, tags, tagcolors, offset, selected, nrows, rowpx, autoscroll)

    on(events(ax.scene).scroll) do s
        if is_mouseinside(ax.scene)
            maxoff = max(0, length(lp.items[]) - lp.nrows[])
            lp.offset[] = clamp(lp.offset[] - 3 * Int(sign(s[2])), 0, maxoff)
        end
    end

    if selectable
        on(events(ax.scene).mousebutton) do ev
            if ev.button == Mouse.left && ev.action == Mouse.press && is_mouseinside(ax.scene)
                y = mouseposition(ax.scene)[2]
                row = lp.nrows[] - floor(Int, y)
                idx = lp.offset[] + row
                if 1 <= row <= lp.nrows[] && 1 <= idx <= length(lp.items[])
                    lp.selected[] = idx
                end
            end
        end
    end
    return lp
end

"Replace the list contents (resets scroll and selection unless `keep = true`)."
function set_items!(lp::ListPanel, v::Vector{String}; tags = String[], tagcolors = RGBf[], keep::Bool = false)
    if keep
        lp.selected.val = min(lp.selected[], length(v))
        lp.offset.val = clamp(lp.offset[], 0, max(0, length(v) - lp.nrows[]))
    else
        lp.selected[] = 0
        lp.offset[] = 0
    end
    lp.tags.val = tags
    lp.tagcolors.val = tagcolors
    lp.items[] = v
    notify(lp.selected)
    return lp
end

"Append line(s) to a list used as a log; auto-scrolls if enabled."
function log!(lp::ListPanel, lines::AbstractString...)
    for l in lines, sub in split(String(l), '\n')
        push!(lp.items[], String(sub))
    end
    n = length(lp.items[])
    n > 3000 && deleteat!(lp.items[], 1:(n - 3000))
    notify(lp.items)
    lp.autoscroll && (lp.offset[] = max(0, length(lp.items[]) - lp.nrows[]))
    return lp
end

# ─────────────────────────────────────────────────────────────────────────────
# TablePanel: scrollable table with fixed-width columns (px), a header row that sorts
# on click (click again to reverse), per-row text colour, and row selection by id.
# ─────────────────────────────────────────────────────────────────────────────
mutable struct TablePanel
    ax::Axis
    cols::Vector{Tuple{String,Int,Symbol}}         # (header, width px, :left | :right)
    rows::Vector{Vector{String}}
    keys::Vector{Vector{Any}}                      # sort key per cell
    ids::Vector{Any}
    colors::Vector{RGBf}
    order::Observable{Vector{Int}}                 # display order (indices into rows)
    offset::Observable{Int}
    nrows::Observable{Int}
    sortcol::Int
    sortrev::Bool
    selected::Observable{Any}                      # id of the selected row (nothing)
    rowpx::Int
    observers::Vector{Any}                         # figure-level event handlers (release with `off` / obs!)
end

function TablePanel(pos, cols; rowpx = 17, fontsize = 12, textcolor = RGBf(0.85, 0.87, 0.90), minrows = 3)
    ax = Axis(pos; backgroundcolor = PANEL_BG, tellheight = false, tellwidth = false, limits = (0, 1, 0, minrows))
    hidedecorations!(ax); hidespines!(ax)
    for k in (:rectanglezoom, :scrollzoom, :dragpan, :limitreset)
        try deregister_interaction!(ax, k) catch end
    end
    tp = TablePanel(ax, cols, Vector{String}[], Vector{Any}[], Any[], RGBf[], Observable(Int[]), Observable(0),
                    Observable(minrows), 0, false, Observable{Any}(nothing), rowpx, Any[])
    on(ax.scene.viewport) do vp
        n = max(minrows, floor(Int, widths(vp)[2] / rowpx))
        n != tp.nrows[] && (tp.nrows[] = n)
    end
    on(tp.nrows; update = true) do n
        limits!(ax, 0, 1, 0, n)
    end
    # column edges in data x (0…1) from pixel widths
    edges = lift(ax.scene.viewport) do vp
        w = max(widths(vp)[1], 1)
        xs = Float32[0.01]
        for (_, px, _) in cols
            push!(xs, xs[end] + px / w)
        end
        xs
    end
    content = lift(tp.order, tp.offset, tp.nrows, edges, tp.selected) do ord, off, n, xs, sel
        L = Tuple{String,Point2f}[]; Lc = RGBf[]
        R = Tuple{String,Point2f}[]; Rc = RGBf[]
        H = Tuple{String,Point2f}[]; Hr = Tuple{String,Point2f}[]
        selrect = Rect2f(0, -10, 1, 1)
        for (c, (hd, _, al)) in enumerate(cols)
            arrow = c == tp.sortcol ? (tp.sortrev ? " ▾" : " ▴") : ""
            al == :right ? push!(Hr, (hd * arrow, Point2f(xs[c+1] - 0.006, n - 0.5))) : push!(H, (hd * arrow, Point2f(xs[c], n - 0.5)))
        end
        for k in 1:min(n - 1, length(ord) - off)
            i = ord[off + k]
            y = n - 1 - k + 0.5
            tp.ids[i] == sel && sel !== nothing && (selrect = Rect2f(0, n - 1 - k, 1, 1))
            for (c, (_, _, al)) in enumerate(cols)
                txt = c <= length(tp.rows[i]) ? tp.rows[i][c] : ""
                if al == :right
                    push!(R, (txt, Point2f(xs[c+1] - 0.006, y))); push!(Rc, tp.colors[i])
                else
                    push!(L, (txt, Point2f(xs[c], y))); push!(Lc, tp.colors[i])
                end
            end
        end
        for v in (L, R, H, Hr)
            isempty(v) && push!(v, (" ", Point2f(0, -5)))
        end
        isempty(Lc) && push!(Lc, textcolor); isempty(Rc) && push!(Rc, textcolor)
        length(Lc) < length(L) && append!(Lc, fill(textcolor, length(L) - length(Lc)))
        length(Rc) < length(R) && append!(Rc, fill(textcolor, length(R) - length(Rc)))
        (L, Lc, R, Rc, H, Hr, selrect)
    end
    poly!(ax, lift(c -> c[7], content); color = RGBAf(0.2, 0.5, 0.95, 0.35))
    poly!(ax, lift(n -> Rect2f(0, n - 1, 1, 1), tp.nrows); color = RGBf(0.12, 0.12, 0.15))
    text!(ax, lift(c -> c[1], content); color = lift(c -> c[2], content), align = (:left, :center), fontsize = fontsize)
    text!(ax, lift(c -> c[3], content); color = lift(c -> c[4], content), align = (:right, :center), fontsize = fontsize)
    text!(ax, lift(c -> c[5], content); color = :gray70, align = (:left, :center), fontsize = fontsize, font = :bold)
    text!(ax, lift(c -> c[6], content); color = :gray70, align = (:right, :center), fontsize = fontsize, font = :bold)

    push!(tp.observers, on(events(ax.scene).scroll) do s
        if is_mouseinside(ax.scene)
            maxoff = max(0, length(tp.order[]) - (tp.nrows[] - 1))
            tp.offset[] = clamp(tp.offset[] - 3 * Int(sign(s[2])), 0, maxoff)
        end
    end)
    push!(tp.observers, on(events(ax.scene).mousebutton) do ev
        (ev.button == Mouse.left && ev.action == Mouse.press && is_mouseinside(ax.scene)) || return
        mp = mouseposition(ax.scene)
        n = tp.nrows[]
        row = n - floor(Int, mp[2])                 # 1 = header
        if row == 1
            xs = edges[]
            c = findlast(x -> x <= mp[1], xs)
            (c === nothing || c > length(cols)) && return
            tp.sortrev = tp.sortcol == c ? !tp.sortrev : false
            tp.sortcol = c
            resort!(tp)
        else
            k = tp.offset[] + row - 1
            1 <= k <= length(tp.order[]) && (tp.selected[] = tp.ids[tp.order[][k]])
        end
    end)
    return tp
end

function resort!(tp::TablePanel)
    idx = collect(1:length(tp.rows))
    c = tp.sortcol
    if c > 0
        key(i) = (k = c <= length(tp.keys[i]) ? tp.keys[i][c] : ""; k isa Real && isnan(k) ? Inf : k)
        function lt(a, b)
            ka, kb = key(a), key(b)
            return (ka isa Real && kb isa Real) ? ka < kb : string(ka) < string(kb)
        end
        sort!(idx; lt = lt, rev = tp.sortrev)
    end
    tp.order[] = idx
    return tp
end

"Replace the table contents. `keys` are the sort keys per cell (defaults to the text)."
function set_rows!(tp::TablePanel, rows::Vector{Vector{String}}; keys = rows, ids = collect(1:length(rows)),
                   colors = fill(RGBf(0.85, 0.87, 0.90), length(rows)), keep::Bool = false)
    tp.rows, tp.keys, tp.ids, tp.colors = rows, keys, ids, colors
    keep || (tp.offset.val = 0)
    tp.offset.val = clamp(tp.offset[], 0, max(0, length(rows) - (tp.nrows[] - 1)))
    resort!(tp)
    return tp
end

# ─────────────────────────────────────────────────────────────────────────────
# Splitter: a thin bar you drag to resize a neighbouring panel.
#   dir = :v → vertical bar, drag left/right;  dir = :h → horizontal bar, drag up/down
#   getsize() returns the current size; setsize!(new) applies it; ondone() after release.
#   sign = +1 if dragging right/up should grow the panel, -1 otherwise.
# ─────────────────────────────────────────────────────────────────────────────
mutable struct Splitter
    box::Box
    dragging::Bool
end

function Splitter(fig, pos, dir::Symbol; getsize, setsize!, sign = 1, minsize = 150, maxsize = 900, ondone = () -> nothing)
    idle, hot = RGBf(0.14, 0.14, 0.17), RGBf(0.30, 0.45, 0.75)
    kw = dir == :v ? (; width = 6) : (; height = 6)
    box = Box(pos; color = idle, strokevisible = false, cornerradius = 2, kw...)
    sp = Splitter(box, false)
    start_mouse = Ref(0.0)
    start_size = Ref(0.0)
    ax = dir == :v ? 1 : 2
    inside() = Point2f(events(fig).mouseposition[]) in box.layoutobservables.computedbbox[]

    on(events(fig).mousebutton; priority = 50) do ev
        ev.button == Mouse.left || return Consume(false)
        if ev.action == Mouse.press && inside()
            sp.dragging = true
            start_mouse[] = events(fig).mouseposition[][ax]
            start_size[] = getsize()
            box.color[] = hot
            return Consume(true)
        elseif ev.action == Mouse.release && sp.dragging
            sp.dragging = false
            box.color[] = idle
            ondone()
            return Consume(true)
        end
        return Consume(false)
    end
    on(events(fig).mouseposition; priority = 50) do mp
        if sp.dragging
            d = (mp[ax] - start_mouse[]) * sign
            setsize!(clamp(start_size[] + d, minsize, maxsize))
            return Consume(true)
        end
        box.color[] = inside() ? RGBf(0.22, 0.30, 0.45) : idle
        return Consume(false)
    end
    return sp
end

# ─────────────────────────────────────────────────────────────────────────────
# TabBar: a row of buttons; `active` holds the selected key.
# ─────────────────────────────────────────────────────────────────────────────
struct TabBar
    active::Observable{Symbol}
    buttons::Dict{Symbol,Button}
end

function TabBar(gl::GridLayout, tabs::Vector{Pair{Symbol,String}}; default = first(tabs)[1])
    active = Observable(default)
    buttons = Dict{Symbol,Button}()
    for (i, (key, label)) in enumerate(tabs)
        b = Button(gl[1, i]; label = label, padding = (10, 10, 5, 5), tellwidth = false, width = Relative(1),
                   labelcolor = :white)
        buttons[key] = b
        on(b.clicks) do _
            active[] = key
        end
    end
    on(active; update = true) do a
        for (k, b) in buttons
            b.buttoncolor[] = k == a ? BTN_ACTIVE : BTN_BG
        end
    end
    colgap!(gl, 4)
    return TabBar(active, buttons)
end

# ─────────────────────────────────────────────────────────────────────────────
# DynPanel: a GridLayout whose contents are rebuilt from scratch (inspector, tabs).
# Builders register what they create with blk!/sub!/obs! so rebuild! can remove it.
# ─────────────────────────────────────────────────────────────────────────────
mutable struct DynPanel
    host::GridLayout
    blocks::Vector{Any}
    layouts::Vector{GridLayout}
    observers::Vector{Any}
end
DynPanel(host::GridLayout) = DynPanel(host, Any[], GridLayout[], Any[])

blk!(p::DynPanel, b) = (push!(p.blocks, b); b)
sub!(p::DynPanel, pos; kw...) = (gl = GridLayout(pos; kw...); push!(p.layouts, gl); gl)
obs!(p::DynPanel, f) = (push!(p.observers, f); f)

function clear!(p::DynPanel)
    foreach(off, p.observers)
    foreach(delete!, p.blocks)
    for gl in reverse(p.layouts)
        gc = GLB.gridcontent(gl)
        gc === nothing || GLB.remove_from_gridlayout!(gc)
    end
    empty!(p.observers); empty!(p.blocks); empty!(p.layouts)
    h = p.host
    while GLB.nrows(h) > 1
        GLB.deleterow!(h, GLB.nrows(h))
    end
    while GLB.ncols(h) > 1
        GLB.deletecol!(h, GLB.ncols(h))
    end
    return p
end

"Clear the panel and run `build(panel)` to fill it again."
function rebuild!(build, p::DynPanel)
    clear!(p)
    build(p)
    return p
end

"A checkbox with a label (and optional label color) in a two-column row. Returns the Checkbox."
function CheckRow(gl, row, label; checked = true, color = :white, p::Union{Nothing,DynPanel} = nothing)
    cb = Checkbox(gl[row, 1]; checked = checked, size = 14, checkboxcolor_checked = ACCENT, roundness = 0.3)
    lb = Label(gl[row, 2], label; halign = :left, color = color, tellwidth = false)
    if p !== nothing
        blk!(p, cb); blk!(p, lb)
    end
    return cb
end

end # module
