module AnalysisPanel

# Right-dock "Analysis" tab, laid out as a tool: pick the simulation source (power or
# signal integrity), then the analysis (DC IR drop / AC PDN impedance for power), and the
# panel shows that analysis's configuration, its own Run button, its results and what it
# draws on the copper.

using GLMakie
using ..WorkbenchState
using ..Widgets
using ..ResultsPanel: dc_panel!, ac_panel!
using ..SIPanel: si_panel!

export build_analysis_panel!, current_analysis

"""
    current_analysis(st) -> (source, analysis)

`(:pi, :dc)`, `(:pi, :ac)` or `(:si, :si)`, as stored in the view settings.
"""
function current_analysis(st::UIState)
    get(st.setup.view, "source", "pi") == "si" && return (:si, :si)
    return (:pi, get(st.setup.view, "pi_analysis", "dc") == "ac" ? :ac : :dc)
end

"A row of mutually exclusive buttons; `pick(key)` is called for an inactive one."
function segmented!(p, gl, items, active, pick; fontsize = 13, pad = 6)
    for (i, (key, label)) in enumerate(items)
        b = blk!(p, Button(gl[1, i]; label = label, tellwidth = false, width = Relative(1), padding = (pad, pad, pad, pad),
                           fontsize = fontsize, buttoncolor = key == active ? BTN_ACTIVE : BTN_BG, labelcolor = :white))
        on(b.clicks) do _
            key == active || pick(key)
        end
    end
    colgap!(gl, 4)
    return gl
end

"""
    build_analysis_panel!(p, st; run_dc!, run_ac!, run_si!, select!)

`select!(source, analysis)` switches the shown analysis (and the overlay / bottom tab with it).
"""
function build_analysis_panel!(p::DynPanel, st::UIState; run_dc!::Function, run_ac!::Function, run_si!::Function,
                               select!::Function, maxrows::Int = 40)
    h = p.host
    r = 1
    src, an = current_analysis(st)
    blk!(p, Label(h[r, 1:2], "SIMULATION SOURCE"; font = :bold, halign = :left, color = :gray65, fontsize = 12,
                  tellwidth = false)); r += 1
    segmented!(p, sub!(p, h[r, 1:2]), [(:pi, "Power integrity"), (:si, "Signal integrity")], src,
               k -> select!(k, k == :si ? :si : nothing); fontsize = 14, pad = 7); r += 1
    if src == :pi
        segmented!(p, sub!(p, h[r, 1:2]), [(:dc, "DC · IR drop"), (:ac, "AC · PDN impedance")], an,
                   k -> select!(:pi, k); fontsize = 12, pad = 4); r += 1
    end
    blk!(p, Box(h[r, 1:2]; height = 1, color = RGBf(0.22, 0.23, 0.28), strokevisible = false, tellwidth = false)); r += 1
    if an == :dc
        dc_panel!(p, st, h, r; run! = run_dc!, maxrows)
    elseif an == :ac
        ac_panel!(p, st, h, r; run! = run_ac!, maxrows)
    else
        si_panel!(p, st, h, r; run! = run_si!, maxrows)
    end
    rowgap!(h, 5)
    return p
end

end # module
