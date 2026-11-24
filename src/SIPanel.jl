module SIPanel

# Signal-integrity UI: the SI analysis in the Analysis tab (configuration, run, findings,
# pairs, groups, overlay key) and the bottom "Signals" tables (nets, pairs, cross-sections,
# findings).

using GLMakie
using Printf
using ..SimSetups
using ..WorkbenchState
using ..Widgets
using ..SISolver
using ..ResultsPanel: settings_grid!, wrap, config_header!, title!, run_button!
using ..Scene3D: SI_STATUS_COLORS, SI_KIND_COLORS

export si_panel!, build_si_table!, SI_RUN_COLOR, SI_TABLES

const SI_RUN_COLOR = RGBf(0.42, 0.25, 0.62)
const DIM = RGBf(0.55, 0.55, 0.60)
const OK_C, BAD_C = RGBf(0.45, 0.85, 0.5), RGBf(0.95, 0.40, 0.35)
const SI_TABLES = ["Nets", "Pairs", "Cross-sections", "Findings"]

section!(p, h, r, text) = blk!(p, Label(h[r, 1:2], text; font = :bold, halign = :left, color = :gray65,
                                        fontsize = 12, tellwidth = false))
line!(p, h, r, text; color = RGBf(0.85, 0.85, 0.9), fontsize = 12) =
    blk!(p, Label(h[r, 1:2], text; halign = :left, justification = :left, color = color, fontsize = fontsize, tellwidth = false))

function row_button!(p, h, r, text, color, f)
    b = blk!(p, Button(h[r, 1:2]; label = text, tellwidth = false, width = Relative(1), padding = (6, 6, 3, 3),
                       fontsize = 12, buttoncolor = RGBf(0.15, 0.15, 0.19), labelcolor = color))
    on(b.clicks) do _; f(); end
    return r + 1
end

const KIND_NAMES = Dict(:noref => "no reference", :gap => "plane gap", :split => "plane split", :return_via => "return via",
                        :stitch_cap => "stitch cap", :z => "impedance", :skew => "skew", :group => "length group", :stub => "via stub")

leaf(net) = String(last(split(net, '/')))
"A pair's name without its schematic sheet path: \"/baseband/CPOUT±\" → \"CPOUT±\"."
function pair_label(pr)
    i = findlast('/', pr.p)
    return i === nothing ? pr.name : (startswith(pr.name, pr.p[1:i]) ? pr.name[i+1:end] : pr.name)
end
clip(s, n) = length(s) <= n ? s : first(s, n - 1) * "…"

"Compact one-line label for a finding (fits the dock)."
function issue_label(i)
    who = isempty(i.net) ? "" : leaf(i.net) * " · "
    detail = if i.kind == :z
        m = match(r"(Z0|Zdiff) ([\d.]+) Ω vs target ([\d.]+) Ω", i.text)
        m === nothing ? "" : "$(m[1]) $(round(Int, parse(Float64, m[2]))) Ω vs $(m[3]) Ω"
    elseif i.kind == :skew
        m = match(r"skew ([\d.]+ mm)", i.text); m === nothing ? "" : m[1]
    elseif i.kind == :return_via
        m = match(r"is ([\d.]+ mm) away", i.text); m === nothing ? "none nearby" : m[1] * " away"
    elseif i.kind == :group
        m = match(r"Group (\S+): \w+ spread ([\d.]+ \w+)", i.text); m === nothing ? "" : "$(m[1]) spread $(m[2])"
        return clip("group " * (m === nothing ? i.text : "$(m[1]) · spread $(m[2])"), 56)
    else
        m = match(r"\(([^()]*)\)\s*$", i.text)
        m === nothing ? "" : replace(m[1], " in total" => "", "places" => "spots")
    end
    return clip(who * KIND_NAMES[i.kind] * (isempty(i.layer) ? "" : " · " * i.layer) * (isempty(detail) ? "" : " · " * detail), 56)
end

fz(z) = isnan(z) ? "—" : @sprintf("%.1f Ω", z)
tick(ok) = ok ? "✓" : "✗"

"Select a finding: highlight its marker, select its net, show the SI overlay."
function focus_issue!(st::UIState, res, k)
    iss = res.issues[k]
    st.si_issue[] = k
    is_si_mode(st.result_mode[]) || (st.result_mode[] = "SI vs target")
    isempty(iss.net) || (st.sel[] = (:net, iss.net))
    st.say("[si] " * uppercase(string(iss.severity)) * ": " * iss.text *
           (isnan(iss.x) ? "" : @sprintf("  @ (%.2f, %.2f)%s", iss.x, iss.y, isempty(iss.layer) ? "" : " " * iss.layer)))
