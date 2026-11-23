module Report

# A self-contained HTML report of the DC, AC and SI results (no GUI dependency): summary,
# stackup, results tables, 3D snapshots (PNG files passed in, embedded as base64) and
# |Z(f)| curves drawn as inline SVG. Print-friendly: the browser's "Save as PDF" works.

using Printf
using Dates
using ..BoardParser: BoardData
using ..Geometry: copper_layers
using ..SimSetups
using ..DCSolver
using ..ACSolver
using ..SISolver

export write_report, report_path

report_path(board_file) = splitext(board_file)[1] * ".perplex-report.html"

# ─────────────────────────────────────────────────────────────────────────────
# Small helpers
# ─────────────────────────────────────────────────────────────────────────────
const B64 = collect("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/")
"Base64 (RFC 4648) of a byte vector."
function base64(bytes::AbstractVector{UInt8})
    io = IOBuffer()
    n = length(bytes)
    for i in 1:3:n
        b1 = bytes[i]; b2 = i + 1 <= n ? bytes[i+1] : 0x00; b3 = i + 2 <= n ? bytes[i+2] : 0x00
        v = (UInt32(b1) << 16) | (UInt32(b2) << 8) | UInt32(b3)
        write(io, B64[(v >> 18) & 0x3f + 1], B64[(v >> 12) & 0x3f + 1])
        write(io, i + 1 <= n ? B64[(v >> 6) & 0x3f + 1] : '=')
        write(io, i + 2 <= n ? B64[v & 0x3f + 1] : '=')
    end
    return String(take!(io))
end

hesc(s) = replace(string(s), "&" => "&amp;", "<" => "&lt;", ">" => "&gt;", "\"" => "&quot;")
num(x, fmt = "%.2f") = (x isa Real && isnan(x)) ? "—" : Printf.format(Printf.Format(fmt), x)
chip(ok::Bool, yes = "pass", no = "check") = "<span class=\"chip $(ok ? "ok" : "bad")\">$(ok ? yes : no)</span>"
sevchip(s::Symbol) = "<span class=\"chip $(s == :error ? "bad" : s == :warning ? "warn" : "info")\">$(s == :info ? "note" : string(s))</span>"

function table(io, head::Vector{String}, rows; right = Int[], cls = "")
    print(io, "<table class=\"$cls\"><thead><tr>")
    for (i, h) in enumerate(head)
        print(io, "<th", i in right ? " class=\"r\"" : "", ">", hesc(h), "</th>")
    end
    print(io, "</tr></thead><tbody>")
    for row in rows
        print(io, "<tr>")
        for (i, c) in enumerate(row)
            print(io, "<td", i in right ? " class=\"r\"" : "", ">", c, "</td>")    # cells are pre-escaped HTML
        end
        print(io, "</tr>")
    end
    println(io, "</tbody></table>")
end

const PORT_COLORS = ["#4fb0ff", "#ff9a33", "#62d36a", "#f06fd8", "#f2e05a", "#9a9aff"]

