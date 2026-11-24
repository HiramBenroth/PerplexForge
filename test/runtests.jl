# Unit tests (no GLMakie needed).
#   julia --project=. test/runtests.jl
#
# The synthetic-board tests always run. Tests on a real board run when
# PERPLEXFORGE_TEST_BOARD points at a .kicad_pcb (see test/board_tests.jl).

using Test

module PFCore                      # load just the GUI-free parts of PerplexForge
include(joinpath(@__DIR__, "..", "src", "BoardParser.jl"))
include(joinpath(@__DIR__, "..", "src", "SimSetup.jl"))
include(joinpath(@__DIR__, "..", "src", "Geometry.jl"))
include(joinpath(@__DIR__, "..", "src", "Mesh.jl"))
include(joinpath(@__DIR__, "..", "src", "DCSolver.jl"))
include(joinpath(@__DIR__, "..", "src", "ACSolver.jl"))
include(joinpath(@__DIR__, "..", "src", "XSection.jl"))
include(joinpath(@__DIR__, "..", "src", "SISolver.jl"))
include(joinpath(@__DIR__, "..", "src", "Report.jl"))
end
using .PFCore.BoardParser
using .PFCore.SimSetups
using .PFCore.DCSolver
using .PFCore.ACSolver
using .PFCore.XSection
using .PFCore.SISolver
using .PFCore.Report

@testset "parse_si / format_si" begin
    @test parse_si("10k") ≈ 1e4
    @test parse_si("4u7") ≈ 4.7e-6
    @test parse_si("1k5") ≈ 1500
    @test parse_si("4R7") ≈ 4.7
    @test parse_si("3V3") ≈ 3.3
    @test parse_si("100nF") ≈ 1e-7
    @test parse_si("100n") ≈ 1e-7
    @test parse_si("10 mA") ≈ 0.01
    @test parse_si("2.2µ") ≈ 2.2e-6
    @test parse_si("1e-3") ≈ 1e-3
    @test parse_si("270") ≈ 270
    @test parse_si("10M") ≈ 1e7
    @test parse_si("12p") ≈ 12e-12
    @test parse_si("STM32F405RGT6") === nothing
    @test parse_si("600 @ 600MHz") === nothing
    @test parse_si("") === nothing
    @test format_si(4.7e-6, "F") == "4.7 µF"
    @test format_si(0.15, "A") == "150 mA"
    @test format_si(3.3, "V") == "3.3 V"
    @test format_si(1500, "Ω") == "1.5 kΩ"
    @test format_si(0, "A") == "0 A"
    @test format_si(999.99, "Ω") == "1 kΩ"
end

@testset "guess_netclass" begin
    @test guess_netclass("GND") == :ground
    @test guess_netclass("AGND") == :ground
    @test guess_netclass("VSS") == :ground
    @test guess_netclass("+3V3") == :power
    @test guess_netclass("+3.3VA") == :power
    @test guess_netclass("+12V") == :power
    @test guess_netclass("VDD") == :power
    @test guess_netclass("VBUS") == :power
    @test guess_netclass("5V") == :power
    @test guess_netclass("SWDIO") == :unspecified
    @test guess_netclass("Net-(C13-Pad1)") == :unspecified
    @test guess_netclass("HSE_IN") == :unspecified
    @test guess_netclass("USB_D+") == :unspecified
    @test guess_netclass("/Microprocessor/VDDA") == :power         # hierarchical sheet names
    @test guess_netclass("/USB_5V") == :power
    @test guess_netclass("/Power/GND") == :ground
    @test guess_netclass("/SEL_52a1") == :unspecified
end

@testset "s-expression scanner" begin
    # quoted strings may contain parentheses; escaped quotes must not end a string
    src = """(kicad_pcb (version 1) (footprint "Lib:A(1)" (property "Value" "x)y\\"z") (pad "1" smd rect (at 1 2) (size 1 1) (layers "F.Cu") (net 1 "GND")))
 (zone (net 1) (net_name "GND") (layer "F.Cu") (filled_polygon (layer "F.Cu") (pts (xy 0 0) (xy 1 0) (xy 1 1))))
 (segment (start 0 0) (end 1 0) (width 0.2) (layer "F.Cu") (net 1)))"""
    items = BoardParser.child_items(src)
    @test [i[1] for i in items] == ["version", "footprint", "zone", "segment"]
    @test length(BoardParser.top_blocks(src, "zone")) == 1
    fp = only(BoardParser.top_blocks(src, "footprint"))
    @test length(BoardParser.child_blocks(fp, "pad")) == 1
    # a very large zone fill (this used to exceed PCRE's match limit)
    big = "(kicad_pcb (zone (net 1) (layer \"F.Cu\") (filled_polygon (layer \"F.Cu\") (pts " *
          join(("(xy $(i % 97) $(i % 89))" for i in 1:400_000), " ") * "))) (segment (start 0 0) (end 1 1)))"
    @test length(BoardParser.top_blocks(big, "zone")) == 1
    @test length(BoardParser.top_blocks(big, "segment")) == 1
end

