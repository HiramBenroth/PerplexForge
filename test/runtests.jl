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
end
using .PFCore.BoardParser
using .PFCore.SimSetups
using .PFCore.DCSolver
using .PFCore.ACSolver

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
# Optional: a real board
# ─────────────────────────────────────────────────────────────────────────────
const BOARD = get(ENV, "PERPLEXFORGE_TEST_BOARD", "")
if isfile(BOARD)
    include("board_tests.jl")
else
    @info "Real-board tests skipped (set PERPLEXFORGE_TEST_BOARD to a .kicad_pcb to run them)."
end
