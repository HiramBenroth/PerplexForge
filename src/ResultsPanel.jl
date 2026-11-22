module ResultsPanel

# Right-dock "Results" tab: what is drawn on the copper (overlay + colour bar), DC results,
# AC (PDN impedance) results, and the DC / AC settings.

using GLMakie
using Printf
using ..SimSetups
using ..WorkbenchState
using ..Widgets
using ..DCSolver
using ..ACSolver

export build_results_panel!, OVERLAY_MODES

const OVERLAY_MODES = ["Off", "Voltage", "IR drop", "Current density", AC_MODE]
const DIM = RGBf(0.55, 0.55, 0.60)
const OK_C, WARN_C, BAD_C = RGBf(0.45, 0.85, 0.5), RGBf(0.95, 0.80, 0.30), RGBf(0.95, 0.40, 0.35)

section!(p, h, r, text) = blk!(p, Label(h[r, 1:2], text; font = :bold, halign = :left, color = :gray65,
                                        fontsize = 12, tellwidth = false))
line!(p, h, r, text; color = RGBf(0.85, 0.85, 0.9), fontsize = 12) =
    blk!(p, Label(h[r, 1:2], text; halign = :left, justification = :left, color = color, fontsize = fontsize, tellwidth = false))

function row_button!(p, st, h, r, text, color, id)
    b = blk!(p, Button(h[r, 1:2]; label = text, tellwidth = false, width = Relative(1), padding = (6, 6, 3, 3),
                       fontsize = 12, buttoncolor = RGBf(0.15, 0.15, 0.19), labelcolor = color))
    id === nothing || on(b.clicks) do _
        st.sel[] = (:elem, id)
    end
    return r + 1
end

run_button!(p, h, r, label, color, f) = begin
    b = blk!(p, Button(h[r, 1:2]; label = label, tellwidth = false, width = Relative(1), buttoncolor = color,
                       labelcolor = :white, padding = (8, 8, 6, 6)))
    on(b.clicks) do _; f(); end
    r + 1
end

severity(pct) = pct < 1 ? OK_C : pct < 3 ? WARN_C : BAD_C

"Greedy word wrap (labels don't wrap reliably inside the dock)."
function wrap(s::AbstractString, n::Int = 60)
    lines = String[]
    cur = ""
    for w in split(s, ' ')
        if !isempty(cur) && length(cur) + 1 + length(w) > n
            push!(lines, cur)
            cur = "   " * w
        else
            cur = isempty(cur) ? String(w) : cur * " " * w
        end
    end
    isempty(cur) || push!(lines, cur)
    return join(lines, "\n")
end

"Editable numeric settings stored in `dict` (values accept SI suffixes)."
function settings_grid!(p, st, h, r, specs, dict, defaults, tag)
    g = sub!(p, h[r, 1:2])
    for (i, (key, label, unit, hint)) in enumerate(specs)
        cur = Float64(get(dict, key, getfield(defaults, Symbol(key))))
        blk!(p, Label(g[i, 1], label; halign = :left, width = 95, fontsize = 12))
        tb = blk!(p, Textbox(g[i, 2]; stored_string = replace(format_si(cur, ""), " " => ""), width = 70, fontsize = 12,
                             validator = s -> (x = parse_si(s); x !== nothing && x >= 0)))
        blk!(p, Label(g[i, 3], unit * (isempty(hint) ? "" : "   " * hint); halign = :left, color = DIM, fontsize = 11,
                      tellwidth = false))
        on(tb.stored_string) do s
            x = parse_si(something(s, ""))
            (x === nothing || x == cur) && return
            dict[key] = x
            changed!(st)
            st.say("$tag $label = $(format_si(x, unit)) (run again to apply)")
            request!(st, :results)
        end
    end
    colgap!(g, 6); rowgap!(g, 3)
    return r + 1
end

