module ImpedancePanel

# Bottom "Impedance" tab: |Z(f)| per port (log-log) with target lines, hover readout,
# and click-to-map: clicking a frequency shows |V| at that frequency on the copper in 3D.

using GLMakie
using Printf
using ..SimSetups
using ..WorkbenchState
using ..Widgets
using ..ACSolver

export build_impedance_panel!, PORT_COLORS, axis_x_at_mouse

const PORT_COLORS = [RGBf(0.35, 0.75, 1.0), RGBf(1.0, 0.6, 0.2), RGBf(0.45, 0.9, 0.45), RGBf(0.95, 0.45, 0.85),
                     RGBf(0.95, 0.9, 0.35), RGBf(0.6, 0.6, 1.0)]
portcolor(i) = PORT_COLORS[mod1(i, length(PORT_COLORS))]

"Frequency under the mouse on a log-x axis (computed from pixels and the axis limits)."
function axis_x_at_mouse(ax)
    px = mouseposition_px(ax.scene)
    w = widths(ax.scene.viewport[])[1]
    lim = ax.finallimits[]
    x0, x1 = lim.origin[1], lim.origin[1] + lim.widths[1]
    t = clamp(px[1] / max(w, 1), 0, 1)
    return 10^(log10(x0) + t * (log10(x1) - log10(x0)))
end

function build_impedance_panel!(p::DynPanel, st::UIState; run!::Function)
    h = p.host
    res = st.ac_result[]
    if res === nothing || !res.ok
        msg = res === nothing ? "No AC sweep yet. Each sink is a port: add sinks, a VRM and your decoupling capacitors, then run the sweep." :
                                "The last AC sweep failed: " * join(res.messages, "  ")
        blk!(p, Label(h[1, 1], msg; halign = :left, color = :gray65, fontsize = 12, tellwidth = false))
        b = blk!(p, Button(h[2, 1]; label = "▶  Run AC sweep", buttoncolor = RGBf(0.15, 0.35, 0.60), labelcolor = :white,
                           halign = :left, padding = (12, 12, 5, 5)))
        on(b.clicks) do _; run!(); end
        rowgap!(h, 6)
        return p
    end

    # header: hover readout + which port drives the 3D map
    g = sub!(p, h[1, 1])
    readout = blk!(p, Label(g[1, 1], "Hover the plot for values · click a frequency to map |V| on the copper (3D)";
                            halign = :left, color = :gray70, fontsize = 12, tellwidth = false))
    blk!(p, Label(g[1, 2], "3D map port"; halign = :right, color = :gray65, fontsize = 12))
    pm = blk!(p, Menu(g[1, 3]; options = [(x.id * "  " * x.ref * "  " * x.net_pos, i) for (i, x) in enumerate(res.ports)],
                      default = res.ports[clamp(st.ac_port[], 1, length(res.ports))].id * "  " *
                                res.ports[clamp(st.ac_port[], 1, length(res.ports))].ref * "  " *
                                res.ports[clamp(st.ac_port[], 1, length(res.ports))].net_pos,
                      width = 220, fontsize = 12))
    on(pm.selection) do i
        i === nothing || i == st.ac_port[] || (st.ac_port[] = i)
    end
    colgap!(g, 8)

    fs = res.freqs
    ax = blk!(p, Axis(h[2, 1]; xscale = log10, yscale = log10, xlabel = "Frequency (Hz)", ylabel = "|Z| (Ω)",
                      backgroundcolor = PANEL_BG, xgridcolor = RGBAf(1, 1, 1, 0.07), ygridcolor = RGBAf(1, 1, 1, 0.07),
                      xminorgridvisible = true, yminorgridvisible = true, xminorgridcolor = RGBAf(1, 1, 1, 0.03),
                      yminorgridcolor = RGBAf(1, 1, 1, 0.03), xlabelsize = 12, ylabelsize = 12,
                      xticklabelsize = 11, yticklabelsize = 11, tellheight = false))
    try deregister_interaction!(ax, :rectanglezoom) catch end        # left click picks a frequency instead
    for (i, port) in enumerate(res.ports)
        mag = max.(abs.(port.Z), 1e-12)
        lines!(ax, fs, mag; color = portcolor(i), linewidth = 2, label = "$(port.id) $(port.ref) $(port.net_pos)")
        isnan(port.target) || hlines!(ax, [port.target]; color = portcolor(i), linestyle = :dash, linewidth = 1.2,
                                      label = "target " * format_si(port.target, "Ω"))
    end
    blk!(p, axislegend(ax; position = :lt, framevisible = false, labelsize = 11, backgroundcolor = RGBAf(0, 0, 0, 0),
               labelcolor = :gray85, patchsize = (18, 8), rowgap = 0))     # tracked so a rebuild removes it

    # selected frequency marker
    fsel = Observable([st.ac_freq[] > 0 ? st.ac_freq[] : fs[1]])
    fvis = Observable(st.ac_freq[] > 0)
    obs!(p, on(st.ac_freq) do f
        f > 0 && (fsel[] = [f])
        fvis[] = f > 0
    end)
    vlines!(ax, fsel; color = RGBAf(1, 1, 1, 0.6), linewidth = 1.5, visible = fvis)

    nearest(f) = argmin(abs.(log10.(fs) .- log10(f)))
    function describe(f)
        i = nearest(f)
        parts = [@sprintf("f = %s", format_si(fs[i], "Hz"))]
        for port in res.ports
            z = port.Z[i]
            ok = isnan(port.target) ? "" : abs(z) <= port.target ? " ✓" : " ✗"
            push!(parts, @sprintf("%s |Z| %s ∠%.0f°%s", port.id, format_si(abs(z), "Ω"), rad2deg(angle(z)), ok))
        end
        return join(parts, "   ")
    end
    obs!(p, on(events(ax.scene).mouseposition) do _
        is_mouseinside(ax.scene) && (readout.text[] = describe(axis_x_at_mouse(ax)))
        return Consume(false)
    end)
    obs!(p, on(events(ax.scene).mousebutton; priority = 5) do ev
        if ev.button == Mouse.left && ev.action == Mouse.press && is_mouseinside(ax.scene) &&
           !ispressed(ax.scene, Keyboard.left_control)
            f = fs[nearest(axis_x_at_mouse(ax))]
            st.ac_freq[] = f
            st.result_mode[] = AC_MODE
            request!(st, :results)
            st.say("[ac] 3D map: |V| at " * format_si(f, "Hz") * " for 1 A into " * res.ports[clamp(st.ac_port[], 1, length(res.ports))].id)
        end
        return Consume(false)
    end)
    rowgap!(h, 4)
    return p
end

end # module
