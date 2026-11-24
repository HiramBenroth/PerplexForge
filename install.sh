#!/bin/bash
# PerplexForge installer for macOS + KiCad 10.
#
#   curl -fsSL https://raw.githubusercontent.com/HiramBenroth/PerplexForge/main/install.sh | bash
#
# Development build (the latest commit on the dev branch, for testing):
#
#   curl -fsSL https://raw.githubusercontent.com/HiramBenroth/PerplexForge/dev/install.sh | bash -s -- --dev
#
# What it does (run it again any time to update to the latest release):
#   1. installs Julia (via juliaup) if it is missing or too old
#   2. downloads the latest PerplexForge release and installs it into KiCad's plugin folder
#   3. turns on the KiCad API (Preferences > Plugins), which PerplexForge needs
#   4. installs PerplexForge's Julia packages, so the first click in KiCad is fast
# KiCad must be closed while it runs.

set -euo pipefail

# Wrapped in { } so that a partial download (curl | bash) never runs half a script.
{

OWNER="HiramBenroth"
REPO="PerplexForge"

step() { printf '\n\033[36m==> %s\033[0m\n' "$1"; }
info() { printf '    %s\n' "$1"; }
fail() { printf '\n\033[31mPerplexForge was not installed: %s\033[0m\n' "$1" >&2; exit 1; }

DEV=""
for a in "$@"; do [ "$a" = "--dev" ] && DEV=1; done
[ "${PF_CHANNEL:-}" = "dev" ] && DEV=1
printf '\033[32mPerplexForge installer%s\033[0m\n' "${DEV:+  (development build from the dev branch)}"

[ "$(uname -s)" = "Darwin" ] || fail "this installer is for macOS. On Windows use install.ps1 (see the README)."

# -- 0. KiCad -----------------------------------------------------------------
KICAD_CFG="${KICAD_CONFIG_HOME:-$HOME/Library/Preferences/kicad}/10.0"
COMMON="$KICAD_CFG/kicad_common.json"
[ -f "$COMMON" ] || fail "KiCad 10 settings not found. Install KiCad 10 and start it once, then run this again."
if [ -z "${PF_IGNORE_RUNNING:-}" ] && pgrep -xq "kicad|pcbnew|eeschema"; then
    fail "KiCad is running. Quit KiCad (Cmd+Q), then run this again."
fi

# -- 1. Julia -----------------------------------------------------------------
step "Checking Julia"
find_julia() {
    local c
    for c in "$(command -v julia 2>/dev/null || true)" "$HOME/.juliaup/bin/julia" \
             /opt/homebrew/bin/julia /usr/local/bin/julia; do
        if [ -n "$c" ] && [ -x "$c" ]; then echo "$c"; return 0; fi
    done
    return 1
}
JULIA="$(find_julia || true)"
if [ -z "$JULIA" ]; then
    info "Julia not found: installing it with juliaup..."
    curl -fsSL https://install.julialang.org | sh -s -- --yes \
        || fail "Julia could not be installed automatically. Install it from https://julialang.org/install/ and run this again."
    JULIA="$(find_julia || true)"
    [ -n "$JULIA" ] || fail "Julia was installed but not found. Open a new Terminal window and run this again."
fi
if [ "$("$JULIA" --startup-file=no -e 'print(VERSION >= v"1.12")' </dev/null)" != "true" ]; then
    info "Julia is older than 1.12: updating with juliaup..."
    JULIAUP="$(command -v juliaup || echo "$HOME/.juliaup/bin/juliaup")"
    [ -x "$JULIAUP" ] || fail "Julia 1.12 or newer is required. Update it from https://julialang.org/install/ and run this again."
    "$JULIAUP" add release </dev/null && "$JULIAUP" default release </dev/null
fi
info "Julia $("$JULIA" --startup-file=no -e 'print(VERSION)' </dev/null)"

# -- 2. Download --------------------------------------------------------------
TMP="$(mktemp -d "${TMPDIR:-/tmp}/perplexforge.XXXXXX")"
trap 'rm -rf "$TMP"' EXIT
if [ -n "$DEV" ]; then
    step "Downloading the latest development build (dev branch)"
    # download first, then parse (piping curl into `grep -m1` can kill curl with SIGPIPE under pipefail)
    API="$(curl -fsSL "https://api.github.com/repos/$OWNER/$REPO/commits/dev")" \
        || fail "could not reach GitHub. Check your internet connection and run this again."
    SHA="$(printf '%s\n' "$API" | sed -nE 's/.*"sha": *"([0-9a-f]{40})".*/\1/p' | head -1)"
    [ ${#SHA} -ge 7 ] || fail "could not find the dev branch on GitHub."
    curl -fsSL -o "$TMP/dev.zip" "https://github.com/$OWNER/$REPO/archive/$SHA.zip" \
        || fail "downloading the dev branch failed. Check your internet connection and run this again."
    unzip -q "$TMP/dev.zip" -d "$TMP/src"
    SRC="$(find "$TMP/src" -mindepth 1 -maxdepth 1 -type d | head -1)"
    # lay it out like a release package: plugins/ = the KiCad plugin, plugins/julia/ = the Julia project
    mkdir -p "$TMP/pkg/plugins/julia/assets"
    cp -R "$SRC/kicad_plugin/." "$TMP/pkg/plugins/"
    cp "$SRC/Project.toml" "$SRC/LICENSE" "$TMP/pkg/plugins/julia/"
    cp -R "$SRC/src" "$SRC/bin" "$TMP/pkg/plugins/julia/"
    for d in icons macos; do [ -d "$SRC/assets/$d" ] && cp -R "$SRC/assets/$d" "$TMP/pkg/plugins/julia/assets/"; done
    # name the build after the last release plus a letter per commit since: v0.2.0a, v0.2.0b, …
    TAG=""
    REL_URL="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$OWNER/$REPO/releases/latest" || true)"
    REL="${REL_URL##*/}"
    if [ "${REL#v}" != "$REL" ]; then
        CMP="$(curl -fsSL "https://api.github.com/repos/$OWNER/$REPO/compare/$REL...$SHA" || true)"
        N="$(printf '%s\n' "$CMP" | sed -nE 's/.*"ahead_by": *([0-9]+).*/\1/p' | head -1)"
        if [ -n "$N" ]; then
            L=""
            while [ "$N" -gt 0 ]; do
                N=$((N - 1)); L="$(printf "\\$(printf '%03o' $((97 + N % 26)))")$L"; N=$((N / 26))
            done
            TAG="$REL$L"
        fi
    fi
    if [ -z "$TAG" ]; then
        TAG="v$(sed -nE 's/^version = "(.*)"/\1/p' "$TMP/pkg/plugins/julia/Project.toml" | head -1)-dev"
    fi
    printf '%s %s' "$TAG" "${SHA:0:7}" > "$TMP/pkg/plugins/julia/DEV_VERSION"
    info "$TAG (commit ${SHA:0:7})"
else
    step "Downloading the latest PerplexForge release"
    # github.com/<owner>/<repo>/releases/latest redirects to .../releases/tag/vX.Y.Z
    LATEST_URL="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$OWNER/$REPO/releases/latest")" \
        || fail "could not reach GitHub. Check your internet connection and run this again."
    TAG="${LATEST_URL##*/}"
    case "$TAG" in v[0-9]*) ;; *) fail "No release found on GitHub." ;; esac
    ZIP_NAME="PerplexForge-${TAG#v}.zip"
    curl -fsSL -o "$TMP/$ZIP_NAME" "https://github.com/$OWNER/$REPO/releases/download/$TAG/$ZIP_NAME" \
        || fail "downloading $ZIP_NAME failed. Check your internet connection and run this again."
    unzip -q "$TMP/$ZIP_NAME" -d "$TMP/pkg"
    info "$TAG  ($(( $(wc -c < "$TMP/$ZIP_NAME") / 1024 )) KB)"