function build_results_panel!(p::DynPanel, st::UIState; run!::Function, run_ac!::Function = () -> nothing)
    h = p.host
    r = 1
    res = st.result[]
    acr = st.ac_result[]
    mode = st.result_mode[]

    # ── what is drawn on the copper ──────────────────────────────────────────
    section!(p, h, r, "ON THE COPPER"); r += 1
    g = sub!(p, h[r, 1:2]); r += 1
    blk!(p, Label(g[1, 1], "Show"; halign = :left, width = 50))
    m = blk!(p, Menu(g[1, 2]; options = OVERLAY_MODES, default = mode, tellwidth = false, width = Relative(1)))
    on(m.selection) do s
        s === nothing || s == st.result_mode[] || (st.result_mode[] = s; request!(st, :results))
    end
    on_now = [n for n in st.layer_names if st.layer_on[n][]]
    blk!(p, Label(g[2, 1], "Layer"; halign = :left, width = 50))
    lm = blk!(p, Menu(g[2, 2]; options = vcat(["All layers"], st.layer_names),
                      default = length(on_now) == 1 ? on_now[1] : "All layers", tellwidth = false, width = Relative(1)))
    on(lm.selection) do s
        s === nothing && return
        for n in st.layer_names
            st.layer_on[n][] = s == "All layers" || n == s
        end
    end
    dc_ok = res !== nothing && res.ok
    if mode == "Voltage" && dc_ok
        rail = shown_rail(st, res)
        blk!(p, Label(g[3, 1], "Rail"; halign = :left, width = 50))
        rm = blk!(p, Menu(g[3, 2]; options = voltage_rails(res), default = rail, tellwidth = false, width = Relative(1)))
        on(rm.selection) do s
            s === nothing || s == st.result_net[] || (st.result_net[] = s; request!(st, :results))
        end
    end
    rowgap!(g, 4)

    cb = nothing                                            # (limits, label, tickformat)
    if mode in ("Voltage", "IR drop", "Current density") && dc_ok
        rail = shown_rail(st, res)
        lo, hi = overlay_range(res, mode; net = rail)
        cb = if mode == "Voltage"
            i = findfirst(x -> x.net == rail, res.rails)
            nom = i === nothing ? NaN : res.rails[i].nominal
            ((lo, hi), "$rail voltage (V)" * (isnan(nom) ? "" : @sprintf("  ·  nominal %.3f V", nom)),
             vs -> [@sprintf("%.4f", v) for v in vs])
        elseif mode == "IR drop"
            ((lo, hi), "IR drop (mV)  ·  |nominal − V|", Makie.automatic)
        else
            ((lo, hi), "Current density (A/mm²)", Makie.automatic)
        end
    elseif mode == AC_MODE && acr !== nothing && acr.ok && st.ac_freq[] > 0
        port = acr.ports[clamp(st.ac_port[], 1, length(acr.ports))]
        _, (lo, hi) = ac_map(acr, clamp(st.ac_port[], 1, length(acr.ports)), st.ac_freq[])
        cb = ((lo, hi), "|V| per A into $(port.id) at $(format_si(st.ac_freq[], "Hz")) (Ω)",
              vs -> [format_si(v, "") for v in vs])
    elseif mode != "Off"
        line!(p, h, r, mode == AC_MODE ? "Run the AC sweep, then click a frequency on the Impedance plot." :
                                         "Run the DC analysis to see this."; color = DIM, fontsize = 11); r += 1
    end
    if cb !== nothing
        (lims, label, fmt) = cb
        blk!(p, Colorbar(h[r, 1:2]; limits = lims, colormap = :turbo, vertical = false, flipaxis = false,
                         height = 10, label = label, tickformat = fmt, labelsize = 12, ticklabelsize = 11,
                         tellwidth = false)); r += 1
    end

    # ── DC ───────────────────────────────────────────────────────────────────
    section!(p, h, r, "DC ANALYSIS"); r += 1
    r = run_button!(p, h, r, "▶  Run DC analysis", RGBf(0.13, 0.50, 0.27), run!)
    if res === nothing
        line!(p, h, r, "Not run yet. Add a VRM and sinks (Inspector), then Run."; color = DIM); r += 1
    elseif !res.ok
        line!(p, h, r, "The last run failed:"; color = BAD_C); r += 1
        for msg in first(res.messages, 6)
            line!(p, h, r, wrap("• " * msg); color = BAD_C, fontsize = 11); r += 1
        end
    else
        st.result_rev != st.rev[] && (line!(p, h, r, "Setup changed since this run: run again to update."; color = WARN_C); r += 1)
        line!(p, h, r, @sprintf("%d nodes · cell %.3f mm · %.2f s · copper loss %s", res.nnodes, res.grid.h, res.seconds,
                                format_si(res.ploss, "W")); color = DIM, fontsize = 11); r += 1
        for s in first(sort(res.sinks; by = s -> -s.pct), 8)
            r = row_button!(p, st, h, r, @sprintf("%s  %s  %s   %.5f V   −%.2f mV (%.2f%%)", s.id, s.ref, s.net_pos,
                                                  s.v, s.drop_mV, s.pct), severity(s.pct), s.id)
        end
        for t in res.vrms
            r = row_button!(p, st, h, r, @sprintf("%s  %s  %s   %s   %.5f V at pads", t.id, t.ref, t.net_pos,
                                                  format_si(t.I, "A"), t.vout), KIND_COLORS[:vrm], t.id)
        end
        for s in first(sort(res.series; by = s -> -abs(s.I)), 6)
            r = row_button!(p, st, h, r, @sprintf("%s  %s → %s   %s   %s across", s.id, s.net_pos, s.net_neg,
                                                  format_si(abs(s.I), "A"), format_si(abs(s.vdrop), "V")),
                            KIND_COLORS[s.kind], s.id)
        end
        for rl in res.rails
            isnan(rl.maxdrop_mV) && continue
            line!(p, h, r, @sprintf("%-10s %s %.2f mV   (%.5f … %.5f V)", rl.net, rl.nominal == 0 ? "max rise" : "max drop",
                                    rl.maxdrop_mV, rl.vmin, rl.vmax); fontsize = 11); r += 1
        end
        if !isempty(res.vias)
            v = sort(res.vias; by = v -> -abs(v.I))[1]
            line!(p, h, r, @sprintf("Highest barrel current %s (%s at %.1f, %.1f, %s)", format_si(abs(v.I), "A"), v.label,
                                    v.x, v.y, v.net); fontsize = 11); r += 1
        end
        if !isempty(res.traces)
            t = res.traces[argmax([t.J for t in res.traces])]
            line!(p, h, r, @sprintf("Max trace current density %.1f A/mm² (%s, %s)", t.J, t.net, res.layers[t.layer]);
                  fontsize = 11); r += 1
        end
        for msg in first(res.messages, 3)
            line!(p, h, r, wrap("• " * msg); color = DIM, fontsize = 11); r += 1
        end
    end

    # ── AC ───────────────────────────────────────────────────────────────────
    section!(p, h, r, "AC ANALYSIS (PDN IMPEDANCE)"); r += 1
    r = run_button!(p, h, r, "▶  Run AC sweep", RGBf(0.15, 0.35, 0.60), run_ac!)
    if acr === nothing
        line!(p, h, r, "Not run yet. Every sink is a port; add your decoupling\ncapacitors as elements, then Run."; color = DIM); r += 1
    elseif !acr.ok
        for msg in first(acr.messages, 4)
            line!(p, h, r, wrap("• " * msg); color = BAD_C, fontsize = 11); r += 1
        end
    else
        st.ac_rev != st.rev[] && (line!(p, h, r, "Setup changed since this sweep: run again to update."; color = WARN_C); r += 1)
        line!(p, h, r, @sprintf("%d points · %d nodes · %.1f s · plane C %s", length(acr.freqs), acr.nnodes, acr.seconds,
                                format_si(acr.cplane, "F")); color = DIM, fontsize = 11); r += 1
        for port in acr.ports
            mag = abs.(port.Z)
            ip = argmax(mag)
            bands = target_violations(acr.freqs, port.Z, port.target)
            c = isnan(port.target) ? RGBf(0.85, 0.85, 0.9) : isempty(bands) ? OK_C : BAD_C
            txt = @sprintf("%s  %s  peak %s at %s", port.id, port.net_pos, format_si(mag[ip], "Ω"), format_si(acr.freqs[ip], "Hz")) *
                  (isnan(port.target) ? "" : "  ·  target " * format_si(port.target, "Ω") * (isempty(bands) ? " ✓" : " ✗"))
            r = row_button!(p, st, h, r, txt, c, port.id)
            for b in first(bands, 2)
                line!(p, h, r, "     above target " * format_si(b[1], "Hz") * " – " * format_si(b[2], "Hz"); color = BAD_C,
                      fontsize = 11); r += 1
            end
        end
        for msg in first(acr.messages, 3)
            line!(p, h, r, wrap("• " * msg); color = DIM, fontsize = 11); r += 1
        end
    end

    # ── settings ─────────────────────────────────────────────────────────────
    section!(p, h, r, "DC SETTINGS"); r += 1
    r = settings_grid!(p, st, h, r, DC_SETTING_SPECS, st.setup.dc, DCSettings(), "[dc]")
    section!(p, h, r, "AC SETTINGS"); r += 1
    r = settings_grid!(p, st, h, r, AC_SETTING_SPECS, st.setup.ac, ACSettings(), "[ac]")
    rowgap!(h, 4)
    return p
end

end # module
