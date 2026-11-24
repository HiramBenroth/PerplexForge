# PerplexForge installer for Windows + KiCad 10.
#
#   irm https://raw.githubusercontent.com/HiramBenroth/PerplexForge/main/install.ps1 | iex
#
# Development builds (the latest commit on the dev branch, for testing):
#
#   irm https://raw.githubusercontent.com/HiramBenroth/PerplexForge/dev/install-dev.ps1 | iex
#
# What it does (run it again any time to update to the latest release):
#   1. installs Julia (via juliaup) if it is missing or too old
#   2. downloads the latest PerplexForge release and installs it into KiCad's plugin folder
#   3. turns on the KiCad API (Preferences > Plugins), which PerplexForge needs
#   4. installs PerplexForge's Julia packages, so the first click in KiCad is fast
# KiCad must be closed while it runs.

$ErrorActionPreference = "Stop"
$ProgressPreference = "SilentlyContinue"
$Owner = "HiramBenroth"
$Repo = "PerplexForge"

function Step($m) { Write-Host ""; Write-Host "==> $m" -ForegroundColor Cyan }
function Info($m) { Write-Host "    $m" }
function Fail($m) { Write-Host ""; Write-Host "PerplexForge was not installed: $m" -ForegroundColor Red; throw $m }

$Dev = $env:PF_CHANNEL -eq "dev"
Write-Host ("PerplexForge installer" + $(if ($Dev) { "  (development build from the dev branch)" } else { "" })) -ForegroundColor Green

# -- 0. KiCad -----------------------------------------------------------------
$kicadCfg = Join-Path $env:APPDATA "kicad\10.0"
if (-not (Test-Path (Join-Path $kicadCfg "kicad_common.json"))) {
    Fail "KiCad 10 settings not found. Install KiCad 10 and start it once, then run this again."
}
if (-not $env:PF_IGNORE_RUNNING -and (Get-Process kicad, pcbnew -ErrorAction SilentlyContinue)) {
    Fail "KiCad is running. Close all KiCad windows, then run this again."
}

# -- 1. Julia -----------------------------------------------------------------
Step "Checking Julia"
$alias = Join-Path $env:LOCALAPPDATA "Microsoft\WindowsApps\julia.exe"
function Find-Julia {
    $cmd = Get-Command julia -ErrorAction SilentlyContinue
    if ($cmd) { return $cmd.Source }
    if (Test-Path $alias) { return $alias }
    return $null
}
$julia = Find-Julia
if (-not $julia) {
    Info "Julia not found: installing it with winget (juliaup)..."
    winget install --id Julialang.Juliaup -e --accept-source-agreements --accept-package-agreements --silent
    $julia = Find-Julia
    if (-not $julia) { Fail "Julia could not be installed automatically. Install it from https://julialang.org/install/ and run this again." }
}
$ok = & $julia --startup-file=no -e 'print(VERSION >= v"1.12")'
if ($ok -ne "true") {
    Info "Julia is older than 1.12: updating with juliaup..."
    $juliaup = Get-Command juliaup -ErrorAction SilentlyContinue
    if (-not $juliaup) { Fail "Julia 1.12 or newer is required. Update it from https://julialang.org/install/ and run this again." }
    & juliaup add release; & juliaup default release
}
Info ("Julia " + (& $julia --startup-file=no -e 'print(VERSION)'))