"|Z(f)| per port on log-log axes, with dashed target lines, as inline SVG."
function z_svg(acr)
    W, H, ml, mr, mt, mb = 760, 300, 64, 16, 12, 40
    fs = acr.freqs
    zs = [max.(abs.(p.Z), 1e-6) for p in acr.ports]
    targets = [p.target for p in acr.ports if !isnan(p.target)]
    zall = vcat(zs..., targets)
    lzlo, lzhi = floor(log10(minimum(zall))), ceil(log10(maximum(zall)))
    lzhi == lzlo && (lzhi += 1)
    lflo, lfhi = log10(fs[1]), log10(fs[end])
    X(f) = ml + (log10(f) - lflo) / (lfhi - lflo) * (W - ml - mr)
    Y(z) = mt + (lzhi - log10(z)) / (lzhi - lzlo) * (H - mt - mb)
    io = IOBuffer()
    print(io, "<svg viewBox=\"0 0 $W $H\" class=\"plot\" role=\"img\" aria-label=\"PDN impedance versus frequency\">")
    for e in ceil(Int, lflo):floor(Int, lfhi)
        x = X(10.0^e)
        print(io, "<line x1=\"$x\" y1=\"$mt\" x2=\"$x\" y2=\"$(H - mb)\" class=\"grid\"/>",
              "<text x=\"$x\" y=\"$(H - mb + 16)\" text-anchor=\"middle\">$(hesc(format_si(10.0^e, "Hz")))</text>")
    end
    for e in Int(lzlo):Int(lzhi)
        y = Y(10.0^e)
        print(io, "<line x1=\"$ml\" y1=\"$y\" x2=\"$(W - mr)\" y2=\"$y\" class=\"grid\"/>",
              "<text x=\"$(ml - 6)\" y=\"$(y + 4)\" text-anchor=\"end\">$(hesc(format_si(10.0^e, "Ω")))</text>")
    end
    for (i, p) in enumerate(acr.ports)
        c = PORT_COLORS[mod1(i, length(PORT_COLORS))]
        pts = join((@sprintf("%.1f,%.1f", X(f), Y(z)) for (f, z) in zip(fs, zs[i])), " ")
        print(io, "<polyline points=\"$pts\" fill=\"none\" stroke=\"$c\" stroke-width=\"2\"/>")
        if !isnan(p.target)
            y = Y(p.target)
            print(io, "<line x1=\"$ml\" y1=\"$y\" x2=\"$(W - mr)\" y2=\"$y\" stroke=\"$c\" stroke-dasharray=\"6 4\"/>")
        end
        print(io, "<text x=\"$(ml + 8)\" y=\"$(mt + 14 + 15 * (i - 1))\" fill=\"$c\" text-anchor=\"start\">",
              hesc("$(p.id) $(p.ref) $(p.net_pos)"), "</text>")
    end
    print(io, "<text x=\"$((W + ml) / 2)\" y=\"$(H - 4)\" text-anchor=\"middle\" class=\"axis\">Frequency</text>",
          "<text x=\"14\" y=\"$((H - mb) / 2)\" text-anchor=\"middle\" class=\"axis\" transform=\"rotate(-90 14 $((H - mb) / 2))\">|Z|</text>")
    print(io, "</svg>")
    return String(take!(io))
end