# ─────────────────────────────────────────────────────────────────────────────
# Synthetic boards
# ─────────────────────────────────────────────────────────────────────────────
const BP = PFCore.BoardParser
rectpts(x0, y0, x1, y1) = [BP.Point(x0, y0), BP.Point(x1, y0), BP.Point(x1, y1), BP.Point(x0, y1)]
pad(num, lx, ly, sx, sy, net; layer = "F.Cu") = BP.Pad(num, "smd", "rect", BP.Point(lx, ly), 0.0, sx, sy, 0.0, [layer], net)
part(ref, x, y, pads; value = "") = BP.Component(ref, "test", value, BP.Point(x, y), 0.0, "F.Cu", pads)
zone(layer, net, pts) = BP.Zone(layer, net, pts, [pts])
function testboard(; comps, zones = BP.Zone[], traces = BP.Trace[], vias = BP.Via[])
    outline = [vcat(rectpts(0, 0, 30, 11), [BP.Point(0, 0)])]
    BP.BoardData(30.0, 11.0, Set(["+3V3", "GND"]), comps, traces, vias, zones, outline, BP.StackupLayer[])
end
function testsetup(b; sink_I = 1.0)
    s = new_setup("synthetic.kicad_pcb", b)
    push!(s.elements, SimSetups.Element("VRM1", :vrm, "U1", "+3V3", "GND", Dict("V" => 3.3, "Rout" => 1e-6, "Lout" => 1e-9)))
    push!(s.elements, SimSetups.Element("SNK1", :sink, "U2", "+3V3", "GND", Dict("I" => sink_I)))
    s.dc["cell_mm"] = 0.1
    s.dc["temperature_c"] = 20.0
    return s
end
strip_parts() = [part("U1", 2, 5.5, [pad("1", 0, -2.5, 1, 4, "+3V3"), pad("2", 0, 2.5, 1, 4, "GND")]),
                 part("U2", 28, 5.5, [pad("1", 0, -2.5, 1, 4, "+3V3"), pad("2", 0, 2.5, 1, 4, "GND")])]
strip_zones() = [zone("F.Cu", "+3V3", rectpts(1, 1, 29, 5)), zone("F.Cu", "GND", rectpts(1, 6, 29, 10))]
const RS = 1.72e-8 / 35e-6          # Ω/□ for 35 µm copper at 20 °C

@testset "setup model and JSON round trip" begin
    comps = vcat(strip_parts(), [part("C1", 15, 5.5, [pad("1", 0, -2.5, 1, 1, "+3V3"), pad("2", 0, 2.5, 1, 1, "GND")];
                                      value = "4u7")])
    b = testboard(comps = comps, zones = strip_zones())
    dir = mktempdir()
    fake_board = joinpath(dir, "test.kicad_pcb")
    s = new_setup(fake_board, b)
    @test s.dirty && netclass(s, "GND") == :ground && netclass(s, "+3V3") == :power
    c1 = comps[3]
    @test guess_kind(c1, s) == :capacitor
    ce = default_element(:capacitor, c1, s)
    @test ce.params["C"] ≈ 4.7e-6 && ce.net_pos == "+3V3" && ce.net_neg == "GND"
    sink = default_element(:sink, comps[2], s)
    @test sink.id == "SNK1" && sink.net_pos == "+3V3" && sink.net_neg == "GND"

    errs, _, _ = validate_dc(s, b)
    @test any(occursin("No VRM", e) for e in errs)
    push!(s.elements, sink, default_element(:vrm, comps[1], s), ce)
    errs, _, summary = validate_dc(s, b)
    @test isempty(errs) && length(summary) == 1

    s.view["zscale"] = 2.5
    s.dc["cell_mm"] = 0.2
    s.ac["f_stop"] = 2e9
    path = save_setup(s)
    @test path == joinpath(dir, "test.perplex.json") && !s.dirty
    s2, status = load_setup(fake_board, b)
    @test status == :loaded && !s2.dirty
    @test s2.netclass == s.netclass
    @test [e.id for e in s2.elements] == [e.id for e in s.elements]
    @test s2.elements[1].params == s.elements[1].params
    @test s2.view["zscale"] == 2.5 && s2.dc["cell_mm"] == 0.2 && s2.ac["f_stop"] == 2e9
    @test load_setup(joinpath(dir, "other.kicad_pcb"), b)[2] == :new
end

@testset "DC: uniform plane strips" begin
    # +3V3 and GND strips 4 mm wide; VRM pads at x≈2, sink pads at x≈28 span the full strip width
    b = testboard(comps = strip_parts(), zones = strip_zones())
    r = solve_dc(b, testsetup(b))
    @test r.ok
    # current flows over 25 mm (pad edge to pad edge); uniform injection over the 1 mm sink pad adds a/3
    Rstrip = RS * (25 + 1 / 3) / 4
    @test isapprox(r.sinks[1].drop_mV, 2 * Rstrip * 1e3; rtol = 0.02)
    @test isapprox(r.vrms[1].I, 1.0; rtol = 1e-6)
    @test isapprox(r.ploss, 2 * Rstrip; rtol = 0.03)
    lo, hi = overlay_range(r, "IR drop")
    @test hi > 0
    p = dc_probe(r, "F.Cu", 15.0, 3.0)
    @test p !== nothing && p.net == "+3V3" && 3.29 < p.V < 3.3