end

"Signal integrity: configuration (targets, settings), run, results (findings, pairs, groups), overlay."
function si_panel!(p::DynPanel, st::UIState, h, r; run!::Function, maxrows::Int = 40)
    res = st.si_result[]
    r = title!(p, h, r, "Signal integrity", "Trace impedance and delay (2-D field solver), return paths, lengths and skew\nof every routed signal net. No setup needed beyond Power / Ground net classes.")
    ts = si_targets(st.setup)
    ng = length(si_groups(st.setup))
    sumtxt = "$(length(ts)) target$(length(ts) == 1 ? "" : "s"), $ng length group$(ng == 1 ? "" : "s")"
    r, open = config_header!(p, st, h, r, "si", res !== nothing, sumtxt)
    if open
        line!(p, h, r, "Reference planes are the pours of nets classed Power or Ground (Nets tab).\nRefill zones in KiCad (B) and save first."; color = DIM, fontsize = 11); r += 1
        r = targets_section!(p, st, h, r, ts)
        section!(p, h, r, "LENGTH-MATCH GROUPS"); r += 1
        gs = si_groups(st.setup)
        for g in gs
            line!(p, h, r, "$(g.name): $(join(g.patterns, " ")) within $(g.tol) $(g.by == :delay ? "ps" : "mm")"; fontsize = 12); r += 1
        end
        line!(p, h, r, "Console:  group add DDR_DQ 0.5 DQ* DQS*   ·   group rm <name>\n(tolerance in mm; add 'delay' to match in ps)"; color = DIM, fontsize = 11); r += 1
        section!(p, h, r, "SETTINGS"); r += 1
        r = settings_grid!(p, st, h, r, SI_SETTING_SPECS, st.setup.si, SISettings(), "[si]")
    end
    r = run_button!(p, h, r, "▶  Run SI analysis", SI_RUN_COLOR, run!)
    # ── overlay
    section!(p, h, r, "ON THE COPPER"); r += 1
    g = sub!(p, h[r, 1:2]); r += 1
    blk!(p, Label(g[1, 1], "Show"; halign = :left, width = 50))
    cur = is_si_mode(st.result_mode[]) ? st.result_mode[] : "Off"
    m = blk!(p, Menu(g[1, 2]; options = ["Off", SI_MODES...], default = cur, tellwidth = false, width = Relative(1)))
    on(m.selection) do s
        (s === nothing || s == cur) && return
        st.result_mode[] = s
        request!(st, :analysis)
    end
    if res !== nothing && res.ok && is_si_mode(cur)
        if cur == "SI impedance"
            lo, hi = si_overlay_range(res)
            blk!(p, Colorbar(h[r, 1:2]; limits = (lo, hi), colormap = OVERLAY_CMAP, vertical = false, flipaxis = false, height = 10,
                             label = "Impedance (Ω): Zdiff where a pair runs coupled, else Z0", labelsize = 12,
                             ticklabelsize = 11, tellwidth = false)); r += 1
            line!(p, h, r, "magenta: no reference plane"; color = SI_STATUS_COLORS[:noref], fontsize = 11); r += 1
        else
            keys_ = cur == "SI vs target" ?
                [(:ok, "within target"), (:off, "outside target"), (:none, "no target"), (:noref, "no reference")] :
                [(:microstrip, "microstrip"), (:stripline, "stripline"), (:embedded, "embedded"), (:none, "no reference")]
            cmap = cur == "SI vs target" ? SI_STATUS_COLORS : SI_KIND_COLORS
            g2 = sub!(p, h[r, 1:2]); r += 1
            for (i, (k, lab)) in enumerate(keys_)
                blk!(p, Label(g2[1, i], "━ " * lab; color = cmap[k], fontsize = 11, halign = :left))
            end
            colgap!(g2, 10)
        end
        line!(p, h, r, "◆ markers: findings (red error · amber warning · grey note)"; color = DIM, fontsize = 11); r += 1
    end


    section!(p, h, r, "RESULTS"); r += 1
    if res === nothing
        line!(p, h, r, "Not run yet."; color = DIM); r += 1
    elseif !res.ok
        for msg in first(res.messages, 5)
            line!(p, h, r, wrap("• " * msg, 58); color = BAD_C, fontsize = 11); r += 1
        end
    else
        st.si_rev != st.rev[] && (line!(p, h, r, "Setup changed since this run: run again to update."; color = SEVERITY_COLORS[:warning]); r += 1)
        line!(p, h, r, @sprintf("%d nets · %d pairs · %d cross-sections solved · %.1f s", length(res.nets), length(res.pairs),
                                res.nxs_solved, res.seconds); color = DIM, fontsize = 11); r += 1
        ne, nw, ni = (count(i -> i.severity == s, res.issues) for s in (:error, :warning, :info))
        g = sub!(p, h[r, 1:2]); r += 1
        for (i, (n, s, lab)) in enumerate(((ne, :error, "errors"), (nw, :warning, "warnings"), (ni, :info, "notes")))
            blk!(p, Label(g[1, i], "●  $n $lab"; color = SEVERITY_COLORS[s], halign = :left, fontsize = 13, font = :bold))
        end
        colgap!(g, 14)
        for m in first(res.messages, 2)
            line!(p, h, r, wrap("• " * m, 58); color = DIM, fontsize = 11); r += 1
        end
    end

    if res !== nothing && res.ok
        # ── findings
        show_all = get(st.setup.view, "si_show_notes", false) == true
        shown = [(k, i) for (k, i) in enumerate(res.issues) if show_all || i.severity != :info]
        section!(p, h, r, "FINDINGS ($(length(shown))$(show_all ? "" : " + $(count(i -> i.severity == :info, res.issues)) notes"))"); r += 1
        cb = CheckRow(sub!(p, h[r, 1:2]), 1, "Include notes (findings on nets without targets)"; checked = show_all, p = p); r += 1
        on(cb.checked) do v
            st.setup.view["si_show_notes"] = v
            notify(st.si_issue)                    # redraw the 3D markers
            request!(st, :analysis)
        end
        isempty(shown) && (line!(p, h, r, "None."; color = OK_C); r += 1)
        room = max(4, maxrows - r - 8)                      # rows left for findings + pairs
        nf = clamp(room * 3 ÷ 5, 2, 12)
        np_ = clamp(room - nf, 2, 8)
        for (k, iss) in first(shown, nf)
            txt = (k == st.si_issue[] ? "▸ " : "") * issue_label(iss)
            r = row_button!(p, h, r, txt, SEVERITY_COLORS[iss.severity], () -> (focus_issue!(st, res, k); request!(st, :analysis)))
        end
        length(shown) > nf && (line!(p, h, r, "… $(length(shown) - nf) more in the Signals table (bottom)"; color = DIM, fontsize = 11); r += 1)

        # ── pairs
        if !isempty(res.pairs)
            section!(p, h, r, "DIFFERENTIAL PAIRS ($(length(res.pairs)))"); r += 1
            for pr in first(sort(res.pairs; by = x -> (x.z_ok && x.skew_ok, x.name)), np_)
                ok = pr.z_ok && pr.skew_ok
                txt = @sprintf("%s  Zdiff %s%s  skew %.2f mm %s", clip(pair_label(pr), 18), fz(pr.zd_avg),
                               isnan(pr.target) ? "" : @sprintf(" %s", tick(pr.z_ok)), pr.skew, tick(pr.skew_ok))
                r = row_button!(p, h, r, txt, ok ? OK_C : BAD_C, () -> (st.sel[] = (:net, pr.p)))
            end
            length(res.pairs) > np_ && (line!(p, h, r, "… all pairs in the Signals table (bottom)"; color = DIM, fontsize = 11); r += 1)
        end

        # ── groups
        section!(p, h, r, "LENGTH-MATCH GROUPS"); r += 1
        if isempty(res.groups)
            line!(p, h, r, "None defined (see Configuration)."; color = DIM, fontsize = 11); r += 1
        end
        for gr in res.groups
            txt = @sprintf("%s   %d nets   spread %.3f %s (≤ %g) %s", gr.name, length(gr.members), gr.spread,
                           gr.by == :delay ? "ps" : "mm", gr.tol, tick(gr.ok))
            r = row_button!(p, h, r, txt, gr.ok ? OK_C : BAD_C, () -> nothing)
        end
    end

    return r
