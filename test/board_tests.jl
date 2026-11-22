# Tests on a real KiCad board (included by runtests.jl when PERPLEXFORGE_TEST_BOARD is set).
# Written against a 4-layer STM32F405 board with an MP2359 buck on +3V3; checks that
# don't hold for other boards are skipped automatically.

board = parse_kicad_board(BOARD; verbose = false)
findcomp(value) = (i = findfirst(c -> c.value == value, board.components); i === nothing ? nothing : board.components[i])
mcu, buck = findcomp("STM32F405RGT6"), findcomp("MP2359DJ-LF-Z")

@testset "real board: parse" begin
    @test !isempty(board.components) && !isempty(board.nets)
    @test count(c -> !isempty(c.value), board.components) > length(board.components) ÷ 2
end

if mcu === nothing || buck === nothing
    @info "Board-specific checks skipped: this board has no STM32F405RGT6 / MP2359DJ-LF-Z."
else
    @testset "real board: guesses" begin
        s = new_setup(BOARD, board)
        @test guess_kind(mcu, s) == :sink
        @test guess_kind(buck, s) == :vrm
        sink = default_element(:sink, mcu, s)
        @test netclass(s, sink.net_pos) == :power && sink.net_neg == "GND"
    end

    @testset "real board: DC" begin
        s = new_setup(BOARD, board)
        sink = default_element(:sink, mcu, s)
        sink.params["I"] = 0.15
        push!(s.elements, sink)
        push!(s.elements, SimSetups.Element("VRM1", :vrm, buck.ref, sink.net_pos, "GND", Dict("V" => 3.3, "Rout" => 0.005, "Lout" => 1e-9)))
        r = solve_dc(board, s)
        @test r.ok
        @test isapprox(r.vrms[1].I, 0.15; rtol = 1e-4)          # KCL (tie conductances limit precision)
        @test 0 < r.sinks[1].drop_mV < 50
        @test any(occursin("nearest", m) for m in r.messages)  # the buck has no pad on its output rail
        foreach(l -> println("    ", l), dc_summary_lines(r))
    end

    @testset "real board: AC, decoupling lowers |Z|" begin
        s = new_setup(BOARD, board)
        sink = default_element(:sink, mcu, s)
        sink.params["I"] = 0.15
        push!(s.elements, sink)
        l1 = first(c for c in board.components if startswith(c.ref, "L") && any(p -> p.net_name == sink.net_pos, c.pads))
        push!(s.elements, SimSetups.Element("VRM1", :vrm, l1.ref, sink.net_pos, "GND", Dict("V" => 3.3, "Rout" => 0.005, "Lout" => 1e-7)))
        s.ac["points_per_decade"] = 3
        r0 = solve_ac(board, s)
        @test r0.ok
        rd = solve_dc(board, s)
        @test isapprox(abs(r0.ports[1].Z[1]), rd.sinks[1].drop_mV * 1e-3 / 0.15; rtol = 0.25)   # coarser AC mesh
        caps = [c for c in board.components if startswith(c.ref, "C") && parse_si(c.value) !== nothing &&
                any(p -> p.net_name == sink.net_pos, c.pads) && any(p -> p.net_name == "GND", c.pads)]
        @test !isempty(caps)
        foreach(c -> push!(s.elements, default_element(:capacitor, c, s)), caps)
        r1 = solve_ac(board, s)
        @test r1.ok
        i10M = argmin(abs.(r1.freqs .- 1e7))
        @test abs(r1.ports[1].Z[i10M]) < 0.5 * abs(r0.ports[1].Z[i10M])
        println("    $(length(caps)) decoupling caps: |Z| at 10 MHz $(format_si(abs(r0.ports[1].Z[i10M]), "Ω")) → $(format_si(abs(r1.ports[1].Z[i10M]), "Ω"))")
    end
end