end

@testset "DC: trace resistance" begin
    # +3V3 through a 26 mm × 0.5 mm trace (pad centre to pad centre); GND as a plane strip
    comps = [part("U1", 2, 5.5, [pad("1", 0, -2.5, 1, 1, "+3V3"), pad("2", 0, 2.5, 1, 4, "GND")]),
             part("U2", 28, 5.5, [pad("1", 0, -2.5, 1, 1, "+3V3"), pad("2", 0, 2.5, 1, 4, "GND")])]
    tr = [BP.Trace(BP.Point(2, 3), BP.Point(28, 3), 0.5, "F.Cu", "+3V3")]
    b = testboard(comps = comps, traces = tr, zones = [zone("F.Cu", "GND", rectpts(1, 6, 29, 10))])
    r = solve_dc(b, testsetup(b))
    @test r.ok
    Rtrace = 1.72e-8 * 26e-3 / (0.5e-3 * 35e-6)
    @test isapprox(3.3 - r.sinks[1].vpos, Rtrace; rtol = 0.02)
    @test all(t -> isapprox(abs(t.I), 1.0; rtol = 1e-6), r.traces)
    @test isapprox(maximum(t.J for t in r.traces), 1.0 / (0.5 * 0.035); rtol = 1e-6)    # A/mm²
end

@testset "DC: via barrel" begin
    # +3V3 runs on F.Cu to a via at x = 14, then on B.Cu to the sink pad (on B.Cu)
    comps = [part("U1", 2, 5.5, [pad("1", 0, -2.5, 1, 4, "+3V3"), pad("2", 0, 2.5, 1, 4, "GND")]),
             part("U2", 28, 5.5, [pad("1", 0, -2.5, 1, 4, "+3V3"; layer = "B.Cu"), pad("2", 0, 2.5, 1, 4, "GND")])]
    zs = [zone("F.Cu", "+3V3", rectpts(1, 1, 15, 5)), zone("B.Cu", "+3V3", rectpts(13, 1, 29, 5)),
          zone("F.Cu", "GND", rectpts(1, 6, 29, 10))]
    vias = [BP.Via(BP.Point(14, 3), 0.6, 0.3, ["F.Cu", "B.Cu"], "+3V3")]
    b = testboard(comps = comps, zones = zs, vias = vias)
    r = solve_dc(b, testsetup(b))
    @test r.ok
    @test length(r.vias) == 1
    @test isapprox(abs(r.vias[1].I), 1.0; rtol = 1e-6)
    # barrel: 1.6 mm (nominal 2-layer spacing), 25 µm plating in a 0.3 mm hole
    Rvia = 1.72e-8 * 1.6e-3 / (π * (0.15^2 - 0.125^2) * 1e-6)
    @test r.sinks[1].drop_mV > Rvia * 1e3                      # via + planes
    @test r.sinks[1].drop_mV < (Rvia + 2 * RS * 26 / 4 + 0.002) * 1e3
end

