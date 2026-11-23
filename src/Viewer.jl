module Viewer

# The workbench window: layout (resizable docks), browser lists, inspector / view tabs,
# console commands, save / recovery, and the DC setup check.

export launch_viewer

using GLMakie
using ..BoardParser: BoardData, Component
using ..SimSetups
using ..WorkbenchState
using ..Widgets
using ..Scene3D
using ..Inspector
using ..DCSolver
using ..ACSolver
using ..ResultsPanel
using ..ImpedancePanel
using ..SISolver
using ..SIPanel
using ..AnalysisPanel
using ..Report
using Printf

const DISPLAY_OPTS = ((:traces, "Traces",       ["Solid", "Wireframe", "Off"]),
                      (:pads,   "Pads",         ["Solid", "Wireframe", "Off"]),
                      (:vias,   "Vias",         ["Solid", "Wireframe", "Off"]),
                      (:pours,  "Copper pours", ["Solid", "Translucent", "Wireframe", "Off"]),
                      (:bodies, "Components",   ["Solid", "Wireframe", "Off"]))

const ASSETS = normpath(joinpath(@__DIR__, "..", "assets"))
asset_path(parts...) = joinpath(ASSETS, parts...)

"PNG as a Matrix{RGBA} (rows top → bottom), or nothing."
load_png(path) = isfile(path) ? (try GLMakie.Makie.PNGFiles.load(path) catch; nothing end) : nothing

"Replace GLMakie's default window/taskbar icon with the PerplexForge icon set (all sizes in assets/icons)."
function set_window_icon!(screen)
    dir = asset_path("icons")
    isdir(dir) || return
    try
        icons = [GLMakie.Makie.load_icon(f) for f in readdir(dir; join = true) if endswith(f, ".png")]
        isempty(icons) || GLMakie.GLFW.SetWindowIcon(screen.glscreen, icons)
    catch err
        @warn "Could not set the window icon" exception = err
    end
end

"""
macOS: replace the Dock icon (by default Julia's, or a generic executable) with the
PerplexForge app icon. GLFW's window icons are ignored on macOS, so this goes through the
Objective-C runtime: `[NSApp setApplicationIconImage:[[NSImage alloc] initWithContentsOfFile:path]]`.
Must run on the main thread after GLFW has created the application (i.e. after the window opens).
"""
const LIBOBJC = "/usr/lib/libobjc.A.dylib"
function set_dock_icon!(path)
    (Sys.isapple() && isfile(path)) || return false
    try
        cls(n) = ccall((:objc_getClass, LIBOBJC), Ptr{Cvoid}, (Cstring,), n)
        sel(n) = ccall((:sel_registerName, LIBOBJC), Ptr{Cvoid}, (Cstring,), n)
        msg(o, s) = ccall((:objc_msgSend, LIBOBJC), Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}), o, sel(s))
        str = ccall((:objc_msgSend, LIBOBJC), Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}, Cstring),
                    cls("NSString"), sel("stringWithUTF8String:"), path)
        img = ccall((:objc_msgSend, LIBOBJC), Ptr{Cvoid}, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}),
                    msg(cls("NSImage"), "alloc"), sel("initWithContentsOfFile:"), str)
        img == C_NULL && return false
        app = msg(cls("NSApplication"), "sharedApplication")
        ccall((:objc_msgSend, LIBOBJC), Cvoid, (Ptr{Cvoid}, Ptr{Cvoid}, Ptr{Cvoid}), app, sel("setApplicationIconImage:"), img)
        return true
    catch err
        @warn "Could not set the Dock icon" exception = err
        return false
    end
end

const TXT = RGBf(0.92, 0.92, 0.95)
const WORKBENCH_THEME = Theme(
    Button = (buttoncolor = BTN_BG, buttoncolor_hover = RGBf(0.32, 0.33, 0.40), buttoncolor_active = BTN_ACTIVE,
              labelcolor = TXT, labelcolor_hover = :white, labelcolor_active = :white, cornerradius = 4, strokewidth = 0),
    Menu = (cell_color_inactive_even = RGBf(0.16, 0.16, 0.20), cell_color_inactive_odd = RGBf(0.18, 0.18, 0.22),
            cell_color_hover = RGBf(0.25, 0.32, 0.48), cell_color_active = BTN_ACTIVE,
            selection_cell_color_inactive = RGBf(0.16, 0.16, 0.20), textcolor = TXT,
            dropdown_arrow_color = RGBf(0.6, 0.6, 0.65), fontsize = 14, textpadding = (8, 10, 5, 5)),
    Textbox = (boxcolor = RGBf(0.13, 0.13, 0.16), boxcolor_hover = RGBf(0.15, 0.15, 0.19),
               boxcolor_focused = RGBf(0.15, 0.15, 0.20), bordercolor = RGBf(0.28, 0.28, 0.34),
               textcolor = TXT, textcolor_placeholder = RGBf(0.45, 0.45, 0.50), cursorcolor = :white, fontsize = 14),
    Label = (color = TXT,),
)

const MIN_CENTER, MIN_VIEW = 480, 220             # smallest 3D view (px) before the docks start to shrink
const MIN_LEFT, MIN_RIGHT = 170, 260               # docks never shrink below these

const ABOUT_TEXT = """PerplexForge: power and signal integrity for KiCad.
DC IR drop · AC PDN impedance · trace impedance (2-D field solver),
return paths, lengths and skew · HTML / PDF reports.
MIT licence · github.com/HiramBenroth/PerplexForge"""

const KIND_ALIASES = Dict("vrm" => :vrm, "sink" => :sink, "load" => :sink, "r" => :resistor, "resistor" => :resistor,
                          "l" => :inductor, "inductor" => :inductor, "fb" => :ferrite, "ferrite" => :ferrite,
                          "short" => :short, "0r" => :short, "jumper" => :short, "c" => :capacitor, "capacitor" => :capacitor)

const CLASS_ALIASES = Dict("power" => :power, "pwr" => :power, "ground" => :ground, "gnd" => :ground,
                           "digital" => :digital, "dig" => :digital, "none" => :unspecified, "unspecified" => :unspecified)

const HELP = """
Commands:
  help | about | clear | info | layers | stackup
  nets [filter]   comps [filter]          list nets / components
  net <name>      comp <ref>              select a net / component
  deselect
  class <net|pattern*> <power|ground|digital|none>   assign a net class
  element add <kind> <REF> [+net] [-net] [P=value …] kinds: vrm sink r l fb short c
  element rm <id>   |   element list
  check                                   validate the DC setup only
  dc  (or run)                            run the DC IR-drop analysis (same as the ▶ button)
  overlay <voltage|drop|density|z|target|ref|off>   colour the copper by the last DC / SI result
  rail <net>                              rail shown by the voltage overlay
  ac                                      run the AC PDN-impedance sweep (each sink is a port)
  si                                      run the signal-integrity analysis (impedance, return paths, lengths)
  target [<pattern> <Ω> [tol%] [diff]]    list / add an impedance target   ·   target rm <pattern> | reset
  group [add <name> <tol> <pattern…> [delay] | rm <name>]   length-match groups (tol in mm, or ps with delay)
  siset <key> <value>                     SI settings, e.g. siset return_via_mm 1   ·   pairs   ·   issues [all]
  acset <f_start|f_stop|points_per_decade|cell_mm> <value>   e.g. acset f_stop 2G
  freq <Hz>   |   port <id>               3D map of |V| at a frequency for 1 A into a port
  dcset <cell_mm|temperature_c|via_plating_um|cu_thickness_um> <value>
  save                                    write <board>.perplex.json
  report [open]                           write <board>.perplex-report.html (DC, AC and SI results; prints to PDF)
  recover                                 load unsaved changes from the last session
  show|hide <layer|outline|dielectric>    mode <traces|pads|vias|pours|bodies> <solid|translucent|wire|off>
  colorby <layer|class>                   zscale <1-20>
  fit   |   view <top|iso|side|bottom>
Mouse (3D): left-drag orbit · right-drag pan · scroll zoom · click copper = net · click body = component"""

