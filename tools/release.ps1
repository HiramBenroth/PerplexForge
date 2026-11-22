# Publish the current `dev` branch as a release.
#
#   .\tools\release.ps1 0.2.0
#
# 1. checks you are on `dev` with everything committed, and runs the tests
# 2. sets the version in Project.toml and commits it on dev
# 3. merges dev into main, tags v0.2.0 and pushes
# GitHub Actions (.github/workflows/release.yml) then builds the add-on zip, creates the
# GitHub release and updates the add-on repository that KiCad reads. Users only ever get
# tagged releases; whatever you push to `dev` in between never reaches them.
param([Parameter(Mandatory = $true)][string]$Version)
$ErrorActionPreference = "Stop"
Set-Location (Split-Path -Parent $PSScriptRoot)

function Run($exe) { & $exe @args; if ($LASTEXITCODE) { throw "'$exe $args' failed" } }

if ($Version -notmatch '^\d+\.\d+\.\d+$') { throw "Version must look like 1.2.3" }
if ((git branch --show-current) -ne "dev") { throw "Switch to the dev branch first (git switch dev)." }
if (git status --porcelain) { throw "You have uncommitted changes. Commit them on dev first." }
Run git fetch origin --tags
if (git tag -l "v$Version") { throw "v$Version already exists." }

Write-Host "==> Running tests" -ForegroundColor Cyan
Run julia --project=. test/runtests.jl

Write-Host "==> Setting version $Version" -ForegroundColor Cyan
$toml = Join-Path (Get-Location) "Project.toml"
$text = [IO.File]::ReadAllText($toml) -replace '(?m)^version = ".*"', "version = `"$Version`""
[IO.File]::WriteAllText($toml, $text, (New-Object Text.UTF8Encoding $false))
Run git commit -am "Release v$Version"
Run git push origin dev

Write-Host "==> Merging into main and tagging v$Version" -ForegroundColor Cyan
Run git switch main
Run git pull --ff-only origin main
Run git merge --no-ff dev -m "Release v$Version"
Run git tag -a "v$Version" -m "PerplexForge v$Version"
Run git push origin main "v$Version"
Run git switch dev

Write-Host ""
Write-Host "Pushed v$Version. GitHub is building the release now; watch it with:  gh run watch" -ForegroundColor Green