@testset "DC: LED string with a resistor and a transistor switch (no sinks)" begin
    # +3V3 ─ R1 (100 Ω) ─ N1 ─ D1 (LED, Vf 2 V) ─ N2 ─ Q1 (on: D–S) ─ GND, all on F.Cu traces
    T(x0, y0, x1, y1, net) = BP.Trace(BP.Point(x0, y0), BP.Point(x1, y1), 0.5, "F.Cu", net)
    comps = [part("U1", 2, 5, [pad("1", 0, -2, 1, 1, "+3V3"), pad("2", 0, 2, 1, 1, "GND")]),
             part("R1", 10, 3, [pad("1", -1, 0, 1, 1, "+3V3"), pad("2", 1, 0, 1, 1, "N1")]; value = "100"),
             part("D1", 16, 3, [pad("1", 1, 0, 1, 1, "N2"), pad("2", -1, 0, 1, 1, "N1")]; value = "LED_Red"),
             part("Q1", 22, 5, [pad("1", -1, 0, 1, 1, "Net-(Q1-G)"), pad("2", 0, 2, 1, 1, "GND"), pad("3", 0, -2, 1, 1, "N2")])]
    traces = [T(2, 3, 9, 3, "+3V3"), T(11, 3, 15, 3, "N1"), T(17, 3, 22, 3, "N2"), T(2, 7, 22, 7, "GND")]
    nets = Set(["+3V3", "GND", "N1", "N2", "Net-(Q1-G)"])
    b = BP.BoardData(30.0, 11.0, nets, comps, traces, BP.Via[], BP.Zone[], [vcat(rectpts(0, 0, 30, 11), [BP.Point(0, 0)])],
                     BP.StackupLayer[])
    s = new_setup("led.kicad_pcb", b)
    byref = Dict(c.ref => c for c in comps)
    @test guess_kind(byref["D1"], s) == :diode && guess_kind(byref["Q1"], s) == :short
    d = default_element(:diode, byref["D1"], s)
    @test d.net_pos == "N1" && d.net_neg == "N2"                 # anode = pin 2, cathode = pin 1
    @test d.params["Vf"] == 2.0                                   # an LED
    q = default_element(:short, byref["Q1"], s)
    @test Set([q.net_pos, q.net_neg]) == Set(["N2", "GND"]) && q.net_neg == "GND"     # drain–source, not the gate

    vrm = SimSetups.Element("VRM1", :vrm, "U1", "+3V3", "GND", Dict("V" => 3.3, "Rout" => 1e-6, "Lout" => 1e-9))
    r1 = default_element(:resistor, byref["R1"], s)
    push!(s.elements, vrm, r1)
    # only the resistor: the diagnosis names the dead end and the part to model there
    _, warns, _ = validate_dc(s, b)
    @test any(w -> occursin("net N1 is only connected to R1", w) && occursin("D1", w), warns)
    d.params["Rs"] = 1e-6
    push!(s.elements, d, q)
    _, warns, _ = validate_dc(s, b)
    @test !any(w -> occursin("No current path", w) || occursin("Nothing draws", w), warns)
    r = solve_dc(b, s)
    @test r.ok
    I = (3.3 - 2.0) / 100
    @test isapprox(r.vrms[1].I, I; rtol = 2e-3)                   # traces add a few mΩ
    sd = only(x for x in r.series if x.kind == :diode)
    @test isapprox(sd.I, I; rtol = 2e-3) && isapprox(sd.vdrop, 2.0; atol = 1e-3)
    @test all(t -> isapprox(abs(t.I), I; rtol = 2e-3), r.traces)
    # traces in copper islands left out of the solve carry NaN current; they must not break the
    # current-density scale (they made it NaN and the whole overlay black)
    lo0, hi0 = overlay_range(r, "Current density")
    push!(r.traces, merge(r.traces[1], (I = NaN, J = NaN)))
    lo, hi = overlay_range(r, "Current density")
    @test isfinite(lo) && isfinite(hi) && hi > lo > 0 && (lo, hi) == (lo0, hi0)
    pop!(r.traces)
    # the LED fitted backwards conducts nothing, and the solver says why
    d.net_pos, d.net_neg = "N2", "N1"
    r2 = solve_dc(b, s)
    @test r2.ok && abs(r2.vrms[1].I) < 1e-6
    @test any(m -> occursin("reverse-biased", m), r2.messages)
end

@testset "mesh: vias sharing a coarse cell still reach their planes" begin
    # A decoupling cap with a via in each pad; on a 3 mm grid both vias fall in one cell.
    # In1 is a +3V3 plane with a clearance hole around them, B.Cu a GND plane. The GND via
    # claims the empty In1 cell first; the +3V3 via must still reach the +3V3 plane next to it.
    M = PFCore.PDNMesh
    viapad(ref, x, y, a, b) = part(ref, x, y, [pad("1", -0.5, 0, 0.8, 0.9, a), pad("2", 0.5, 0, 0.8, 0.9, b)])
    comps = [part("U1", 3, 5, [pad("1", 0, -1, 1, 1, "+3V3"), pad("2", 0, 1.5, 1, 1, "GND")]),
             part("U2", 27, 5, [pad("1", 0, -1, 1, 1, "+3V3"), pad("2", 0, 1.5, 1, 1, "GND")]),
             viapad("C1", 15, 5, "+3V3", "GND")]
    v(x, y, net) = BP.Via(BP.Point(x, y), 0.6, 0.3, ["F.Cu", "B.Cu"], net)
    vias = [v(15.5, 5, "GND"), v(14.5, 5, "+3V3"), v(3, 4, "+3V3"), v(3, 6.5, "GND"), v(27, 4, "+3V3"), v(27, 6.5, "GND")]
    plane3v3 = [rectpts(0, 0, 30, 3), rectpts(0, 5, 30, 11), rectpts(0, 3, 15, 5), rectpts(17, 3, 30, 5)]
    zs = [BP.Zone("In1.Cu", "+3V3", rectpts(0, 0, 30, 11), plane3v3), zone("B.Cu", "GND", rectpts(0, 0, 30, 11))]
    b = testboard(comps = comps, zones = zs, vias = vias)
    s = testsetup(b)
    push!(s.elements, default_element(:capacitor, comps[3], s))
    m = M.build_mesh(b, s; h = 3.0, ρ = 1.72e-8, include_caps = true)
    parent = collect(1:m.nn)
    root(x) = (while parent[x] != x; parent[x] = parent[parent[x]]; x = parent[x]; end; x)
    for k in eachindex(m.EA)
        m.EK[k] in (M.BR_PLANE, M.BR_TRACE, M.BR_BARREL, M.BR_TIE) || continue
        ra, rb = root(m.EA[k]), root(m.EB[k]); ra != rb && (parent[ra] = rb)
    end
    sizes = Dict{Int,Int}()
    foreach(k -> (r = root(k); sizes[r] = get(sizes, r, 0) + 1), 1:m.ngrid)
    main(net) = root(argmax(r -> m.nets[m.node_net[r]] == net ? sizes[r] : -1, collect(keys(sizes))))
    t = only(m.cap_t)
    @test root(t.ta) == main(t.e.net_pos)
    @test root(t.tb) == main(t.e.net_neg)
end