# -- 2. Download --------------------------------------------------------------
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("perplexforge-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null
$hdr = @{ "User-Agent" = "PerplexForge-installer" }
if ($Dev) {
    Step "Downloading the latest development build (dev branch)"
    $commit = Invoke-RestMethod "https://api.github.com/repos/$Owner/$Repo/commits/dev" -Headers $hdr
    $sha = $commit.sha
    $zip = Join-Path $tmp "dev.zip"
    Invoke-WebRequest "https://github.com/$Owner/$Repo/archive/$sha.zip" -OutFile $zip -Headers $hdr
    Expand-Archive $zip (Join-Path $tmp "src")
    $srcDir = Get-ChildItem (Join-Path $tmp "src") -Directory | Select-Object -First 1
    # lay it out like a release package: plugins\ = the KiCad plugin, plugins\julia\ = the Julia project
    $pkgPlugins = Join-Path $tmp "pkg\plugins"
    New-Item -ItemType Directory -Force -Path (Join-Path $pkgPlugins "julia\assets") | Out-Null
    Copy-Item (Join-Path $srcDir.FullName "kicad_plugin\*") $pkgPlugins -Recurse
    foreach ($f in "Project.toml", "LICENSE") { Copy-Item (Join-Path $srcDir.FullName $f) (Join-Path $pkgPlugins "julia") }
    foreach ($d in "src", "bin") { Copy-Item (Join-Path $srcDir.FullName $d) (Join-Path $pkgPlugins "julia") -Recurse }
    foreach ($d in "icons", "macos") {
        $a = Join-Path $srcDir.FullName "assets\$d"
        if (Test-Path $a) { Copy-Item $a (Join-Path $pkgPlugins "julia\assets") -Recurse }
    }
    # name the build after the last release plus a letter per commit since: v0.2.0a, v0.2.0b, …
    $short = $sha.Substring(0, 7)
    $label = $null
    try {
        $tag = (Invoke-RestMethod "https://api.github.com/repos/$Owner/$Repo/releases/latest" -Headers $hdr).tag_name
        $n = [int](Invoke-RestMethod "https://api.github.com/repos/$Owner/$Repo/compare/$tag...$sha" -Headers $hdr).ahead_by
        $letters = ""
        while ($n -gt 0) {
            $n = $n - 1
            $letters = [string][char](97 + ($n % 26)) + $letters
            $n = [int][math]::Floor($n / 26)
        }
        $label = "$tag$letters"
    } catch { }
    if (-not $label) {
        $pv = (Select-String -Path (Join-Path $pkgPlugins "julia\Project.toml") -Pattern '^version = "(.*)"').Matches[0].Groups[1].Value
        $label = "v$($pv)-dev"
    }
    Set-Content -Path (Join-Path $pkgPlugins "julia\DEV_VERSION") -Value "$label $short" -NoNewline
    Info "$label (commit $short)  $($commit.commit.message.Split("`n")[0])"
} else {
    Step "Downloading the latest PerplexForge release"
    $rel = Invoke-RestMethod "https://api.github.com/repos/$Owner/$Repo/releases/latest" -Headers $hdr
    $asset = $rel.assets | Where-Object { $_.name -like "PerplexForge-*.zip" } | Select-Object -First 1
    if (-not $asset) { Fail "No release package found on GitHub." }
    $zip = Join-Path $tmp $asset.name
    Invoke-WebRequest $asset.browser_download_url -OutFile $zip -Headers $hdr
    Expand-Archive $zip (Join-Path $tmp "pkg")
    $label = $rel.tag_name
    Info "$label  ($([math]::Round($asset.size / 1KB)) KB)"
}

# -- 3. Install into KiCad's plugin folder ------------------------------------
Step "Installing into KiCad"
$docsHome = if ($env:KICAD_DOCUMENTS_HOME) { $env:KICAD_DOCUMENTS_HOME } else { Join-Path ([Environment]::GetFolderPath("MyDocuments")) "KiCad" }
$plugins = Join-Path $docsHome "10.0\plugins"
$dest = Join-Path $plugins "perplexforge"
New-Item -ItemType Directory -Force -Path $plugins | Out-Null
if (Test-Path $dest) {
    $item = Get-Item $dest -Force
    if ($item.LinkType) { cmd /c rmdir "$dest" | Out-Null }          # a dev link: remove the link only
    else { Remove-Item $dest -Recurse -Force }
}
Copy-Item (Join-Path $tmp "pkg\plugins") $dest -Recurse
Info $dest

# -- 4. KiCad API -------------------------------------------------------------
Step "Enabling the KiCad API"
$common = Join-Path $kicadCfg "kicad_common.json"
$text = [IO.File]::ReadAllText($common)
if ($text -match '"enable_server"\s*:\s*true') {
    Info "already on"
} else {
    Copy-Item $common "$common.bak" -Force
    if ($text -match '"enable_server"\s*:\s*false') {
        $text = $text -replace '"enable_server"\s*:\s*false', '"enable_server": true'
    } else {
        $json = $text | ConvertFrom-Json
        if (-not $json.api) { $json | Add-Member -NotePropertyName api -NotePropertyValue ([pscustomobject]@{}) }
        $json.api | Add-Member -NotePropertyName enable_server -NotePropertyValue $true -Force
        $text = $json | ConvertTo-Json -Depth 100
    }
    [IO.File]::WriteAllText($common, $text, (New-Object Text.UTF8Encoding $false))
    Info "on (previous settings saved as kicad_common.json.bak)"
}

# -- 5. Julia packages --------------------------------------------------------
Step "Installing PerplexForge's Julia packages (several minutes, once)"
# Windows 11 Smart App Control blocks unsigned DLLs, and Julia's compiled package images are
# DLLs built on this PC ("julia.exe - Bad Image ... 0xc0e90002"). While it is enforcing, build
# (and later run) without package images; the KiCad plugin makes the same check.
$sac = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Control\CI\Policy" -Name VerifiedAndReputablePolicyState -ErrorAction SilentlyContinue).VerifiedAndReputablePolicyState
$jflags = @("--startup-file=no")
if ($sac -eq 1) {
    Info "Smart App Control is on: Julia will run without package images (no compiled DLLs; slower start)."
    $jflags += "--pkgimages=no"
}
& $julia @jflags --project="$dest\julia" -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()'
if ($LASTEXITCODE) { Fail "Installing the Julia packages failed (see above). Check your internet connection and run this again." }

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "PerplexForge $label is installed." -ForegroundColor Green
Write-Host "Open a board in KiCad's PCB Editor and click the PerplexForge button on the toolbar."
Write-Host "(The first click lets KiCad set up the plugin's Python environment; it needs internet once.)"
Write-Host "If the button is missing: PCB Editor > Preferences > Plugins, and make sure PerplexForge is shown."