end

"Editable impedance target list."
function targets_section!(p, st, h, r, ts)
    section!(p, h, r, "IMPEDANCE TARGETS"); r += 1
    ts = si_targets(st.setup)
    for (i, t) in enumerate(ts)
        g = sub!(p, h[r, 1:2]); r += 1
        blk!(p, Label(g[1, 1], @sprintf("%-14s %s  %g Ω  ±%s%%", t.pattern, t.mode == :diff ? "diff" : "single", t.z,
                                        isnan(t.tol_pct) ? string(round(si_settings(st.setup).z_tol_pct, digits = 1)) : string(t.tol_pct));
                      halign = :left, fontsize = 12, tellwidth = false))
        x = blk!(p, Button(g[1, 2]; label = "✕", padding = (6, 6, 2, 2), fontsize = 11, width = 26))
        on(x.clicks) do _
            set_si_targets!(st.setup, [u for (j, u) in enumerate(ts) if j != i])
            changed!(st); request!(st, :analysis)
            st.say("[si] removed target $(t.pattern) (run again to apply)")
        end
    end
    isempty(ts) && (line!(p, h, r, "No targets: impedances are reported but not checked."; color = DIM, fontsize = 11); r += 1)
    g = sub!(p, h[r, 1:2]); r += 1
    pat = blk!(p, Textbox(g[1, 1]; placeholder = "net pattern, e.g. *CLK*", width = Relative(1), tellwidth = false, fontsize = 12))
    zt = blk!(p, Textbox(g[1, 2]; placeholder = "Ω", width = 48, fontsize = 12,
                         validator = s -> (x = parse_si(s); x !== nothing && x > 0)))
    md = blk!(p, Menu(g[1, 3]; options = ["single", "diff"], default = "single", width = 70, fontsize = 12))
    add = blk!(p, Button(g[1, 4]; label = "Add", padding = (8, 8, 3, 3), fontsize = 12))
    colsize!(g, 1, Relative(0.5)); colgap!(g, 4)
    on(add.clicks) do _
        ps = strip(something(pat.stored_string[], ""))
        z = parse_si(something(zt.stored_string[], ""))
        (isempty(ps) || z === nothing) && return st.say("[si] Enter a net pattern and an impedance, e.g. *CLK* 50.")
        mode = md.selection[] == "diff" ? :diff : :se
        set_si_targets!(st.setup, vcat(ts, [ZTarget(String(ps), z, NaN, mode)]))
        changed!(st); request!(st, :analysis)
        st.say("[si] target $ps $(mode == :diff ? "differential" : "single-ended") $(z) Ω (run again to apply)")
    end
    if haskey(st.setup.si, "targets")
        b = blk!(p, Button(h[r, 1:2]; label = "Reset to defaults (USB 90 Ω differential)", tellwidth = false, width = Relative(1),
                           fontsize = 11, padding = (4, 4, 3, 3))); r += 1
        on(b.clicks) do _
            delete!(st.setup.si, "targets"); changed!(st); request!(st, :analysis)
        end
    end

    return r