@testset "mesh: thin pin rotated 45° with an off-centre trace" begin
    # Like a QFP at 45°: a 0.3 × 1.6 mm pin on a 0.4 mm grid rasterizes into a diagonal
    # staircase, and its trace starts near the pin's end. The sink must still be fed.
    rot45 = BP.Pad("1", "smd", "oval", BP.Point(0, 0), 45.0, 0.3, 1.6, 0.0, ["F.Cu"], "+3V3")
    comps = [part("U1", 2, 5.5, [pad("1", 0, -2.5, 1, 4, "+3V3"), pad("2", 0, 2.5, 1, 4, "GND")]),
             part("U2", 25, 3, [rot45, pad("2", 0, 5.5, 1, 4, "GND")])]
    tr = [BP.Trace(BP.Point(25.424, 3.424), BP.Point(19.5, 3), 0.25, "F.Cu", "+3V3")]
    zs = [zone("F.Cu", "+3V3", rectpts(1, 1, 20, 5)), zone("F.Cu", "GND", rectpts(1, 6, 29, 10))]
    b = testboard(comps = comps, zones = zs, traces = tr)
    s = testsetup(b)
    s.dc["cell_mm"] = 0.4
    r = solve_dc(b, s)
    @test r.ok
    @test length(r.sinks) == 1
    @test !any(occursin("isn't connected", m) || occursin("ignored", m) for m in r.messages)
    @test 3.2 < r.sinks[1].v < 3.3
end

@testset "AC: low frequency matches DC" begin
    b = testboard(comps = strip_parts(), zones = strip_zones())
    s = testsetup(b)
    s.ac["cell_mm"] = 0.1
    s.ac["f_start"] = 100.0
    s.ac["f_stop"] = 1e4
    s.ac["points_per_decade"] = 2
    rd = solve_dc(b, s)
    ra = solve_ac(b, s)
    @test ra.ok
    Rdc = rd.sinks[1].drop_mV * 1e-3 / 1.0                       # V per A
    @test isapprox(abs(ra.ports[1].Z[1]), Rdc; rtol = 0.01)
    @test abs(angle(ra.ports[1].Z[1])) < 0.01                     # resistive at 100 Hz
end

@testset "AC: plane-pair cavity resonance" begin
    # 100 × 60 mm +3V3 / GND plane pair, 1.6 mm FR-4 (εr 4.5): first mode f10 = c / (2a√εr)
    corner(ref, x, y) = part(ref, x, y, [pad("1", 0, 0, 1, 1, "+3V3"), pad("2", 0, 0, 1, 1, "GND"; layer = "B.Cu")])
    outline = [vcat(rectpts(0, 0, 100, 60), [BP.Point(0, 0)])]
    zs = [zone("F.Cu", "+3V3", rectpts(0, 0, 100, 60)), zone("B.Cu", "GND", rectpts(0, 0, 100, 60))]
    b = BP.BoardData(100.0, 60.0, Set(["+3V3", "GND"]), [corner("U1", 1, 1), corner("U2", 99, 59)],
                     BP.Trace[], BP.Via[], zs, outline, BP.StackupLayer[])
    s = new_setup("cavity.kicad_pcb", b)
    push!(s.elements, SimSetups.Element("VRM1", :vrm, "U1", "+3V3", "GND", Dict("V" => 3.3, "Rout" => 100.0, "Lout" => 0.0)))
    push!(s.elements, SimSetups.Element("SNK1", :sink, "U2", "+3V3", "GND", Dict("I" => 0.1, "Istep" => 0.05, "Ripple" => 3.0)))
    s.ac["cell_mm"] = 2.0
    s.ac["f_start"] = 5e8
    s.ac["f_stop"] = 9e8
    s.ac["points_per_decade"] = 400
    r = solve_ac(b, s)
    @test r.ok
    f10 = 299792458 / (2 * 0.100 * sqrt(4.5))
    fpk = r.freqs[argmax(abs.(r.ports[1].Z))]
    @test isapprox(fpk, f10; rtol = 0.02)
    @test isapprox(r.cplane, 8.8541878128e-12 * 4.5 * 0.1 * 0.06 / 1.6e-3; rtol = 0.02)
    println("    cavity: f10 analytic $(round(f10 / 1e6, digits = 1)) MHz, peak at $(round(fpk / 1e6, digits = 1)) MHz")
end