const CSS = """
:root { --bg:#f6f7f9; --card:#fff; --ink:#1d2330; --dim:#5d6676; --line:#e2e5ea; --accent:#3a6fd8;
        --ok:#1f8a4c; --okbg:#e2f5ea; --bad:#c23b32; --badbg:#fbe6e4; --warn:#9a6a00; --warnbg:#fdf1d6;
        --info:#4d5a70; --infobg:#e9edf3; }
@media (prefers-color-scheme: dark) { :root:not([data-theme="light"]) {
        --bg:#14161b; --card:#1d2027; --ink:#e7eaf0; --dim:#9aa3b2; --line:#2d313b; --accent:#7aa2ff;
        --ok:#6fd79a; --okbg:#173326; --bad:#ff8a80; --badbg:#3a1d1b; --warn:#f3c461; --warnbg:#3a2e12;
        --info:#b3bdcc; --infobg:#262b35; } }
* { box-sizing: border-box; }
body { margin:0; background:var(--bg); color:var(--ink); font:14px/1.5 system-ui,-apple-system,"Segoe UI",Roboto,sans-serif; }
main { max-width:1100px; margin:0 auto; padding:24px 16px 64px; }
header { display:flex; align-items:center; gap:16px; margin-bottom:8px; }
header img { width:48px; height:48px; }
h1 { font-size:24px; margin:0; } h2 { font-size:18px; margin:32px 0 8px; border-bottom:1px solid var(--line); padding-bottom:6px; }
h3 { font-size:15px; margin:20px 0 6px; }
.meta { color:var(--dim); font-size:13px; }
.cards { display:grid; grid-template-columns:repeat(auto-fit,minmax(220px,1fr)); gap:12px; margin:16px 0; }
.card { background:var(--card); border:1px solid var(--line); border-radius:10px; padding:14px 16px; }
.card .k { color:var(--dim); font-size:12px; text-transform:uppercase; letter-spacing:.04em; }
.card .v { font-size:22px; font-weight:600; margin:2px 0; }
.chip { display:inline-block; padding:1px 8px; border-radius:999px; font-size:12px; font-weight:600; }
.chip.ok { color:var(--ok); background:var(--okbg); } .chip.bad { color:var(--bad); background:var(--badbg); }
.chip.warn { color:var(--warn); background:var(--warnbg); } .chip.info { color:var(--info); background:var(--infobg); }
.scroll { overflow-x:auto; }
table { border-collapse:collapse; width:100%; background:var(--card); border:1px solid var(--line); border-radius:8px;
        font-size:13px; margin:6px 0 12px; }
th, td { padding:5px 8px; border-bottom:1px solid var(--line); text-align:left; vertical-align:top; }
th { color:var(--dim); font-weight:600; background:var(--bg); } td.r, th.r { text-align:right; font-variant-numeric:tabular-nums; }
tr:last-child td { border-bottom:none; }
figure { margin:10px 0 18px; } figure img { width:100%; border-radius:8px; border:1px solid var(--line); background:#000; }
figcaption { color:var(--dim); font-size:12px; margin-top:4px; }
.grid2 { display:grid; grid-template-columns:repeat(auto-fit,minmax(320px,1fr)); gap:12px; }
svg.plot { width:100%; height:auto; background:var(--card); border:1px solid var(--line); border-radius:8px; }
svg.plot text { font-size:11px; fill:var(--dim); } svg.plot .grid { stroke:var(--line); } svg.plot .axis { font-size:12px; }
.note { color:var(--dim); font-size:12px; }
ul.msgs { margin:4px 0 12px; padding-left:20px; color:var(--dim); font-size:13px; }
footer { margin-top:40px; color:var(--dim); font-size:12px; border-top:1px solid var(--line); padding-top:10px; }
@media print { body { background:#fff; color:#000; } main { max-width:none; padding:0; } .card, table, svg.plot { break-inside:avoid; }
               h2 { break-after:avoid; } figure { break-inside:avoid; } }
"""

