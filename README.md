<p align="center"><img src="assets/icons/icon_128.png" width="96" alt="PerplexForge logo"></p>

# PerplexForge

A power- and signal-integrity workbench for **KiCad 10**. One click in the PCB Editor opens the current board in 3D, where you can:

**Power integrity**

- **Set up the power network**: classify nets (power / ground / digital), then model parts as lumped elements: VRMs, sinks (loads), resistors, inductors, ferrites, 0 Ω links and capacitors. Values are pre-filled from the schematic.
- **DC analysis (IR drop)**: voltage, IR-drop and current-density maps on every copper layer, the voltage at each load's pins, VRM currents, the most heavily loaded vias and the copper loss.
- **AC analysis (PDN impedance)**: |Z(f)| seen by every load with target-impedance checks, and a 3D map of the noise voltage at any frequency you click.

**Signal integrity**

- **Trace impedance and delay**: every routed signal trace is solved with a 2-D field solver on its real cross-section: the board stackup, the reference planes above and below it, solder mask, a coplanar ground pour beside it, and its differential-pair partner. You get Z0, Zdiff, εeff and delay per trace, an impedance table of every cross-section on the board, and checks against your targets (USB pairs default to 90 Ω).
- **Return paths**: traces that run off their reference plane or cross a gap or split in it, and signal vias that change reference plane without a nearby return via (or, when the reference changes net, a stitching capacitor).
- **Lengths and skew**: net length and delay including vias, intra-pair skew of differential pairs (found by name: `_P/_N`, `+/-`, `DP/DM` …), length-match groups, and via stubs.

Findings are graded: nets with an impedance target, differential pairs and length-group members get errors and warnings; everything else is a note.

**Reports**: one click writes `<board>.perplex-report.html`, a self-contained report of the DC, AC and SI results with 3D snapshots. Open it in any browser, or print it to PDF.

Your board is never modified. The simulation setup is saved next to it as `<board>.perplex.json`.

## Install (Windows)

You need **KiCad 10**. Close KiCad, open **PowerShell** and paste:

```powershell
irm https://raw.githubusercontent.com/HiramBenroth/PerplexForge/main/install.ps1 | iex
```

The installer:

1. installs **Julia** (the language PerplexForge runs on) if it's missing
2. downloads the latest release and installs it into KiCad's plugin folder
3. turns on the **KiCad API** (Preferences → Plugins), which PerplexForge needs
4. installs PerplexForge's Julia packages. This takes several minutes, once.

Then open a board in the PCB Editor and click the **PerplexForge** toolbar button. On the very first click KiCad also sets up a small Python environment for the plugin, which needs internet once.

**Update**: run the same command again. **Uninstall**: delete `Documents\KiCad\10.0\plugins\perplexforge`.

## Install (macOS)

You need **KiCad 10**. Quit KiCad, open **Terminal** and paste:

```bash
curl -fsSL https://raw.githubusercontent.com/HiramBenroth/PerplexForge/main/install.sh | bash
```

It does the same four steps as the Windows installer (Julia comes from the official `juliaup` installer). Then open a board in the PCB Editor and click the **PerplexForge** toolbar button. The workbench opens in a Terminal window, which shows its progress and any errors; keep it open while you work.

**Update**: run the same command again. **Uninstall**: delete `~/Documents/KiCad/10.0/plugins/perplexforge`.

If the button does nothing, look at `~/Documents/KiCad/10.0/plugins/perplexforge/perplexforge_plugin.log`.

<details>
<summary>Other ways to install</summary>

- **KiCad Plugin and Content Manager**: click **Manage…** (repositories) and add
  `https://raw.githubusercontent.com/HiramBenroth/PerplexForge/main/pcm/repository.json`,
  then install PerplexForge from that repository. You still need Julia 1.12+ ([julialang.org/install](https://julialang.org/install/)) and the KiCad API turned on.
- **Manual**: download the zip from [Releases](https://github.com/HiramBenroth/PerplexForge/releases) and use **Install from File…** in the Plugin and Content Manager.

</details>

The version you're running is shown in the window title and the top bar, e.g. `v0.1.0`.

## Using it

1. Save the board in KiCad and refill zones (**B**). PerplexForge reads the saved file.
2. **Nets** tab: check the power/ground classes (they're guessed from net names). Ground and power pours are the reference planes for signal integrity.
3. Power integrity: click a part (in 3D or in the **Components** list) and **+ Add** an element: a VRM on the regulator or its output inductor, a sink on each load, and capacitors for AC. Then **▶ Run DC analysis** or **▶ Run AC sweep**. Results appear in the **Power** tab, on the copper in 3D, and (for AC) in the **PDN impedance** tab below the view.
4. Signal integrity: **▶ Run SI analysis** needs no setup. Results appear in the **Signals** tab, on the traces in 3D (coloured by impedance, by target, or by reference type) and in the **Signals** tables below the view. Click a finding to highlight it. Add impedance targets in the Signals tab (or `target *CLK* 50`), and length-match groups with `group add DDR_DQ 0.5 DQ*`.
5. **Report** writes the HTML report; **Save** stores the setup next to the board.

Type `help` in the console for keyboard-friendly commands.

## Development

```text
src/            workbench (GLMakie UI) and the GUI-free solvers (DCSolver, ACSolver, Mesh, XSection, SISolver) and Report
bin/            launch.jl (entry point) and perplexforge.bat / perplexforge.sh (run without KiCad)
kicad_plugin/   the KiCad IPC plugin (Python launcher, plugin.json, toolbar icons)
test/           unit tests; gui_snapshot.jl renders the UI offscreen
tools/          release.ps1 (publish a release), build_pcm.py (build the add-on package)
assets/         icons and their SVG sources
install.ps1     the one-line installer (Windows)
install.sh      the one-line installer (macOS)
```

A copy running from a git checkout shows its version as `v0.1.0-dev (commit)`, so it's never confused with an installed release.

Run without KiCad: `julia --project=. bin/launch.jl path/to/board.kicad_pcb`

Tests (the solvers are checked against hand calculations, the analytic plane-pair resonance, and the exact stripline, coupled-stripline and microstrip impedance solutions):
`julia --project=. test/runtests.jl`. Set `PERPLEXFORGE_TEST_BOARD` to a `.kicad_pcb` to also run the real-board tests.

### Branches and releases

- **`dev`**: everyday work. Push it whenever you like; it never reaches users.
- **`main`**: released versions only.
- **Releasing**: from `dev` with everything committed, run `.\tools\release.ps1 0.2.0`. It runs the tests, sets the version, merges into `main`, tags `v0.2.0` and pushes. GitHub Actions then builds the add-on zip, creates the GitHub release and updates the add-on repository (`pcm/`). Installers and KiCad's add-on manager only ever pick up these tagged releases.

## License

[MIT](LICENSE)
