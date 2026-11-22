# PerplexForge installer for Windows + KiCad 10.
#
#   irm https://raw.githubusercontent.com/HiramBenroth/PerplexForge/main/install.ps1 | iex
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

Write-Host "PerplexForge installer" -ForegroundColor Green

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

# -- 2. Latest release --------------------------------------------------------
Step "Downloading the latest PerplexForge release"
$rel = Invoke-RestMethod "https://api.github.com/repos/$Owner/$Repo/releases/latest" -Headers @{ "User-Agent" = "PerplexForge-installer" }
$asset = $rel.assets | Where-Object { $_.name -like "PerplexForge-*.zip" } | Select-Object -First 1
if (-not $asset) { Fail "No release package found on GitHub." }
$tmp = Join-Path ([IO.Path]::GetTempPath()) ("perplexforge-" + [guid]::NewGuid())
New-Item -ItemType Directory -Path $tmp | Out-Null
$zip = Join-Path $tmp $asset.name
Invoke-WebRequest $asset.browser_download_url -OutFile $zip -Headers @{ "User-Agent" = "PerplexForge-installer" }
Expand-Archive $zip (Join-Path $tmp "pkg")
Info "$($rel.tag_name)  ($([math]::Round($asset.size / 1KB)) KB)"

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
& $julia --startup-file=no --project="$dest\julia" -e 'using Pkg; Pkg.instantiate(); Pkg.precompile()'
if ($LASTEXITCODE) { Fail "Installing the Julia packages failed (see above). Check your internet connection and run this again." }

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ""
Write-Host "PerplexForge $($rel.tag_name) is installed." -ForegroundColor Green
Write-Host "Open a board in KiCad's PCB Editor and click the PerplexForge button on the toolbar."
Write-Host "(The first click lets KiCad set up the plugin's Python environment; it needs internet once.)"
Write-Host "If the button is missing: PCB Editor > Preferences > Plugins, and make sure PerplexForge is shown."