# ─────────────────────────────────────────────────────────────────────────────
# Report
# ─────────────────────────────────────────────────────────────────────────────
"""
    write_report(path; board, setup, dc, ac, si, images, version, logo) -> path

`dc`, `ac`, `si` are results or `nothing`; `images` is a vector of
`(section::Symbol, caption, png_path)`; `logo` an optional PNG path.
"""
function write_report(path::AbstractString; board::BoardData, setup::SimSetup, dc = nothing, ac = nothing, si = nothing,
                      images = Tuple{Symbol,String,String}[], version::AbstractString = "", logo::AbstractString = "")
    io = IOBuffer()
    name = basename(setup.board_file)
    img(p) = isfile(p) ? "data:image/png;base64," * base64(read(p)) : ""
    figs(sec) = [(c, img(p)) for (s, c, p) in images if s == sec && isfile(p)]
    dcok = dc !== nothing && dc.ok
    acok = ac !== nothing && ac.ok
    siok = si !== nothing && si.ok

    println(io, "<!doctype html><html lang=\"en\"><head><meta charset=\"utf-8\">",
            "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">",
            "<title>$(hesc(name)) · PerplexForge report</title><style>", CSS, "</style></head><body><main>")
    print(io, "<header>", isfile(logo) ? "<img src=\"$(img(logo))\" alt=\"\">" : "",
          "<div><h1>$(hesc(name))</h1><div class=\"meta\">Power &amp; signal integrity report · PerplexForge $(hesc(version)) · ",
          hesc(Dates.format(now(), "yyyy-mm-dd HH:MM")), "</div></div></header>")
    @printf(io, "<p class=\"meta\">Board %.1f × %.1f mm · %d copper layers · %d nets · %d components · %d trace segments · %d vias</p>",
            board.width, board.height, length(copper_layers(board)),
            length(board.nets), length(board.components), length(board.traces), length(board.vias))

    # ── summary cards
    print(io, "<div class=\"cards\">")
    if dcok
        w = isempty(dc.sinks) ? nothing : dc.sinks[argmax([s.pct for s in dc.sinks])]
        print(io, "<div class=\"card\"><div class=\"k\">DC · IR drop</div><div class=\"v\">",
              w === nothing ? "no sinks" : @sprintf("%.2f %%", w.pct), "</div><div class=\"meta\">",
              w === nothing ? "" : hesc("worst sink $(w.id) $(w.ref) on $(w.net_pos), −$(num(w.drop_mV)) mV"), " ",
              w === nothing ? "" : chip(w.pct < 3), "</div></div>")
    end
    if acok
        bad = count(p -> !isempty(target_violations(ac.freqs, p.Z, p.target)), ac.ports)
        print(io, "<div class=\"card\"><div class=\"k\">AC · PDN impedance</div><div class=\"v\">$(length(ac.ports) - bad) / $(length(ac.ports))</div>",
              "<div class=\"meta\">ports within target ", chip(bad == 0), "</div></div>")
    end
    if siok
        ne = count(i -> i.severity == :error, si.issues); nw = count(i -> i.severity == :warning, si.issues)
        nbad = count(p -> !(p.z_ok && p.skew_ok), si.pairs)
        print(io, "<div class=\"card\"><div class=\"k\">SI · findings</div><div class=\"v\">$ne errors · $nw warnings</div>",
              "<div class=\"meta\">$(count(i -> i.severity == :info, si.issues)) notes on nets without targets ", chip(ne == 0), "</div></div>")
        isempty(si.pairs) || print(io, "<div class=\"card\"><div class=\"k\">SI · differential pairs</div><div class=\"v\">",
                                   "$(length(si.pairs) - nbad) / $(length(si.pairs))</div><div class=\"meta\">pairs within impedance and skew ",
                                   chip(nbad == 0), "</div></div>")
    end
    (dcok || acok || siok) || print(io, "<div class=\"card\"><div class=\"k\">No results</div><div class=\"meta\">Run an analysis first.</div></div>")
    println(io, "</div>")

    # ── stackup
    stk = si_stack(board)
    println(io, "<h2>Stackup</h2>")
    stk.defined || println(io, "<p class=\"note\">", hesc(first(stk.notes)), "</p>")
    rows = [[hesc(it.name), string(it.kind), num(it.t * 1000, "%.1f"), it.kind == :copper ? "" : num(it.εr, "%.2f"),
             it.kind == :copper || it.tanδ == 0 ? "" : num(it.tanδ, "%.3f")] for it in stk.items]
    print(io, "<div class=\"scroll\">"); table(io, ["Layer", "Type", "Thickness µm", "εr", "tan δ"], rows; right = [3, 4, 5]); print(io, "</div>")

    # ── DC
    if dcok
        println(io, "<h2>DC analysis: IR drop</h2>")
        @printf(io, "<p class=\"note\">%d nodes · cell %.3f mm · copper loss %s · %.2f s</p>", dc.nnodes, dc.grid.h,
                hesc(format_si(dc.ploss, "W")), dc.seconds)
        table(io, ["Sink", "Part", "Rail", "Voltage at pins", "Drop", "Drop %", ""],
              [[hesc(s.id), hesc(s.ref), hesc(s.net_pos), num(s.v, "%.5f V"), num(s.drop_mV, "%.2f mV"), num(s.pct, "%.2f %%"),
                chip(s.pct < 3)] for s in sort(dc.sinks; by = s -> -s.pct)]; right = [4, 5, 6])
        table(io, ["VRM", "Part", "Rail", "Current", "Voltage at pads"],
              [[hesc(t.id), hesc(t.ref), hesc(t.net_pos), hesc(format_si(t.I, "A")), num(t.vout, "%.5f V")] for t in dc.vrms]; right = [4, 5])
        rl = [r for r in dc.rails if !isnan(r.maxdrop_mV)]
        isempty(rl) || table(io, ["Net", "Nominal", "Min", "Max", "Max drop / rise"],
                             [[hesc(r.net), num(r.nominal, "%.3f V"), num(r.vmin, "%.5f V"), num(r.vmax, "%.5f V"),
                               num(r.maxdrop_mV, "%.2f mV")] for r in rl]; right = [2, 3, 4, 5])
        fs = figs(:dc)
        isempty(fs) || (print(io, "<div class=\"grid2\">");
                        foreach(f -> print(io, "<figure><img src=\"$(f[2])\" alt=\"$(hesc(f[1]))\"><figcaption>$(hesc(f[1]))</figcaption></figure>"), fs);
                        print(io, "</div>"))
    end

    # ── AC
    if acok
        println(io, "<h2>AC analysis: PDN impedance</h2>")
        @printf(io, "<p class=\"note\">%d frequencies · %d nodes · plane capacitance %s · %.1f s. Each sink is a port; the dashed line is its target impedance (ripple × V / step current).</p>",
                length(ac.freqs), ac.nnodes, hesc(format_si(ac.cplane, "F")), ac.seconds)
        println(io, z_svg(ac))
        rows = Vector{String}[]
        for p in ac.ports
            mag = abs.(p.Z); ip = argmax(mag)
            bands = target_violations(ac.freqs, p.Z, p.target)
            push!(rows, [hesc(p.id), hesc(p.ref), hesc(p.net_pos), hesc(format_si(mag[ip], "Ω")), hesc(format_si(ac.freqs[ip], "Hz")),
                         isnan(p.target) ? "—" : hesc(format_si(p.target, "Ω")),
                         isnan(p.target) ? "" : isempty(bands) ? chip(true) :
                         chip(false, "", "above target " * hesc(join(["$(format_si(a, "Hz"))–$(format_si(b, "Hz"))" for (a, b) in first(bands, 2)], ", ")))])
        end
        table(io, ["Port", "Part", "Rail", "Peak |Z|", "at", "Target", ""], rows; right = [4, 5, 6])
    end

    # ── SI
    if siok
        println(io, "<h2>Signal integrity</h2>")
        @printf(io, "<p class=\"note\">%d signal nets · %d differential pairs · %d trace cross-sections solved with a 2-D field solver · %.1f s</p>",
                length(si.nets), length(si.pairs), si.nxs_solved, si.seconds)
        isempty(si.messages) || (print(io, "<ul class=\"msgs\">"); foreach(m -> print(io, "<li>", hesc(m), "</li>"), si.messages); print(io, "</ul>"))
        fs = figs(:si)
        isempty(fs) || (print(io, "<div class=\"grid2\">");
                        foreach(f -> print(io, "<figure><img src=\"$(f[2])\" alt=\"$(hesc(f[1]))\"><figcaption>$(hesc(f[1]))</figcaption></figure>"), fs);
                        print(io, "</div>"))
        imp = [i for i in si.issues if i.severity != :info]
        println(io, "<h3>Findings ($(length(imp)))</h3>")
        if isempty(imp)
            println(io, "<p>No errors or warnings on controlled nets. ", chip(true), "</p>")
        else
            print(io, "<div class=\"scroll\">")
            table(io, ["", "Net", "Layer", "Location (mm)", "Finding"],
                  [[sevchip(i.severity), hesc(i.net), hesc(i.layer), isnan(i.x) ? "" : @sprintf("%.2f,&nbsp;%.2f", i.x, i.y), hesc(i.text)] for i in imp])
            print(io, "</div>")
        end
        ni = count(i -> i.severity == :info, si.issues)
        ni > 0 && println(io, "<p class=\"note\">$ni further notes concern nets without an impedance target, pair or length group (listed in the workbench).</p>")
        if !isempty(si.pairs)
            println(io, "<h3>Differential pairs</h3><div class=\"scroll\">")
            table(io, ["Pair", "Zdiff avg", "min", "max", "Target", "Coupled", "Skew", "Skew ps", ""],
                  [[hesc(p.name), num(p.zd_avg, "%.1f Ω"), num(p.zd_min, "%.1f"), num(p.zd_max, "%.1f"),
                    isnan(p.target) ? "—" : @sprintf("%g Ω ±%g%%", p.target, p.tol), @sprintf("%.0f %%", 100p.coupled),
                    num(p.skew, "%.3f mm"), num(p.delay_skew * 1e12, "%.1f"), chip(p.z_ok && p.skew_ok)] for p in si.pairs];
                  right = [2, 3, 4, 6, 7, 8])
            print(io, "</div>")
        end
        if !isempty(si.groups)
            println(io, "<h3>Length-match groups</h3>")
            table(io, ["Group", "Nets", "Spread", "Limit", ""],
                  [[hesc(g.name), string(length(g.members)), num(g.spread, g.by == :delay ? "%.1f ps" : "%.3f mm"),
                    g.by == :delay ? "$(g.tol) ps" : "$(g.tol) mm", chip(g.ok)] for g in si.groups]; right = [2, 3, 4])
        end
        println(io, "<h3>Impedance table</h3><p class=\"note\">Every distinct trace cross-section on the board, by length of trace that uses it.</p><div class=\"scroll\">")
        table(io, ["Layer", "Type", "Width", "Gap", "Coplanar gap", "Z0", "Zdiff", "εeff", "ps/mm", "Used", "Reference planes"],
              [[hesc(x.layer), hesc(SI_KIND_LABEL[x.kind]), num(x.w, "%.3f"), num(x.gap, "%.3f"), num(x.cpw, "%.2f"),
                num(x.Z0, "%.1f Ω"), num(x.Zdiff, "%.1f Ω"), num(x.εeff, "%.2f"), num(x.delay * 1e9, "%.2f"),
                num(x.len, "%.1f mm"), hesc(x.ref)] for x in first(si.xsecs, 40)]; right = [3, 4, 5, 6, 7, 8, 9, 10])
        print(io, "</div>")
        tn = [n for n in si.nets if !isnan(n.target) || !isempty(n.pair)]
        if !isempty(tn)
            println(io, "<h3>Controlled nets</h3><div class=\"scroll\">")
            table(io, ["Net", "Pair", "Length", "Delay", "Vias", "Z0 range", "Target", "Off target"],
                  [[hesc(n.net), hesc(n.pair), num(n.length, "%.2f mm"), num(n.delay * 1e12, "%.1f ps"), string(n.nvias),
                    "$(num(n.zmin, "%.1f"))–$(num(n.zmax, "%.1f")) Ω", isnan(n.target) ? "—" : @sprintf("%g Ω", n.target),
                    n.viol_len > 0 ? num(n.viol_len, "%.1f mm") : ""] for n in tn]; right = [3, 4, 5, 6, 7, 8])
            print(io, "</div>")
        end
    end

    println(io, "<footer>Generated by PerplexForge $(hesc(version)) from the last saved copy of $(hesc(name)). ",
            "DC: resistive mesh of the board copper. AC: RLC mesh with plane-pair capacitance. ",
            "SI: quasi-static 2-D field solutions of each trace cross-section from the board stackup; ",
            "values are estimates and do not replace a fabricator's impedance calculation for controlled-impedance orders.</footer>")
    println(io, "</main></body></html>")
    tmp = path * ".tmp"
    write(tmp, take!(io))
    mv(tmp, path; force = true)
    return path
end

end # module