"""
    launch_viewer(board, setup; on_simulate=nothing, startup_log=String[], block=false, show=true)

Opens the workbench. `on_simulate(board, setup)` is called by the ▶ button after a
successful DC setup check. With `show = false` nothing is displayed (used for
snapshots); the returned named tuple gives access to the figure, state and helpers.
"""
function launch_viewer(board::BoardData, setup::SimSetup; on_simulate = nothing, startup_log = String[],
                       block::Bool = false, show::Bool = true, version::AbstractString = "")
    println("[viewer] Building geometry...")
    layers, unfilled = build_layers(board)
    zcu, slabs, diel_defined = stack_geometry(board, layers)
    bounds = board_bounds(board, layers)
    println("[viewer] Copper layers: ", join((L.name for L in layers), ", "))

    v = setup.view
    getv(k, d) = (x = get(v, k, d); x isa typeof(d) ? x : (d isa Number && x isa Number ? oftype(d, x) : d))
    hidden = Set(String.(get(v, "hidden_layers", String[])))

    sayref = Ref{Any}((msg...) -> println(msg...))
    say(msg...) = sayref[](msg...)

    st = UIState(board, setup, Dict(c.ref => c for c in board.components),
                 Observable((:none, "")), Observable(0), Observable(0),
                 Observable(getv("color_by", "Layer")),
                 Dict(sym => Observable(getv("mode_" * string(sym), "Solid")) for (sym, _, _) in DISPLAY_OPTS),
                 [L.name for L in layers],
                 Dict(L.name => Observable(!(L.name in hidden)) for L in layers),
                 Observable(getv("show_outline", true)),
                 Observable(diel_defined && getv("show_dielectric", true)), diel_defined,
                 Observable(getv("show_passive_markers", true)),
                 Observable(clamp(getv("zscale", 1.0), 1.0, MAX_ZSCALE)),
                 String[], Set{Symbol}(), say,
                 Observable{Any}(nothing), Observable(getv("result_mode", "Voltage")), Observable(getv("result_net", "")), 0,
                 Observable{Any}(nothing), Observable(0.0), Observable(1), 0,
                 Observable{Any}(nothing), 0, Observable(0))

    fig = with_theme(merge(WORKBENCH_THEME, theme_dark())) do
        Figure(size = (1900, 1050), backgroundcolor = RGBf(0.11, 0.11, 0.13))
    end
    boardname = basename(setup.board_file)

    # ── top bar ──────────────────────────────────────────────────────────────
    top = GridLayout(fig[1, 1])
    logo_ax = Axis(top[1, 1]; width = 48, height = 48, aspect = DataAspect(), backgroundcolor = :transparent)
    hidedecorations!(logo_ax); hidespines!(logo_ax)
    foreach(k -> (try deregister_interaction!(logo_ax, k) catch end), (:rectanglezoom, :scrollzoom, :dragpan, :limitreset))
    logo = load_png(asset_path("icons", "icon_48.png"))           # shown 1:1 so it stays crisp
    logo === nothing || image!(logo_ax, rotr90(logo); interpolate = false)
    tightlimits!(logo_ax)
    # The title never asks for width (tellwidth = false): it is shortened to fit instead, so a
    # narrow window can't push the logo or the buttons out of the frame.
    title = Label(top[1, 2], ""; fontsize = 19, font = :bold, halign = :left, tellwidth = false)
    btn_save = Button(top[1, 3]; label = "Save", padding = (16, 16, 7, 7))
    btn_report = Button(top[1, 4]; label = "Report", padding = (14, 14, 7, 7))
    colgap!(top, 8)
    function update_title()
        W = widths(fig.scene.viewport[])[1]
        budget = max(8, floor(Int, (W - 48 - 190 - 60) / 10.5))        # characters that fit at 19 pt bold
        dirty = st.setup.dirty ? "   ●  unsaved" : ""
        name = boardname
        full = length("PerplexForge ") + length(version) + 5 + length(name) + length(dirty)
        if full <= budget
            title.text[] = rich("PerplexForge ", rich(version; color = :gray60, fontsize = 13, font = :regular), "  ·  " * name * dirty)
        else
            room = budget - length(dirty)
            name = length(name) <= room ? name : first(name, max(room - 1, 4)) * "…"
            title.text[] = rich(name * dirty)
        end
    end

    # ── main area: left | splitter | centre | splitter | right ───────────────
    main = GridLayout(fig[2, 1])
    left   = GridLayout(main[1, 1])
    center = GridLayout(main[1, 3])
    right  = GridLayout(main[1, 5])
    wl = Ref(Float64(getv("left_width", 300.0)))
    wr = Ref(Float64(getv("right_width", 380.0)))
    hc = Ref(Float64(getv("console_height", 170.0)))
    colsize!(main, 1, Fixed(wl[]))
    colsize!(main, 5, Fixed(wr[]))
    colgap!(main, 4)
    rowgap!(fig.layout, 6)

    # centre: bottom area first (so warnings from the scene builder land in the console), then 3D
    bottom = GridLayout(center[3, 1])
    tabgl = GridLayout(bottom[1, 1]; halign = :left, tellwidth = false)
    tabs_b = TabBar(tabgl, [:console => "Console", :impedance => "PDN impedance", :signals => "Signals"])
    foreach(c -> colsize!(tabgl, c, Fixed(c == 2 ? 140 : 120)), 1:3)
    console = ListPanel(bottom[2, 1]; autoscroll = true, selectable = false, rowpx = 16, fontsize = 12)
    zpanel = DynPanel(GridLayout(bottom[2, 1]; tellwidth = false, tellheight = false))
    rowgap!(bottom, 4)
    sayref[] = (msg...) -> log!(console, msg...)
    rowsize!(center, 3, Fixed(hc[]))
    cmdbox = Textbox(center[4, 1]; placeholder = "▸ command  (type help)", width = Relative(1), tellwidth = false)
    viewgl = GridLayout(center[1, 1])
    vtool = GridLayout(viewgl[1, 1]; tellwidth = false, halign = :left)
    bs = build_scene!(viewgl[2, 1], st, layers, zcu, slabs, bounds; say = say)
    rowgap!(viewgl, 4)
    rowgap!(center, 4)
    # view toolbar: camera presets on the left, overlay quick-switch on the right
    Label(vtool[1, 1], "View"; color = :gray60, fontsize = 12)
    vbtn = Dict(k => Button(vtool[1, 1 + i]; label = l, padding = (8, 8, 3, 3), fontsize = 12)
                for (i, (k, l)) in enumerate(((:keep, "Fit"), (:top, "Top"), (:iso, "Iso"), (:side, "Side"), (:bottom, "Bottom"))))
    Label(vtool[1, 7], ""; tellwidth = false)
    Label(vtool[1, 8], "Overlay"; color = :gray60, fontsize = 12)
    overlay_menu = Menu(vtool[1, 9]; options = OVERLAY_MODES, default = st.result_mode[] in OVERLAY_MODES ? st.result_mode[] : "Off",
                        width = 170, fontsize = 12, textpadding = (6, 6, 3, 3))
    on(overlay_menu.selection) do s
        s === nothing || s == st.result_mode[] || (st.result_mode[] = s)
    end
    on(st.result_mode) do m
        m in OVERLAY_MODES && overlay_menu.selection[] != m && (overlay_menu.i_selected[] = findfirst(==(m), OVERLAY_MODES))
    end
    colgap!(vtool, 4)

    # ── status bar ───────────────────────────────────────────────────────────
    sbar = GridLayout(fig[3, 1]; tellwidth = false)
    status = Label(sbar[1, 1], "Ready"; halign = :left, color = :gray70, fontsize = 12, tellwidth = false)
    Label(sbar[1, 2], "left-drag orbit · right-drag pan · scroll zoom · click to select"; halign = :right,
          color = :gray45, fontsize = 11, tellwidth = false)
    rowsize!(fig.layout, 3, Fixed(18))

    # wl / wr / hc are the sizes the user asked for (saved with the setup); el / er / ec are what
    # fits the current window. When the window is too small the docks and the console shrink
    # (down to a floor) so the 3D view keeps at least MIN_CENTER × MIN_VIEW pixels.
    el, er, ec = Ref(wl[]), Ref(wr[]), Ref(hc[])
    function fit_layout!()
        W, H = widths(fig.scene.viewport[])
        avail = W - MIN_CENTER - 40
        l, rr = wl[], wr[]
        if l + rr > avail
            f = max(avail, 0) / (l + rr)
            l, rr = max(MIN_LEFT, l * f), max(MIN_RIGHT, rr * f)
        end
        c = clamp(hc[], 60, max(60, H - MIN_VIEW - 200))
        (l, rr, c) == (el[], er[], ec[]) && return
        el[], er[], ec[] = l, rr, c
        colsize!(main, 1, Fixed(l)); colsize!(main, 5, Fixed(rr)); rowsize!(center, 3, Fixed(c))
    end
    "How many ~25 px rows fit in the right dock (the panels size their lists to it; it can't scroll)."
    row_budget() = floor(Int, (widths(fig.scene.viewport[])[2] - 50 - 18 - 40 - 30) / 25.5)
    last_budget = Ref(0)
    on(fig.scene.viewport) do _
        fit_layout!()
        update_title()
        b = row_budget()
        b != last_budget[] && (last_budget[] = b; request!(st, :right))
    end
    splitters = (
        left = Splitter(fig, main[1, 2], :v; getsize = () -> el[], sign = 1, minsize = MIN_LEFT, maxsize = 700,
                        setsize! = w -> (wl[] = w; fit_layout!())),
        right = Splitter(fig, main[1, 4], :v; getsize = () -> er[], sign = -1, minsize = MIN_RIGHT, maxsize = 800,
                         setsize! = w -> (wr[] = w; fit_layout!())),
        console = Splitter(fig, center[2, 1], :h; getsize = () -> ec[], sign = 1, minsize = 60, maxsize = 700,
                           setsize! = h -> (hc[] = h; fit_layout!())),
        sizes = () -> (left = wl[], right = wr[], console = hc[]),
    )

    # ── left dock: browser ───────────────────────────────────────────────────
    tabs_l = TabBar(GridLayout(left[1, 1]), [:nets => "Nets", :comps => "Components", :setup => "Setup"])
    filter_tb = Textbox(left[2, 1]; placeholder = "filter…", width = Relative(1), tellwidth = false)
    browser = ListPanel(left[3, 1]; rowpx = 17)
    leftfoot = DynPanel(GridLayout(left[4, 1]))
    rowgap!(left, 6)

    net_names = sort!(collect(board.nets))
    comp_sorted = sort(board.components; by = c -> (replace(c.ref, r"\d+" => ""), something(tryparse(Int, replace(c.ref, r"\D" => "")), 0)))
    cur_keys = Ref(Tuple{Symbol,String}[])
    syncing = Ref(false)

    filt() = lowercase(strip(something(filter_tb.displayed_string[], "")))
    elem_order(e) = (findfirst(==(KIND_SPECS[e.kind].group), (:source, :load, :passive)), e.id)

    function browser_key(sel, tab)
        kind, name = sel
        tab == :nets && return kind == :net ? sel : nothing
        tab == :comps && (r = sel_component(st, sel); return r === nothing ? nothing : (:comp, r))
        return kind == :elem ? sel : nothing
    end

    function sync_browser!()
        key = browser_key(st.sel[], tabs_l.active[])
        i = key === nothing ? 0 : something(findfirst(==(key), cur_keys[]), 0)
        syncing[] = true
        browser.selected[] = i
        if i > 0 && !(browser.offset[] < i <= browser.offset[] + browser.nrows[])
            browser.offset[] = clamp(i - browser.nrows[] ÷ 2, 0, max(0, length(cur_keys[]) - browser.nrows[]))
        end
        syncing[] = false
    end

    function refresh_browser!(keep::Bool = true)
        f = filt()
        tab = tabs_l.active[]
        items, tags, tcols, keys = String[], String[], RGBf[], Tuple{Symbol,String}[]
        if tab == :nets
            nets = [n for n in net_names if isempty(f) || occursin(f, lowercase(n))]
            st.filtered_nets = nets
            for n in nets
                cl = netclass(st.setup, n)
                push!(items, n); push!(tags, CLASS_TAGS[cl]); push!(tcols, CLASS_COLORS[cl]); push!(keys, (:net, n))
            end
        elseif tab == :comps
            byref = Dict{String,Vector{Element}}()
            for e in st.setup.elements
                push!(get!(byref, e.ref, Element[]), e)
            end
            for c in comp_sorted
                txt = rpad(c.ref, 7) * (isempty(c.value) ? c.footprint_name : c.value)
                isempty(f) || occursin(f, lowercase(txt * " " * c.footprint_name)) || continue
                els = get(byref, c.ref, Element[])
                push!(items, txt); push!(keys, (:comp, c.ref))
                push!(tags, isempty(els) ? "" : KIND_TAGS[els[1].kind] * (length(els) > 1 ? "+" : ""))
                push!(tcols, isempty(els) ? RGBf(1, 1, 1) : KIND_COLORS[els[1].kind])
            end
        else
            for e in sort(st.setup.elements; by = elem_order)
                txt = element_summary(e)
                isempty(f) || occursin(f, lowercase(txt)) || continue
                push!(items, txt); push!(tags, KIND_TAGS[e.kind]); push!(tcols, KIND_COLORS[e.kind]); push!(keys, (:elem, e.id))
            end
        end
        cur_keys[] = keys
        syncing[] = true
        set_items!(browser, items; tags = tags, tagcolors = tcols, keep = keep)
        syncing[] = false
        sync_browser!()
    end

    on(browser.selected) do i
        syncing[] && return
        1 <= i <= length(cur_keys[]) || return
        key = cur_keys[][i]
        key == browser_key(st.sel[], tabs_l.active[]) && return
        st.sel[] = key
    end

    clear_armed = Ref(false)
    function build_leftfoot!(p)
        h = p.host
        tab = tabs_l.active[]
        if tab == :nets
            blk!(p, Label(h[1, 1:4], "Set class of all filtered nets:"; halign = :left, color = :gray65, fontsize = 12, tellwidth = false))
            for (i, c) in enumerate(NET_CLASSES)
                b = blk!(p, Button(h[2, i]; label = CLASS_TAGS[c] == " — " ? "None" : CLASS_TAGS[c], tellwidth = false,
                                   width = Relative(1), padding = (4, 4, 4, 4), labelcolor = lighten(CLASS_COLORS[c], 0.3)))
                on(b.clicks) do _
                    if isempty(filt())
                        say("Type a filter first (e.g. GND), then click a class to apply it to the matching nets.")
                        return
                    end
                    k = count(n -> set_class!(st.setup, n, c), st.filtered_nets)
                    k > 0 && changed!(st; classes = true)
                    say("Set $k net(s) matching '$(filt())' to $(CLASS_LABELS[c]).")
                    request!(st, :inspector)
                end
            end
            colgap!(h, 4)
        elseif tab == :comps
            blk!(p, Label(h[1, 1], "Click a part (here or in 3D) to open its lumped\nmodel in the Inspector.";
                          halign = :left, color = :gray55, fontsize = 11, tellwidth = false, justification = :left))
        else
            b1 = blk!(p, Button(h[1, 1]; label = "Remove selected", tellwidth = false, width = Relative(1)))
            b2 = blk!(p, Button(h[1, 2]; label = "Clear all", tellwidth = false, width = Relative(1)))
            on(b1.clicks) do _
                kind, name = st.sel[]
                kind == :elem || return say("Select an element in the list first.")
                filter!(e -> e.id != name, st.setup.elements)
                changed!(st)
                say("Removed $name")
                st.sel[] = (:none, "")
            end
            on(b2.clicks) do _
                if !clear_armed[]
                    clear_armed[] = true
                    b2.label[] = "Click again to clear"
                    return
                end
                clear_armed[] = false
                b2.label[] = "Clear all"
                n = length(st.setup.elements)
                empty!(st.setup.elements)
                changed!(st)
                say("Removed all $n element(s).")
                st.sel[] = (:none, "")
            end
        end
    end

    on(filter_tb.displayed_string) do _; refresh_browser!(false); end
    on(tabs_l.active) do _
        refresh_browser!(false)
        rebuild!(build_leftfoot!, leftfoot)
    end

    # ── right dock: inspector / view ─────────────────────────────────────────
    tabs_r = TabBar(GridLayout(right[1, 1]), [:inspector => "Inspector", :analysis => "Analysis", :view => "View"])
    rpanel = DynPanel(GridLayout(right[2, 1]; valign = :top, tellheight = false))
    rowgap!(right, 8)

    function build_view_panel!(p)
        h = p.host
        r = 1
        head!(text) = (blk!(p, Label(h[r, 1:2], text; font = :bold, halign = :left, color = :gray65, fontsize = 12,
                                     tellwidth = false)); r += 1)
        head!("DISPLAY")
        for (sym, label, opts) in DISPLAY_OPTS
            blk!(p, Label(h[r, 1], label; halign = :left))
            m = blk!(p, Menu(h[r, 2]; options = opts, default = st.modes[sym][], width = Relative(1), tellwidth = false))
            on(m.selection) do s; s === nothing || (st.modes[sym][] = s); end
            r += 1
        end
        blk!(p, Label(h[r, 1], "Color by"; halign = :left))
        m = blk!(p, Menu(h[r, 2]; options = ["Layer", "Net class"], default = st.color_by[], width = Relative(1), tellwidth = false))
        on(m.selection) do s; s === nothing || (st.color_by[] = s); end
        r += 1

        head!("LAYERS")
        g = sub!(p, h[r, 1:2]); r += 1
        for (i, name) in enumerate(st.layer_names)
            cb = CheckRow(g, i, name; checked = st.layer_on[name][], color = layer_color(name), p = p)
            on(cb.checked) do val; st.layer_on[name][] = val; end
        end
        rowgap!(g, 3)

        head!("BOARD")
        g = sub!(p, h[r, 1:2]); r += 1
        cb = CheckRow(g, 1, "Board outline"; checked = st.show_outline[], p = p)
        on(cb.checked) do val; st.show_outline[] = val; end
        if st.diel_defined
            cb = CheckRow(g, 2, "Dielectric"; checked = st.show_diel[], p = p)
            on(cb.checked) do val; st.show_diel[] = val; end
        else
            blk!(p, Label(g[2, 1:2], "Dielectric (no stackup in board)"; halign = :left, color = :gray50))
        end
        cb = CheckRow(g, 3, "Markers for passive models"; checked = st.show_passive_markers[], p = p)
        on(cb.checked) do val; st.show_passive_markers[] = val; end
        rowgap!(g, 3)

        head!("VERTICAL SCALE")
        g = sub!(p, h[r, 1:2]); r += 1
        sl = blk!(p, Slider(g[1, 1]; range = 1.0:0.1:MAX_ZSCALE, startvalue = st.exag[], tellwidth = false))
        tb = blk!(p, Textbox(g[1, 2]; stored_string = string(round(st.exag[], digits = 1)), width = 55,
                             validator = s -> (x = tryparse(Float64, s); x !== nothing && 1 <= x <= MAX_ZSCALE)))
        blk!(p, Label(g[2, 1:2], st.diel_defined ? "1 = true thickness (board stackup)" : "1 = nominal 1.6 mm board";
                      halign = :left, color = :gray55, fontsize = 11, tellwidth = false))
        colgap!(g, 6)
        on(sl.value) do x
            st.exag[] = x
            tb.displayed_string[] = string(round(x, digits = 1))
        end
        on(tb.stored_string) do s
            x = tryparse(Float64, something(s, ""))
            x === nothing || Makie.set_close_to!(sl, x)
        end

        if !isempty(board.stackup)
            head!("STACKUP")
            txt = join([rpad(first(s.name, 12), 13) * rpad(first(s.kind, 8), 9) * string(s.thickness) * " mm"
                        for s in board.stackup if s.thickness > 0], "\n")
            blk!(p, Label(h[r, 1:2], txt; halign = :left, justification = :left, fontsize = 11, color = :gray70,
                          tellwidth = false, font = :regular)); r += 1
        end
        head!("ABOUT")
        blk!(p, Label(h[r, 1:2], ABOUT_TEXT * "\nVersion " * version; halign = :left, justification = :left, fontsize = 11,
                      color = :gray70, tellwidth = false)); r += 1
        rowgap!(h, 5)
    end

    function flush_ui!()
        isempty(st.pending) && return
        tab = tabs_r.active[]
        want = (:right in st.pending) || (tab in st.pending) ||
               (tab == :analysis && any(k -> k in st.pending, (:results, :signals)))
        bottom_want = :impedance in st.pending || :si_table in st.pending
        empty!(st.pending)
        if bottom_want
            if tabs_b.active[] == :impedance
                GLMakie.Makie.hide!(console.ax)
                rebuild!(p -> build_impedance_panel!(p, st; run! = () -> run_ac!()), zpanel)
            elseif tabs_b.active[] == :signals
                GLMakie.Makie.hide!(console.ax)
                rebuild!(p -> build_si_table!(p, st; run! = () -> run_si!()), zpanel)
            else
                rebuild!(_ -> nothing, zpanel)
                GLMakie.Makie.unhide!(console.ax)
            end
        end
        want || return
        rebuild!(rpanel) do p
            tab == :inspector ? build_inspector!(p, st) :
            tab == :analysis  ? build_analysis_panel!(p, st; run_dc! = () -> run_dc!(), run_ac! = () -> run_ac!(),
                                                      run_si! = () -> run_si!(), select! = (s, a) -> select_analysis!(s, a),
                                                      maxrows = row_budget()) :
                                build_view_panel!(p)
        end
    end
    on(events(fig).tick) do _
        flush_ui!()
    end
    on(tabs_r.active) do _; request!(st, :right); end

    "Show an analysis in the Analysis tab, with its overlay on the copper and its bottom tab."
    function select_analysis!(src::Symbol, an = nothing)
        vw = st.setup.view
        vw["source"] = string(src)
        src == :pi && an !== nothing && (vw["pi_analysis"] = string(an))
        _, a = current_analysis(st)
        ok(r) = r !== nothing && r.ok
        m = st.result_mode[]
        if a == :dc
            st.result_mode[] = ok(st.result[]) ? (m in DC_MODES ? m : "Voltage") : "Off"
        elseif a == :ac
            st.result_mode[] = ok(st.ac_result[]) && st.ac_freq[] > 0 ? AC_MODE : "Off"
            ok(st.ac_result[]) && (tabs_b.active[] = :impedance)
        else
            st.result_mode[] = ok(st.si_result[]) ? (is_si_mode(m) ? m : "SI vs target") : "Off"
            ok(st.si_result[]) && (tabs_b.active[] = :signals)
        end
        tabs_r.active[] = :analysis
        request!(st, :analysis)
    end

    # ── selection / changes ──────────────────────────────────────────────────
    on(st.sel) do s
        s[1] != :none && tabs_r.active[] == :view && (tabs_r.active[] = :inspector)
        request!(st, :inspector)
        sync_browser!()
    end
    on(st.rev) do _
        update_title()
        refresh_browser!(true)
        request!(st, :analysis)                     # "setup changed since this run" note
        request!(st, :signals)
    end
    on(st.result) do _
        request!(st, :analysis)
    end
    on(st.ac_result) do _
        request!(st, :analysis)
        request!(st, :impedance)
    end
    on(st.result_mode) do _
        request!(st, :signals)
        request!(st, :analysis)
    end
    on(st.si_result) do _
        request!(st, :signals)
        request!(st, :si_table)
        request!(st, :inspector)
    end
    on(tabs_b.active) do _
        request!(st, :impedance)
    end
    on(st.exag) do _
        refit_if_untouched!(bs)
    end

    # ── 3D mouse: click to select, hover readout ─────────────────────────────
    press_pos = Ref((0.0, 0.0))
    on(events(fig).mousebutton; priority = 10) do ev
        ev.button == Mouse.left || return Consume(false)
        mp = events(fig).mouseposition[]
        if ev.action == Mouse.press
            press_pos[] = mp
        elseif ev.action == Mouse.release
            hypot(mp[1] - press_pos[][1], mp[2] - press_pos[][2]) > 4 && return Consume(false)
            is_mouseinside(bs.scene) || return Consume(false)
            t = pick_target(bs)
            t === nothing && return Consume(false)
            t[1] == :comp && sel_component(st) == t[2] && return Consume(false)   # keep an open element
            st.sel[] = t
            say(t[1] == :net ? "Selected net $(t[2])" : "Selected component $(t[2])")
        end
        return Consume(false)
    end
    last_hover = Ref(0.0)
    on(events(fig).mouseposition) do _
        t = time()
        t - last_hover[] < 0.06 && return
        last_hover[] = t
        is_mouseinside(bs.scene) || return
        (ispressed(fig, Mouse.left) || ispressed(fig, Mouse.right)) && return
        s = hover_info(bs, st)
        s === nothing || (status.text[] = s)
    end

    # ── view buttons ─────────────────────────────────────────────────────────
    for (k, b) in vbtn
        on(b.clicks) do _; set_view!(bs, k); end
    end

    # ── save / recovery ──────────────────────────────────────────────────────
    function store_view!()
        vw = st.setup.view
        vw["zscale"] = round(st.exag[], digits = 2)
        vw["color_by"] = st.color_by[]
        vw["result_mode"] = st.result_mode[]
        vw["result_net"] = st.result_net[]
        for (sym, _, _) in DISPLAY_OPTS
            vw["mode_" * string(sym)] = st.modes[sym][]
        end
        vw["show_outline"] = st.show_outline[]
        vw["show_dielectric"] = st.show_diel[]
        vw["show_passive_markers"] = st.show_passive_markers[]
        vw["hidden_layers"] = [n for n in st.layer_names if !st.layer_on[n][]]
        vw["left_width"] = round(wl[]); vw["right_width"] = round(wr[]); vw["console_height"] = round(hc[])
    end
    rpath = recovery_path(setup.board_file)
    function do_save!()
        store_view!()
        path = save_setup(st.setup)
        isfile(rpath) && rm(rpath; force = true)
        say("Saved $(basename(path))")
        status.text[] = "Saved $(basename(path))"
        update_title()
    end
    on(btn_save.clicks) do _
        try
            do_save!()
        catch err
            say("ERROR saving: " * sprint(showerror, err))
        end
    end
    show && on(events(fig).window_open) do isopen
        if !isopen && st.setup.dirty && st.rev[] > 0          # only if something was changed this session
            try
                store_view!()
                p = save_setup(st.setup, rpath; mark_clean = false)
                println("[viewer] Unsaved changes written to $p")
                println("[viewer] Open the board again and type 'recover' to restore them.")
            catch err
                println("[viewer] Could not write recovery file: ", sprint(showerror, err))
            end
        end
    end
    function do_recover!()
        isfile(rpath) || return say("No recovery file ($(basename(rpath))).")
        rs, _ = load_setup(setup.board_file, board; path = rpath)
        st.setup.netclass = rs.netclass
        st.setup.elements = rs.elements
        changed!(st; classes = true)
        st.sel[] = (:none, "")
        say("Recovered $(length(rs.elements)) element(s) and net classes from $(basename(rpath)). Save to keep them.")
    end

    # ── DC setup check / simulation entry point ──────────────────────────────
    function run_check!()
        errs, warns, summary = validate_dc(st.setup, board)
        say("[dc] ── DC setup check ──")
        isempty(summary) ? say("[dc]   no rails yet (add a VRM and sinks)") : foreach(l -> say("[dc]   " * l), summary)
        foreach(w -> say("[dc] WARNING: " * w), warns)
        foreach(e -> say("[dc] ERROR: " * e), errs)
        if !isempty(errs)
            status.text[] = "DC setup: $(length(errs)) error(s), $(length(warns)) warning(s)"
            return false
        end
        status.text[] = "DC setup OK" * (isempty(warns) ? "" : " ($(length(warns)) warning(s))")
        return true
    end

    function run_dc!()
        run_check!() || return
        say("[dc] Solving…")
        res = try
            solve_dc(board, st.setup; log = say)
        catch err
            say("[dc] ERROR: " * sprint(showerror, err))
            status.text[] = "DC analysis failed (see console)"
            return
        end
        foreach(l -> say("[dc] " * l), dc_summary_lines(res))
        st.result_rev = st.rev[]
        st.result[] = res
        if res.ok
            select_analysis!(:pi, :dc)
            if isempty(res.sinks)
                status.text[] = @sprintf("DC solved in %.1f s", res.seconds)
            else
                w = res.sinks[argmax([s.pct for s in res.sinks])]
                status.text[] = @sprintf("DC: worst sink %s −%.2f mV (%.2f%%)", w.id, w.drop_mV, w.pct)
            end
        else
            status.text[] = "DC analysis failed (see console)"
        end
        if on_simulate !== nothing && res.ok
            try
                on_simulate(board, st.setup)
            catch err
                say("[dc] on_simulate hook error: " * sprint(showerror, err))
            end
        end
    end

    function run_ac!()
        if !any(e -> e.kind == :sink, st.setup.elements)
            say("[ac] Add at least one sink: each sink is an impedance port.")
            status.text[] = "AC: no ports (sinks) defined"
            return
        end
        say("[ac] Sweeping PDN impedance…")
        res = try
            solve_ac(board, st.setup; log = say)
        catch err
            say("[ac] ERROR: " * sprint(showerror, err))
            status.text[] = "AC sweep failed (see console)"
            return
        end
        foreach(l -> say("[ac] " * l), ac_summary_lines(res))
        st.ac_rev = st.rev[]
        st.ac_result[] = res
        if res.ok
            st.ac_port[] = clamp(st.ac_port[], 1, max(1, length(res.ports)))
            select_analysis!(:pi, :ac)
            tabs_b.active[] = :impedance
            bad = [p for p in res.ports if !isempty(target_violations(res.freqs, p.Z, p.target))]
            status.text[] = isempty(bad) ? "AC: all ports meet their target impedance" :
                            "AC: $(length(bad)) port(s) above target (see the PDN impedance tab)"
        else
            status.text[] = "AC sweep failed (see console)"
        end
    end

    function run_si!()
        say("[si] Analysing signal integrity (impedance, return paths, lengths)…")
        res = try
            solve_si(board, st.setup; log = say)
        catch err
            say("[si] ERROR: " * sprint(showerror, err))
            status.text[] = "SI analysis failed (see console)"
            return
        end
        foreach(l -> say("[si] " * l), res.messages)
        foreach(l -> say("[si] " * l), si_summary_lines(res))
        st.si_rev = st.rev[]
        st.si_issue[] = 0
        st.si_result[] = res
        if res.ok
            select_analysis!(:si)
            ne = count(i -> i.severity == :error, res.issues)
            nw = count(i -> i.severity == :warning, res.issues)
            bad = count(p -> !(p.z_ok && p.skew_ok), res.pairs)
            status.text[] = "SI: $ne error(s), $nw warning(s)" * (isempty(res.pairs) ? "" : " · $bad of $(length(res.pairs)) pair(s) off spec")
        else
            status.text[] = "SI analysis failed (see console)"
        end
    end

    # ── report ───────────────────────────────────────────────────────────────
    screen_ref = Ref{Any}(nothing)
    "PNG of the 3D view only (cropped from the rendered window)."
    function capture_3d(path)
        flush_ui!()
        img = screen_ref[] === nothing ? GLMakie.Makie.colorbuffer(fig) : GLMakie.Makie.colorbuffer(screen_ref[])
        fw = widths(fig.scene.viewport[])[1]
        sc = size(img, 2) / fw
        vp = bs.scene.viewport[]
        x0, y0 = round.(Int, GLMakie.Makie.GeometryBasics.origin(vp) .* sc)
        w, h = round.(Int, widths(vp) .* sc)
        H = size(img, 1)
        img = img[clamp(H - (y0 + h) + 1, 1, H):clamp(H - y0, 1, H), clamp(x0 + 1, 1, size(img, 2)):clamp(x0 + w, 1, size(img, 2))]
        # trim the empty background around the board (keep a margin)
        bg = img[1, 1]
        diff(c) = abs(Float32(c.r) - Float32(bg.r)) + abs(Float32(c.g) - Float32(bg.g)) + abs(Float32(c.b) - Float32(bg.b)) > 0.06f0
        rows = findall(i -> any(diff, @view img[i, :]), axes(img, 1))
        cols = findall(j -> any(diff, @view img[:, j]), axes(img, 2))
        if !isempty(rows) && !isempty(cols)
            m = round(Int, 0.03 * max(length(rows), length(cols)))
            img = img[max(1, rows[1] - m):min(end, rows[end] + m), max(1, cols[1] - m):min(end, cols[end] + m)]
        end
        save(path, img)
        return path
    end
    function run_report!(; open_it::Bool = true)
        dc = st.result[]; ac = st.ac_result[]; si = st.si_result[]
        any(r -> r !== nothing && r.ok, (dc, ac, si)) || (say("[report] Run at least one analysis first (DC, AC or SI)."); return nothing)
        say("[report] Writing the report…")
        prev_mode, prev_view = st.result_mode[], bs.view[]
        images = Tuple{Symbol,String,String}[]
        dir = mktempdir()
        try
            set_view!(bs, :top)
            shots = Tuple{Symbol,String,String}[]
            if dc !== nothing && dc.ok
                push!(shots, (:dc, "Voltage", "DC voltage on $(shown_rail(st, dc)) (top view, all layers)"),
                             (:dc, "IR drop", "IR drop (mV) on the simulated nets"))
            end
            if si !== nothing && si.ok
                push!(shots, (:si, "SI vs target", "Signal traces against their impedance targets (green ok, red outside, grey no target, magenta no reference); ◆ findings"),
                             (:si, "SI impedance", "Signal trace impedance (Zdiff where pairs run coupled), turbo scale $(join(round.(Int, si_overlay_range(si)), "–")) Ω"))
            end
            for (k, (sec, mode, cap)) in enumerate(shots)
                st.result_mode[] = mode
                push!(images, (sec, cap, capture_3d(joinpath(dir, "shot$k.png"))))
            end
        catch err
            say("[report] could not capture the 3D view: " * sprint(showerror, err))
        finally
            st.result_mode[] = prev_mode
            set_view!(bs, prev_view)
        end
        path = report_path(setup.board_file)
        try
            write_report(path; board, setup = st.setup, dc, ac, si, images, version, logo = asset_path("icons", "icon_64.png"))
        catch err
            say("[report] ERROR: " * sprint(showerror, err))
            status.text[] = "Report failed (see console)"
            return nothing
        end
        say("[report] Wrote $path")
        status.text[] = "Report: $(basename(path))"
        if open_it
            try
                cmd = Sys.iswindows() ? `cmd /c start "" $path` : Sys.isapple() ? `open $path` : `xdg-open $path`
                run(pipeline(cmd; stdout = devnull, stderr = devnull); wait = false)
            catch err
                say("[report] Open it in a browser: $path")
            end
        end
        return path
    end
    on(btn_report.clicks) do _; run_report!(); end

    # ── console commands ─────────────────────────────────────────────────────
    function find_net(q)
        ql = lowercase(q)
        i = findfirst(n -> lowercase(n) == ql, net_names)
        i === nothing && (i = findfirst(n -> occursin(ql, lowercase(n)), net_names))
        return i === nothing ? nothing : net_names[i]
    end
    function set_visible!(what, state)
        if what == "outline"
            st.show_outline[] = state
        elseif what == "dielectric"
            diel_defined ? (st.show_diel[] = state) : say("Dielectric is not defined in this board.")
        else
            k = findfirst(n -> lowercase(n) == what, st.layer_names)
            k === nothing ? say("Unknown item '$what'. Try: layers, outline, dielectric") : (st.layer_on[st.layer_names[k]][] = state)
        end
        request!(st, :inspector)          # the View tab mirrors these (rebuilt if it is open)
        tabs_r.active[] == :view && request!(st, :right)
    end
    function element_cmd(rest)
        sub = isempty(rest) ? "list" : lowercase(rest[1])
        if sub == "add"
            length(rest) < 3 && return say("Usage: element add <kind> <REF> [+net] [-net] [P=value …]")
            kind = get(KIND_ALIASES, lowercase(rest[2]), nothing)
            kind === nothing && return say("Unknown kind '$(rest[2])'. Kinds: vrm sink r l fb short c")
            c = get(st.comps, String(rest[3]), nothing)
            c === nothing && return say("No component '$(rest[3])'.")
            e = default_element(kind, c, st.setup)
            nets = String[]
            for a in rest[4:end]
                if occursin('=', a)
                    k, val = split(a, '='; limit = 2)
                    x = parse_si(val)
                    i = findfirst(ps -> lowercase(ps.name) == lowercase(k), KIND_SPECS[kind].params)
                    (x === nothing || i === nothing) && return say("Bad parameter '$a'.")
                    e.params[KIND_SPECS[kind].params[i].name] = x
                else
                    n = String(a) in board.nets ? String(a) : find_net(String(a))
                    n === nothing && return say("No net '$a'.")
                    push!(nets, n)
                end
            end
            length(nets) >= 1 && (e.net_pos = nets[1])
            length(nets) >= 2 && (e.net_neg = nets[2])
            push!(st.setup.elements, e)
            changed!(st)
            st.sel[] = (:elem, e.id)
            say("Added " * element_summary(e))
        elseif sub == "rm" && length(rest) >= 2
            n = length(st.setup.elements)
            filter!(e -> e.id != rest[2], st.setup.elements)
            length(st.setup.elements) == n ? say("No element '$(rest[2])'.") : (changed!(st); say("Removed $(rest[2])"))
        else
            isempty(st.setup.elements) && say("No elements defined.")
            foreach(e -> say("  " * rpad(KIND_TAGS[e.kind], 4) * element_summary(e)), sort(st.setup.elements; by = elem_order))
        end
    end
    function class_cmd(rest)
        length(rest) < 2 && return say("Usage: class <net|pattern*> <power|ground|digital|none>")
        cls = get(CLASS_ALIASES, lowercase(rest[end]), nothing)
        cls === nothing && return say("Class must be power, ground, digital or none.")
        pat = String(rest[1])
        targets = if occursin('*', pat)
            re = Regex("^" * replace(pat, r"[.+^$()\[\]{}|\\?]" => s"\\\0", "*" => ".*") * "\$", "i")
            [n for n in net_names if occursin(re, n)]
        else
            i = findfirst(n -> lowercase(n) == lowercase(pat), net_names)
            i === nothing ? String[] : [net_names[i]]
        end
        isempty(targets) && return say("No net matches '$pat' (use * as a wildcard, e.g. class +3V* power).")
        k = count(n -> set_class!(st.setup, n, cls), targets)
        k > 0 && changed!(st; classes = true)
        request!(st, :inspector)
        say("$(CLASS_LABELS[cls]): $(join(first(targets, 8), ", "))" * (length(targets) > 8 ? " …" : "") *
            "  ($k changed)")
    end

    function target_cmd(rest)
        ts = si_targets(st.setup)
        if isempty(rest)
            isempty(ts) && return say("No impedance targets (impedances are reported but not checked).")
            foreach(t -> say(@sprintf("  %-20s %-6s %g Ω ±%s%%", t.pattern, t.mode == :diff ? "diff" : "single", t.z,
                                      isnan(t.tol_pct) ? "default" : string(t.tol_pct))), ts)
            return
        end
        sub = lowercase(rest[1])
        if sub == "reset"
            delete!(st.setup.si, "targets"); changed!(st)
            return say("[si] targets reset to the defaults (USB pairs 90 Ω differential)")
        elseif sub == "rm" && length(rest) >= 2
            keep = [t for t in ts if t.pattern != rest[2]]
            length(keep) == length(ts) && return say("No target '$(rest[2])'.")
            set_si_targets!(st.setup, keep); changed!(st)
            return say("[si] removed target $(rest[2])")
        end
        length(rest) < 2 && return say("Usage: target <pattern> <Ω> [tol%] [diff]   e.g. target *CLK* 50 10")
        z = parse_si(String(rest[2]))
        (z === nothing || z <= 0) && return say("Impedance must be a positive number of ohms.")
        tol = NaN
        mode = :se
        for a in rest[3:end]
            la = lowercase(a)
            la in ("diff", "differential", "pair") ? (mode = :diff) :
            la in ("se", "single") ? (mode = :se) :
            (x = tryparse(Float64, rstrip(la, '%')); x === nothing ? say("Ignored '$a'.") : (tol = x))
        end
        set_si_targets!(st.setup, vcat(filter(t -> !(t.pattern == rest[1] && t.mode == mode), ts),
                                       [ZTarget(String(rest[1]), z, tol, mode)]))
        changed!(st)
        say("[si] target $(rest[1]) $(mode == :diff ? "differential" : "single-ended") $(z) Ω" *
            (isnan(tol) ? "" : " ±$(tol)%") * " (run again to apply)")
    end
    function group_cmd(rest)
        gs = si_groups(st.setup)
        if isempty(rest)
            isempty(gs) && return say("No length-match groups. Usage: group add <name> <tol> <pattern…> [delay]")
            foreach(g -> say("  $(rpad(g.name, 14)) ≤ $(g.tol) $(g.by == :delay ? "ps" : "mm")   $(join(g.patterns, " "))"), gs)
            return
        end
        sub = lowercase(rest[1])
        if sub == "rm" && length(rest) >= 2
            keep = [g for g in gs if g.name != rest[2]]
            length(keep) == length(gs) && return say("No group '$(rest[2])'.")
            set_si_groups!(st.setup, keep); changed!(st)
            return say("[si] removed group $(rest[2])")
        elseif sub == "add" && length(rest) >= 4
            tol = parse_si(String(rest[3]))
            tol === nothing && return say("Tolerance must be a number (mm, or ps with 'delay').")
            pats = String[String(a) for a in rest[4:end] if lowercase(a) != "delay"]
            by = any(a -> lowercase(a) == "delay", rest[4:end]) ? :delay : :length
            isempty(pats) && return say("Give at least one net pattern, e.g. DQ*.")
            set_si_groups!(st.setup, vcat(filter(g -> g.name != rest[2], gs), [GroupDef(String(rest[2]), pats, tol, by)]))
            changed!(st)
            return say("[si] group $(rest[2]): $(join(pats, " ")) within $tol $(by == :delay ? "ps" : "mm") (run again to apply)")
        end
        say("Usage: group add <name> <tol> <pattern…> [delay]   |   group rm <name>   |   group")
    end

    function exec(line)
        line = strip(line)
        isempty(line) && return
        say("▸ " * line)
        args = split(line)
        cmd = lowercase(args[1])
        rest = args[2:end]
        try
            if cmd == "help"
                say(HELP)
            elseif cmd == "clear"
                set_items!(console, String[])
            elseif cmd == "about"
                foreach(l -> say("  " * l), split(ABOUT_TEXT * "\nVersion " * version, '\n'))
            elseif cmd == "info"
                say("Board $(round(board.width, digits = 1)) × $(round(board.height, digits = 1)) mm | " *
                    "$(length(board.nets)) nets | $(length(board.components)) components | " *
                    "$(length(board.traces)) segments | $(length(board.vias)) vias | $(length(board.zones)) pours | " *
                    "$(length(st.setup.elements)) sim elements")
            elseif cmd == "layers"
                for L in layers
                    say("  $(rpad(L.name, 8)) z = $(round(zcu[L.name], digits = 3)) mm   $(st.layer_on[L.name][] ? "visible" : "hidden")")
                end
            elseif cmd == "stackup"
                isempty(board.stackup) && return say("No stackup defined in this board (KiCad: Board Setup → Board Stackup).")
                for s in board.stackup
                    say("  $(rpad(s.name, 16)) $(rpad(s.kind, 18)) $(s.thickness) mm  $(s.material)" *
                        (s.epsilon_r > 0 ? "  εr=$(s.epsilon_r)" : "") * (s.loss_tangent > 0 ? "  tanδ=$(s.loss_tangent)" : ""))
                end
            elseif cmd == "nets"
                f = isempty(rest) ? "" : lowercase(rest[1])
                hits = [n for n in net_names if isempty(f) || occursin(f, lowercase(n))]
                foreach(n -> say("  [" * CLASS_TAGS[netclass(st.setup, n)] * "] " * n), first(hits, 40))
                say("  ($(length(hits)) nets" * (length(hits) > 40 ? ", showing 40" : "") * ")")
            elseif cmd == "comps"
                f = isempty(rest) ? "" : lowercase(rest[1])
                hits = [rpad(c.ref, 8) * c.value for c in comp_sorted if isempty(f) || occursin(f, lowercase(c.ref * " " * c.value))]
                foreach(s -> say("  " * s), first(hits, 40))
                say("  ($(length(hits)) components" * (length(hits) > 40 ? ", showing 40" : "") * ")")
            elseif cmd == "net"
                n = isempty(rest) ? nothing : find_net(String(rest[1]))
                n === nothing ? say("No such net.") : (st.sel[] = (:net, n); say("Selected net $n"))
            elseif cmd == "comp"
                c = isempty(rest) ? nothing : get(st.comps, String(rest[1]), nothing)
                c === nothing ? say("No such component.") : (st.sel[] = (:comp, c.ref); say("Selected $(c.ref)"))
            elseif cmd == "deselect"
                st.sel[] = (:none, "")
            elseif cmd == "class"
                class_cmd(rest)
            elseif cmd == "element" || cmd == "el"
                element_cmd(rest)
            elseif cmd == "check"
                run_check!()
            elseif cmd == "dc" || cmd == "run"
                run_dc!()
            elseif cmd == "ac"
                run_ac!()
            elseif cmd == "si"
                run_si!()
            elseif cmd == "target" || cmd == "targets"
                target_cmd(rest)
            elseif cmd == "group" || cmd == "groups"
                group_cmd(rest)
            elseif cmd == "siset"
                keys_ = [k for (k, _, _, _) in SI_SETTING_SPECS]
                (length(rest) < 2 || !(rest[1] in keys_)) && return say("Usage: siset <$(join(keys_, "|"))> <value>")
                x = parse_si(String(rest[2]))
                (x === nothing || x < 0) && return say("Value must be a number ≥ 0.")
                st.setup.si[String(rest[1])] = x
                changed!(st)
                say("[si] $(rest[1]) = $(format_si(x, "")) (run again to apply)")
            elseif cmd == "pairs"
                res = st.si_result[]
                (res === nothing || !res.ok) && return say("Run the SI analysis first (si).")
                isempty(res.pairs) && return say("No differential pairs found (pairs are found by name: _P/_N, +/-, DP/DM …).")
                foreach(p -> say(@sprintf("  %-28s Zdiff %6.1f Ω  skew %.3f mm  %s", p.name, p.zd_avg, p.skew,
                                          p.z_ok && p.skew_ok ? "ok" : "OFF SPEC")), res.pairs)
            elseif cmd == "issues"
                res = st.si_result[]
                (res === nothing || !res.ok) && return say("Run the SI analysis first (si).")
                all_ = !isempty(rest) && lowercase(rest[1]) == "all"
                shown = [i for i in res.issues if all_ || i.severity != :info]
                foreach(i -> say("  " * rpad(uppercase(string(i.severity)), 8) * i.text), first(shown, 60))
                say("  ($(length(shown)) shown" * (all_ ? "" : ", 'issues all' includes notes") * ")")
            elseif cmd == "acset"
                keys_ = [k for (k, _, _, _) in AC_SETTING_SPECS]
                (length(rest) < 2 || !(rest[1] in keys_)) && return say("Usage: acset <$(join(keys_, "|"))> <value>  (e.g. acset f_stop 2G)")
                x = parse_si(String(rest[2]))
                (x === nothing || x < 0) && return say("Value must be a number ≥ 0 (SI suffixes allowed).")
                st.setup.ac[String(rest[1])] = x
                changed!(st)
                say("[ac] $(rest[1]) = $(format_si(x, "")) (run again to apply)")
            elseif cmd == "freq"
                res = st.ac_result[]
                (res === nothing || !res.ok) && return say("Run the AC sweep first.")
                isempty(rest) && return say("freq = $(format_si(st.ac_freq[], "Hz"))")
                x = parse_si(String(rest[1]))
                x === nothing && return say("Usage: freq <Hz>  (e.g. freq 120M)")
                st.ac_freq[] = x
                st.result_mode[] = AC_MODE
                request!(st, :analysis)
                say("[ac] 3D map at $(format_si(x, "Hz"))")
            elseif cmd == "port"
                res = st.ac_result[]
                (res === nothing || !res.ok) && return say("Run the AC sweep first.")
                i = isempty(rest) ? nothing : findfirst(p -> lowercase(p.id) == lowercase(rest[1]), res.ports)
                i === nothing && return say("Ports: " * join([p.id for p in res.ports], ", "))
                st.ac_port[] = i
                request!(st, :impedance)
            elseif cmd == "overlay"
                isempty(rest) && return say("overlay = $(st.result_mode[])")
                a = lowercase(rest[1])
                st.result_mode[] = a in ("voltage", "v", "volts") ? "Voltage" : a in ("drop", "ir") ? "IR drop" :
                                   a in ("density", "j", "current") ? "Current density" :
                                   a in ("z", "impedance") ? "SI impedance" : a in ("target", "targets") ? "SI vs target" :
                                   a in ("ref", "reference") ? "SI reference" : "Off"
                request!(st, :analysis)
            elseif cmd == "rail"
                res = st.result[]
                (res === nothing || !res.ok) && return say("Run the DC analysis first.")
                isempty(rest) && return say("rail = $(shown_rail(st, res))   (choices: $(join(voltage_rails(res), ", ")))")
                n = findfirst(x -> lowercase(x) == lowercase(rest[1]), res.nets)
                n === nothing && return say("'$(rest[1])' is not a simulated net. Choices: $(join(voltage_rails(res), ", "))")
                st.result_net[] = res.nets[n]
                st.result_mode[] = "Voltage"
                request!(st, :analysis)
            elseif cmd == "dcset"
                keys_ = [k for (k, _, _, _) in DC_SETTING_SPECS]
                (length(rest) < 2 || !(rest[1] in keys_)) && return say("Usage: dcset <$(join(keys_, "|"))> <value>")
                x = tryparse(Float64, rest[2])
                (x === nothing || x < 0) && return say("Value must be a number ≥ 0.")
                st.setup.dc[String(rest[1])] = x
                changed!(st)
                say("[dc] $(rest[1]) = $x (run again to apply)")
            elseif cmd == "save"
                do_save!()
            elseif cmd == "report"
                run_report!(; open_it = !isempty(rest) && lowercase(rest[1]) == "open")
            elseif cmd == "recover"
                do_recover!()
            elseif cmd == "show" || cmd == "hide"
                isempty(rest) ? say("Usage: $cmd <layer|outline|dielectric>") : set_visible!(lowercase(String(rest[1])), cmd == "show")
            elseif cmd == "mode"
                length(rest) < 2 && return say("Usage: mode <traces|pads|vias|pours|bodies> <solid|translucent|wire|off>")
                cat = Symbol(lowercase(rest[1]))
                haskey(st.modes, cat) || return say("Unknown element '$(rest[1])'.")
                want = lowercase(rest[2])
                want = want == "wire" ? "wireframe" : want == "hidden" ? "off" : want
                opts = first(o for (s, _, o) in DISPLAY_OPTS if s == cat)
                i = findfirst(o -> lowercase(o) == want, opts)
                i === nothing && return say("'$(rest[2])' is not available for $(rest[1]).")
                st.modes[cat][] = opts[i]
                tabs_r.active[] == :view && request!(st, :right)
            elseif cmd == "colorby"
                isempty(rest) && return say("color by = $(st.color_by[])")
                st.color_by[] = startswith(lowercase(rest[1]), "c") ? "Net class" : "Layer"
                tabs_r.active[] == :view && request!(st, :right)
            elseif cmd == "zscale"
                isempty(rest) && return say("zscale = $(round(st.exag[], digits = 1))")
                st.exag[] = clamp(parse(Float64, rest[1]), 1.0, MAX_ZSCALE)
                tabs_r.active[] == :view && request!(st, :right)
            elseif cmd == "fit"
                set_view!(bs, :keep)
            elseif cmd == "view"
                vname = isempty(rest) ? :iso : Symbol(lowercase(rest[1]))
                vname in (:top, :iso, :side, :bottom) ? set_view!(bs, vname) : say("Views: top iso side bottom")
            else
                say("Unknown command '$cmd'. Type help.")
            end
        catch err
            say("ERROR: " * sprint(showerror, err))
        end
    end

    on(cmdbox.stored_string) do s
        s = something(s, "")
        isempty(strip(s)) && return
        exec(s)
        Makie.set!(cmdbox, "")
        cmdbox.focused[] = true
    end

    # ── startup ──────────────────────────────────────────────────────────────
    say("PerplexForge $version workbench ready.")
    foreach(l -> say(l), startup_log)
    say("Type 'help' for commands.  Left-drag orbit · right-drag pan · scroll zoom · click to select.")
    unfilled > 0 && say("NOTE: $unfilled pour(s) have no fill data and are drawn as boundaries only.")
    isfile(rpath) && say("NOTE: unsaved changes from a previous session were found. Type 'recover' to load them.")

    fit_layout!()
    update_title()
    refresh_browser!(false)
    rebuild!(build_leftfoot!, leftfoot)
    request!(st, :right)
    flush_ui!()

    screen = nothing
    if show
        screen = display(GLMakie.Screen(; title = "PerplexForge $version · " * boardname), fig)
        screen_ref[] = screen
        set_window_icon!(screen)
        set_dock_icon!(asset_path("macos", "icon_1024.png"))
        try                                                # below this the layout can't fit
            GLMakie.GLFW.SetWindowSizeLimits(screen.glscreen, 960, 600, GLMakie.GLFW.DONT_CARE, GLMakie.GLFW.DONT_CARE)
        catch
        end
        set_view!(bs, :iso)
    else
        set_view!(bs, :iso)
    end
    ui = (; fig, state = st, scene = bs, console, flush! = flush_ui!, check! = run_check!, dc! = run_dc!, ac! = run_ac!, si! = run_si!, report! = run_report!,
          select! = select_analysis!,
          tabs_bottom = tabs_b, zpanel, save! = do_save!,
          exec = exec, tabs_left = tabs_l, tabs_right = tabs_r, splitters, screen)
    block && screen !== nothing && wait(screen)
    return ui
end

end # module