# ─────────────────────────────────────────────────────────────────────────────
# Signal integrity
# ─────────────────────────────────────────────────────────────────────────────
@testset "XSection: field solver vs exact solutions" begin
    b, εr = 0.4, 4.2
    for w in (0.1, 0.2, 0.4)                          # zero-thickness centred stripline (Cohn, exact)
        xs = CrossSection(slabs = [Slab(0, b, εr)], conductors = [Conductor(-w / 2, w / 2, b / 2, b / 2)],
                          plane_bottom = 0.0, plane_top = b)
        p = line_params(solve_extrapolated(xs))
        @test isapprox(p.Z0, cohn_stripline_z0(w, b, εr); rtol = 0.005)
        @test isapprox(p.εeff, εr; rtol = 1e-6)
        @test isapprox(p.delay, sqrt(εr) / C0_LIGHT; rtol = 1e-6)
    end
    for (w, s) in ((0.1, 0.1), (0.15, 0.2))            # edge-coupled stripline (Cohn, exact)
        xs = CrossSection(slabs = [Slab(0, b, εr)], plane_bottom = 0.0, plane_top = b,
                          conductors = [Conductor(-s / 2 - w, -s / 2, b / 2, b / 2), Conductor(s / 2, s / 2 + w, b / 2, b / 2)])
        q = pair_params(solve_extrapolated(xs))
        ze, zo = cohn_coupled_stripline(w, s, b, εr)
        @test isapprox(q.Zodd, zo; rtol = 0.006) && isapprox(q.Zeven, ze; rtol = 0.006)
        @test q.Zdiff ≈ 2q.Zodd
    end
    for (w, h, e) in ((0.3, 0.2, 4.3), (0.15, 0.1, 4.0))   # microstrip (Hammerstad–Jensen, ±0.2 %)
        xs = CrossSection(slabs = [Slab(0, h, e)], conductors = [Conductor(-w / 2, w / 2, h, h)], plane_bottom = 0.0)
        p = line_params(solve_extrapolated(xs))
        z, ee = hammerstad_microstrip(w, h, e)
        @test isapprox(p.Z0, z; rtol = 0.006) && isapprox(p.εeff, ee; rtol = 0.01)
    end
    # grounded coplanar waveguide, tight gap (conformal mapping is accurate there)
    w, s, h, e = 0.3, 0.15, 0.2, 4.3
    K(k) = XSection.ellipK(k); kp(x) = sqrt(1 - x^2)
    k = w / (w + 2s); k3 = tanh(π * w / (4h)) / tanh(π * (w + 2s) / (4h))
    qq = K(kp(k)) * K(k3) / (K(k) * K(kp(k3)))
    zc = 60π / sqrt((1 + e * qq) / (1 + qq)) / (K(k) / K(kp(k)) + K(k3) / K(kp(k3)))
    xs = CrossSection(slabs = [Slab(0, h, e)], conductors = [Conductor(-w / 2, w / 2, h, h)], plane_bottom = 0.0,
                      grounds = [Conductor(-w / 2 - s - 3, -w / 2 - s, h, h), Conductor(w / 2 + s, w / 2 + s + 3, h, h)])
    @test isapprox(line_params(solve_extrapolated(xs)).Z0, zc; rtol = 0.01)
    # solder mask and copper thickness both lower Z0
    m0 = line_params(solve_extrapolated(CrossSection(slabs = [Slab(0, 0.2, 4.3)], conductors = [Conductor(-0.15, 0.15, 0.2, 0.235)],
                                                     plane_bottom = 0.0))).Z0
    m1 = line_params(solve_extrapolated(CrossSection(slabs = [Slab(0, 0.2, 4.3)], conductors = [Conductor(-0.15, 0.15, 0.2, 0.235)],
                                                     plane_bottom = 0.0, coat_t = 0.015, coat_εr = 3.3, coat_surface = 0.2))).Z0
    @test m1 < m0 < hammerstad_microstrip(0.3, 0.2, 4.3)[1]
end

@testset "SI: differential pair names" begin
    pairs = find_diff_pairs(["USB_P", "USB_N", "D+", "D-", "X+", "MOSFET_P", "/a/DP", "/a/DM", "CLK_T", "CLK_C", "GND"])
    names = Dict(p => (nm, n) for (nm, p, n) in pairs)
    @test names["USB_P"] == ("USB", "USB_N")
    @test names["D+"] == ("D±", "D-")
    @test names["/a/DP"] == ("/a/DP/DM", "/a/DM")
    @test names["CLK_T"] == ("CLK", "CLK_C")
    @test length(pairs) == 4                       # X+ and MOSFET_P have no partner
    @test globmatch("*USB*", "/conn/USB_D") && globmatch("DP", "/a/DP") && !globmatch("D+", "/b/ID+")
end

# 4-layer board 40 × 20 mm: F.Cu / In1 (GND, with a slot) / In2 (GND) / B.Cu
si_stackup() = [BP.StackupLayer("F.Mask", "Top Solder Mask", 0.015, "", 3.3, 0.0),
                BP.StackupLayer("F.Cu", "copper", 0.035, "", 0.0, 0.0),
                BP.StackupLayer("dielectric 1", "prepreg", 0.2, "", 4.2, 0.02),
                BP.StackupLayer("In1.Cu", "copper", 0.035, "", 0.0, 0.0),
                BP.StackupLayer("dielectric 2", "core", 1.0, "", 4.5, 0.02),
                BP.StackupLayer("In2.Cu", "copper", 0.035, "", 0.0, 0.0),
                BP.StackupLayer("dielectric 3", "prepreg", 0.2, "", 4.2, 0.02),
                BP.StackupLayer("B.Cu", "copper", 0.035, "", 0.0, 0.0),
                BP.StackupLayer("B.Mask", "Bottom Solder Mask", 0.015, "", 3.3, 0.0)]