end

# ─────────────────────────────────────────────────────────────────────────────
# Bottom tables
# ─────────────────────────────────────────────────────────────────────────────
const TABLE_COLS = Dict(
    "Nets" => [("Net", 230, :left), ("Pair", 150, :left), ("Length mm", 80, :right), ("Delay ps", 72, :right),
               ("Vias", 42, :right), ("Z0 min", 64, :right), ("Z0 max", 64, :right), ("Target", 60, :right),
               ("Off-target mm", 100, :right), ("Layers", 220, :left)],
    "Pairs" => [("Pair", 260, :left), ("Zdiff", 70, :right), ("min", 64, :right), ("max", 64, :right), ("Target", 60, :right),
                ("Coupled", 66, :right), ("Skew mm", 70, :right), ("Skew ps", 64, :right), ("Length P", 74, :right),
                ("Length N", 74, :right), ("Status", 80, :left)],
    "Cross-sections" => [("Layer", 64, :left), ("Type", 140, :left), ("Width", 60, :right), ("Gap", 56, :right),
                         ("Coplanar", 70, :right), ("Z0", 60, :right), ("Zdiff", 64, :right), ("εeff", 52, :right),
                         ("ps/mm", 58, :right), ("Used mm", 72, :right), ("Reference planes", 330, :left)],
    "Findings" => [("", 22, :left), ("Kind", 86, :left), ("Net", 200, :left), ("Layer", 64, :left), ("Where", 120, :left),
                   ("Finding", 900, :left)])


f1(x) = isnan(x) ? "—" : @sprintf("%.1f", x)
f2(x) = isnan(x) ? "—" : @sprintf("%.2f", x)
f3(x) = isnan(x) ? "—" : @sprintf("%.3f", x)