fi

# -- 3. Install into KiCad's plugin folder ------------------------------------
step "Installing into KiCad"
PLUGINS="${KICAD_DOCUMENTS_HOME:-$HOME/Documents/KiCad}/10.0/plugins"
DEST="$PLUGINS/perplexforge"
mkdir -p "$PLUGINS"
if [ -L "$DEST" ]; then rm "$DEST"            # a dev link: remove the link only
elif [ -e "$DEST" ]; then rm -rf "$DEST"; fi
cp -R "$TMP/pkg/plugins" "$DEST"
info "$DEST"

# -- 4. KiCad API -------------------------------------------------------------
step "Enabling the KiCad API"
if grep -Eq '"enable_server"[[:space:]]*:[[:space:]]*true' "$COMMON"; then
    info "already on"
else
    cp "$COMMON" "$COMMON.bak"
    # false -> true; or add it to an existing "api" section; or add an "api" section.
    perl -0777 -i -pe '
        s/("enable_server"\s*:\s*)false/${1}true/ and next;
        s/("api"\s*:\s*\{)\s*\}/$1 "enable_server": true }/ and next;
        s/("api"\s*:\s*\{)/$1\n    "enable_server": true,/ and next;
        s/^\{/{\n  "api": { "enable_server": true },/;
    ' "$COMMON"
    grep -Eq '"enable_server"[[:space:]]*:[[:space:]]*true' "$COMMON" \
        || fail "could not turn on the KiCad API. Turn it on in KiCad: Preferences > Plugins > Enable KiCad API."
    info "on (previous settings saved as kicad_common.json.bak)"
fi

# -- 5. Julia packages --------------------------------------------------------
step "Installing PerplexForge's Julia packages (several minutes, once)"
# compile only what PerplexForge loads, not every package in the environment
JULIA_PKG_PRECOMPILE_AUTO=0 "$JULIA" --startup-file=no --project="$DEST/julia" -e 'using Pkg; Pkg.instantiate(); @eval using PerplexForge' </dev/null \
    || fail "Installing the Julia packages failed (see above). Check your internet connection and run this again."

printf '\n\033[32mPerplexForge %s is installed.\033[0m\n' "$TAG"
echo "Open a board in KiCad's PCB Editor and click the PerplexForge button on the toolbar."
echo "(The first click lets KiCad set up the plugin's Python environment; it needs internet once.)"
echo "If the button is missing: PCB Editor > Preferences > Plugins, and make sure PerplexForge is shown."
}