function si_board(; extra_vias = BP.Via[], sig2_end = 35.0)
    T(x0, y0, x1, y1, w, layer, net) = BP.Trace(BP.Point(x0, y0), BP.Point(x1, y1), w, layer, net)
    traces = [T(5, 5, 35, 5, 0.3, "F.Cu", "SIG1"),                 # crosses the In1 slot at x = 20…21
              T(5, 15, sig2_end, 15, 0.3, "F.Cu", "SIG2"),         # over solid In1
              T(25, 10, 39, 10, 0.3, "F.Cu", "SIG3"),              # runs off the planes (they end at x = 36)
              T(5, 8, 30, 8, 0.15, "F.Cu", "USB_P"), T(5, 8.3, 30, 8.3, 0.15, "F.Cu", "USB_N"),
              T(30, 8.3, 31, 8.3, 0.15, "F.Cu", "USB_N"),          # 1 mm longer: skew
              T(5, 2, 10, 2, 0.3, "F.Cu", "SIG4"), T(10, 2, 20, 2, 0.3, "B.Cu", "SIG4")]
    in1 = [rectpts(0, 0, 20, 20), rectpts(21, 0, 36, 20), rectpts(20, 12, 21, 20)]
    zones = [BP.Zone("In1.Cu", "GND", rectpts(0, 0, 36, 20), in1), BP.Zone("In2.Cu", "GND", rectpts(0, 0, 36, 20), [rectpts(0, 0, 36, 20)])]
    vias = vcat([BP.Via(BP.Point(10, 2), 0.6, 0.3, ["F.Cu", "B.Cu"], "SIG4")], extra_vias)
    nets = Set(["GND", "SIG1", "SIG2", "SIG3", "SIG4", "USB_P", "USB_N"])
    BP.BoardData(40.0, 20.0, nets, BP.Component[], traces, vias, zones, [vcat(rectpts(0, 0, 40, 20), [BP.Point(0, 0)])], si_stackup())
end

@testset "SI: impedance, delay, return paths, skew, groups" begin
    b = si_board()
    s = new_setup("si.kicad_pcb", b)
    @test netclass(s, "GND") == :ground
    SISolver.set_si_groups!(s, [SISolver.GroupDef("BUS", ["SIG1", "SIG2"], 0.5, :length)])
    r = solve_si(b, s)
    @test r.ok
    # the microstrip over In1: same Z as a hand-built cross-section (35 µm copper under 15 µm mask)
    hand = line_params(solve_extrapolated(CrossSection(slabs = [Slab(0, 0.2, 4.2)], conductors = [Conductor(-0.15, 0.15, 0.2, 0.235)],
                                                       plane_bottom = 0.0, coat_t = 0.015, coat_εr = 3.3, coat_surface = 0.2)))
    sig2 = only(n for n in r.nets if n.net == "SIG2")
    @test isapprox(sig2.zmin, hand.Z0; rtol = 1e-3) && isapprox(sig2.zmax, hand.Z0; rtol = 1e-3)
    @test 45 < hand.Z0 < 60
    @test isapprox(sig2.length, 30.0; rtol = 1e-9)
    @test isapprox(sig2.delay, 30e-3 * hand.delay; rtol = 1e-3)
    @test any(p -> p.kind == :microstrip && p.ref == "In1.Cu GND", r.pieces)
    # over the slot SIG1 references In2 through the core: much higher Z0, and a gap finding
    sig1 = only(n for n in r.nets if n.net == "SIG1")
    @test sig1.zmax > 1.5 * hand.Z0
    gi = [i for i in r.issues if i.kind == :gap && i.net == "SIG1"]
    @test length(gi) == 1 && 19.5 < gi[1].x < 21.5 && occursin("In1.Cu GND", gi[1].text)
    @test !any(i -> i.net == "SIG2" && i.kind in (:gap, :noref, :split), r.issues)
    # SIG3 leaves the planes: no reference for the last 3 mm
    ni = only(i for i in r.issues if i.kind == :noref && i.net == "SIG3")
    @test ni.x > 36 && occursin("(3.0 mm)", ni.text) && ni.severity == :info     # not a high-speed net
    @test count(i -> i.kind == :noref, r.issues) == 1
    # USB pair: 90 Ω default target, coupled ~96 %, 1 mm skew
    up = only(r.pairs)
    @test up.name == "USB" && up.target == 90.0
    handp = pair_params(solve_extrapolated(CrossSection(slabs = [Slab(0, 0.2, 4.2)], plane_bottom = 0.0,
                                                        conductors = [Conductor(-0.225, -0.075, 0.2, 0.235), Conductor(0.075, 0.225, 0.2, 0.235)],
                                                        coat_t = 0.015, coat_εr = 3.3, coat_surface = 0.2)))
    @test isapprox(up.zd_min, handp.Zdiff; rtol = 2e-3)        # over solid plane (the slot raises it)
    @test up.zd_max > 1.1 * up.zd_min && !up.z_ok
    @test isapprox(up.skew, 1.0; atol = 1e-6) && !up.skew_ok
    @test 0.9 < up.coupled < 1.0
    @test any(i -> i.kind == :skew, r.issues)
    # SIG4 changes from In1 to In2 (both GND) with no return via; adding one 0.8 mm away fixes it
    ri = only(i for i in r.issues if i.kind in (:return_via, :stitch_cap) && i.net == "SIG4")
    @test ri.kind == :return_via && occursin("no GND via", ri.text)
    r2 = solve_si(si_board(extra_vias = [BP.Via(BP.Point(10.8, 2), 0.6, 0.3, ["F.Cu", "B.Cu"], "GND")]), s)
    @test !any(i -> i.kind == :return_via, r2.issues)
    sig4 = only(n for n in r.nets if n.net == "SIG4")
    @test sig4.nvias == 1 && isapprox(sig4.via_len, 0.2 + 1.0 + 0.2 + 3 * 0.035; rtol = 1e-6)
    # length group: SIG1 and SIG2 are both 30 mm; shortening SIG2 by 1 mm breaks the 0.5 mm budget
    g = only(r.groups)
    @test g.ok && g.spread < 1e-9
    r3 = solve_si(si_board(sig2_end = 34.0), s)
    @test !only(r3.groups).ok && any(i -> i.kind == :group, r3.issues)
    # impedance table and summary
    @test !isempty(r.xsecs) && all(x -> x.len > 0, r.xsecs)
    @test any(l -> occursin("pair USB", l), si_summary_lines(r))
    @test any(l -> occursin("Length 30.00 mm", l), si_net_report(r, "SIG2"))