function build_si_table!(p::DynPanel, st::UIState; run!::Function)
    h = p.host
    res = st.si_result[]
    if res === nothing || !res.ok
        msg = res === nothing ? "No SI analysis yet: impedance, return paths and lengths of every routed signal net." :
                                "The last SI analysis failed: " * join(res.messages, "  ")
        blk!(p, Label(h[1, 1], msg; halign = :left, color = :gray65, fontsize = 12, tellwidth = false))
        b = blk!(p, Button(h[2, 1]; label = "▶  Run SI analysis", buttoncolor = SI_RUN_COLOR, labelcolor = :white,
                           halign = :left, padding = (12, 12, 5, 5)))
        on(b.clicks) do _; run!(); end
        rowgap!(h, 6)
        return p
    end
    which = String(get(st.setup.view, "si_table", "Nets"))
    which in SI_TABLES || (which = "Nets")
    g = sub!(p, h[1, 1])
    blk!(p, Label(g[1, 1], "Show"; halign = :left, color = :gray65, fontsize = 12))
    m = blk!(p, Menu(g[1, 2]; options = SI_TABLES, default = which, width = 140, fontsize = 12))
    blk!(p, Label(g[1, 3], "click a header to sort · click a row to select it"; halign = :left, color = :gray50,
                  fontsize = 11, tellwidth = false))
    colgap!(g, 8)
    on(m.selection) do s
        (s === nothing || s == which) && return
        st.setup.view["si_table"] = s
        request!(st, :si_table)
    end
    tp = TablePanel(h[2, 1], TABLE_COLS[which])
    blk!(p, tp.ax)
    foreach(o -> obs!(p, o), tp.observers)
    rows, keys, ids, cols = Vector{String}[], Vector{Any}[], Any[], RGBf[]
    plain = RGBf(0.85, 0.87, 0.90)
    if which == "Nets"
        for n in res.nets
            push!(rows, [n.net, n.pair, f2(n.length), f1(n.delay * 1e12), string(n.nvias), f1(n.zmin), f1(n.zmax),
                         isnan(n.target) ? "" : @sprintf("%g", n.target), n.viol_len > 0 ? f1(n.viol_len) : "",
                         join(n.layers, " ")])
            push!(keys, Any[n.net, n.pair, n.length, n.delay, n.nvias, n.zmin, n.zmax, n.target, n.viol_len, join(n.layers, " ")])
            push!(ids, (:net, n.net)); push!(cols, n.viol_len > 0 ? BAD_C : plain)
        end
    elseif which == "Pairs"
        for pr in res.pairs
            ok = pr.z_ok && pr.skew_ok
            push!(rows, [pr.name, f1(pr.zd_avg), f1(pr.zd_min), f1(pr.zd_max), isnan(pr.target) ? "" : @sprintf("%g", pr.target),
                         @sprintf("%.0f%%", 100pr.coupled), f3(pr.skew), f1(pr.delay_skew * 1e12), f2(pr.len_p), f2(pr.len_n),
                         ok ? "ok" : (pr.z_ok ? "skew" : pr.skew_ok ? "impedance" : "both")])
            push!(keys, Any[pr.name, pr.zd_avg, pr.zd_min, pr.zd_max, pr.target, pr.coupled, pr.skew, pr.delay_skew,
                            pr.len_p, pr.len_n, ok ? 0 : 1])
            push!(ids, (:net, pr.p)); push!(cols, ok ? plain : BAD_C)
        end
    elseif which == "Cross-sections"
        for x in res.xsecs
            push!(rows, [x.layer, SI_KIND_LABEL[x.kind], f3(x.w), f3(x.gap), f2(x.cpw), f1(x.Z0), f1(x.Zdiff), f2(x.εeff),
                         f2(x.delay * 1e9), f1(x.len), x.ref])
            push!(keys, Any[x.layer, string(x.kind), x.w, x.gap, x.cpw, x.Z0, x.Zdiff, x.εeff, x.delay, x.len, x.ref])
            push!(ids, nothing); push!(cols, x.kind == :none ? SI_STATUS_COLORS[:noref] : plain)
        end
    else
        for (k, i) in enumerate(res.issues)
            sev = i.severity == :error ? 0 : i.severity == :warning ? 1 : 2
            push!(rows, ["●", get(KIND_NAMES, i.kind, string(i.kind)), i.net, i.layer,
                         isnan(i.x) ? "" : @sprintf("%.2f, %.2f", i.x, i.y), i.text])
            push!(keys, Any[sev, string(i.kind), i.net, i.layer, isnan(i.x) ? Inf : i.x, i.text])
            push!(ids, (:issue, k)); push!(cols, SEVERITY_COLORS[i.severity])
        end
    end
    set_rows!(tp, rows; keys = keys, ids = ids, colors = cols)
    obs!(p, on(tp.selected) do id
        id === nothing && return
        if id[1] == :issue
            focus_issue!(st, res, id[2])
            request!(st, :right)
        else
            st.sel[] = id
        end
    end)
    rowgap!(h, 4)
    return p
end

end # module
