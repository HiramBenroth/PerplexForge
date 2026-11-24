# Installs the latest development build of PerplexForge (the dev branch) into KiCad 10.
#
#   irm https://raw.githubusercontent.com/HiramBenroth/PerplexForge/dev/install-dev.ps1 | iex
#
# Run it again to update to the newest dev commit. To go back to the released version, run the
# normal installer (see the README). Dev builds are named after the last release plus a letter
# per commit since then: v0.2.0a, v0.2.0b, …
$env:PF_CHANNEL = "dev"
try {
    Invoke-RestMethod "https://raw.githubusercontent.com/HiramBenroth/PerplexForge/dev/install.ps1" | Invoke-Expression
} finally {
    Remove-Item Env:PF_CHANNEL -ErrorAction SilentlyContinue
}