end

@testset "SI: setup round trip and nominal stackup" begin
    b = si_board()
    dir = mktempdir()
    s = new_setup(joinpath(dir, "si.kicad_pcb"), b)
    SISolver.set_si_targets!(s, [SISolver.ZTarget("SIG*", 40.0, 5.0, :se), SISolver.ZTarget("USB", 85.0, NaN, :diff)])
    SISolver.set_si_groups!(s, [SISolver.GroupDef("BUS", ["SIG1", "SIG2"], 10.0, :delay)])
    s.si["pair_skew_mm"] = 0.1
    save_setup(s)
    s2, _ = load_setup(joinpath(dir, "si.kicad_pcb"), b)
    ts = si_targets(s2)
    @test length(ts) == 2 && ts[1].z == 40.0 && ts[1].tol_pct == 5.0 && ts[1].mode == :se && isnan(ts[2].tol_pct)
    @test only(si_groups(s2)).by == :delay && si_settings(s2).pair_skew_mm == 0.1
    r = solve_si(b, s2)
    @test only(r.pairs).target == 85.0
    @test only(n for n in r.nets if n.net == "SIG2").target == 40.0
    @test any(i -> i.kind == :z && i.net == "SIG2", r.issues)          # a ~50 Ω microstrip misses 40 Ω ±5 %
    # without a stackup the solver still runs, on a nominal 1.6 mm board, and says so
    b0 = BP.BoardData(b.width, b.height, b.nets, b.components, b.traces, b.vias, b.zones, b.outline, BP.StackupLayer[])
    r0 = solve_si(b0, new_setup("x.kicad_pcb", b0))
    @test r0.ok && !r0.stack.defined && any(m -> occursin("nominal 1.6 mm", m), r0.messages)
end

@testset "HTML report" begin
    @test Report.base64(UInt8[]) == "" && Report.base64(codeunits("f")) == "Zg==" &&
          Report.base64(codeunits("fo")) == "Zm8=" && Report.base64(codeunits("foobar")) == "Zm9vYmFy"
    b = testboard(comps = strip_parts(), zones = strip_zones())
    s = testsetup(b)
    s.ac["points_per_decade"] = 3
    dc, ac = solve_dc(b, s), solve_ac(b, s)
    bs = si_board()
    ss = new_setup("si.kicad_pcb", bs)
    si = solve_si(bs, ss)
    dir = mktempdir()
    png = joinpath(dir, "x.png")
    write(png, UInt8[0x89, 0x50, 0x4e, 0x47])                       # contents don't matter, it is embedded as-is
    path = write_report(joinpath(dir, "r.html"); board = b, setup = s, dc, ac, si, version = "v9",
                        images = [(:dc, "Voltage <map>", png), (:si, "SI", png)])
    html = read(path, String)
    @test startswith(html, "<!doctype html>") && occursin("</html>", html)
    for want in ("DC analysis", "AC analysis", "<svg", "Signal integrity", "Differential pairs", "Impedance table",
                 "Stackup", "data:image/png;base64,iVBORw==", "Voltage &lt;map&gt;", "SNK1", "USB")
        @test occursin(want, html)
    end
    @test count("<figure>", html) == 2
    # without results it still writes a page that says so
    empty_html = read(write_report(joinpath(dir, "e.html"); board = b, setup = s), String)
    @test occursin("Run an analysis first", empty_html) && !occursin("DC analysis", empty_html)
    @test report_path("/a/b/board.kicad_pcb") == "/a/b/board.perplex-report.html"
end

# ─────────────────────────────────────────────────────────────────────────────
# Optional: a real board
# ─────────────────────────────────────────────────────────────────────────────
const BOARD = get(ENV, "PERPLEXFORGE_TEST_BOARD", "")
if isfile(BOARD)
    include("board_tests.jl")
else
    @info "Real-board tests skipped (set PERPLEXFORGE_TEST_BOARD to a .kicad_pcb to run them)."
end
