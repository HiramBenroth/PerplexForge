"""Build the KiCad Plugin and Content Manager (PCM) package and repository files.

    python tools/build_pcm.py --owner <github-user> [--version 0.1.0] [--status testing]

Produces
  dist/PerplexForge-<version>.zip   the add-on package (attach it to the GitHub release v<version>)
  pcm/packages.json                 package list with download URL, sha256 and sizes
  pcm/repository.json               the URL users add in KiCad (Manage repositories)

Package layout (per KiCad's add-on docs):
  metadata.json
  resources/icon.png                64x64
  plugins/                          plugin.json + launcher (KiCad IPC plugin)
  plugins/julia/                    the Julia project (Project.toml, src, bin, assets)

Manifest.toml is deliberately not packaged: on first run Julia resolves the packages for the
user's own Julia version (see bin/launch.jl).
"""

import argparse
import datetime
import hashlib
import io
import json
import os
import re
import zipfile

ROOT = os.path.normpath(os.path.join(os.path.dirname(os.path.abspath(__file__)), os.pardir))
SKIP_NAMES = {"perplexforge_plugin.log", "__pycache__", "Manifest.toml"}

DESCRIPTION = "Power-integrity workbench for KiCad: DC IR-drop and AC PDN-impedance on your board in 3D (needs Julia)."
DESCRIPTION_FULL = """PerplexForge opens the current board in a 3D power-integrity workbench.

- Classify nets (power / ground / digital) and model components as lumped elements: VRMs, sinks, R, L, ferrite, 0 ohm, capacitors.
- DC analysis: voltage, IR drop and current density maps on every copper layer, sink voltages, via currents and copper loss.
- AC analysis: PDN impedance |Z(f)| at every sink with target-impedance checks, plus 3D maps of the noise voltage at any frequency.

Requirements: KiCad 10 with the KiCad API enabled (Preferences > Plugins), and Julia 1.12 or newer (https://julialang.org/install/).
The first launch installs PerplexForge's Julia packages, which takes several minutes once.
Your board is never modified; the simulation setup is saved next to it as <board>.perplex.json."""


def project_version():
    with open(os.path.join(ROOT, "Project.toml"), encoding="utf-8") as f:
        m = re.search(r'^version\s*=\s*"([^"]+)"', f.read(), re.M)
    return m.group(1) if m else "0.1.0"


def add_tree(z, src, dest):
    for dirpath, dirnames, filenames in os.walk(src):
        dirnames[:] = sorted(d for d in dirnames if d not in SKIP_NAMES)
        for fn in sorted(filenames):
            if fn in SKIP_NAMES:
                continue
            full = os.path.join(dirpath, fn)
            rel = os.path.relpath(full, src).replace(os.sep, "/")
            z.write(full, f"{dest}/{rel}")


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--owner", required=True, help="GitHub user or organisation that hosts the repo")
    ap.add_argument("--repo", default="PerplexForge")
    ap.add_argument("--version", default=project_version())
    ap.add_argument("--status", default="testing", choices=["stable", "testing", "development", "deprecated"])
    ap.add_argument("--kicad", default="10.0", help="minimum KiCad version (major.minor)")
    args = ap.parse_args()

    owner, repo, version = args.owner, args.repo, args.version
    home = f"https://github.com/{owner}/{repo}"
    meta = {
        "$schema": "https://go.kicad.org/pcm/schemas/v1",
        "name": "PerplexForge",
        "description": DESCRIPTION,
        "description_full": DESCRIPTION_FULL,
        "identifier": f"com.github.{owner.lower()}.perplexforge",
        "type": "plugin",
        "author": {"name": owner, "contact": {"github": f"https://github.com/{owner}"}},
        "license": "MIT",
        "resources": {"homepage": home},
        "versions": [{"version": version, "status": args.status, "kicad_version": args.kicad,
                      "runtime": "ipc", "platforms": ["windows", "macos"]}],
    }

    # ── the package zip
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        z.writestr("metadata.json", json.dumps(meta, indent=2, ensure_ascii=False))
        z.write(os.path.join(ROOT, "assets", "icons", "icon_64.png"), "resources/icon.png")
        add_tree(z, os.path.join(ROOT, "kicad_plugin"), "plugins")
        z.write(os.path.join(ROOT, "Project.toml"), "plugins/julia/Project.toml")
        z.write(os.path.join(ROOT, "LICENSE"), "plugins/julia/LICENSE")
        for sub in ("src", "bin"):
            add_tree(z, os.path.join(ROOT, sub), f"plugins/julia/{sub}")
        add_tree(z, os.path.join(ROOT, "assets", "icons"), "plugins/julia/assets/icons")
        install_size = sum(i.file_size for i in z.infolist())
    data = buf.getvalue()
    os.makedirs(os.path.join(ROOT, "dist"), exist_ok=True)
    zip_name = f"PerplexForge-{version}.zip"
    with open(os.path.join(ROOT, "dist", zip_name), "wb") as f:
        f.write(data)

    # ── repository files (served from the repo's main branch)
    raw = f"https://raw.githubusercontent.com/{owner}/{repo}/main/pcm"
    ver = dict(meta["versions"][0])
    ver.update({"download_url": f"{home}/releases/download/v{version}/{zip_name}",
                "download_sha256": sha256(data), "download_size": len(data), "install_size": install_size})
    pkg = dict(meta, versions=[ver])
    pkg.pop("$schema")
    packages = json.dumps({"packages": [pkg]}, indent=2, ensure_ascii=False).encode("utf-8")
    now = datetime.datetime.now(datetime.timezone.utc)
    repository = {
        "$schema": "https://go.kicad.org/pcm/schemas/v1#/definitions/Repository",
        "name": "PerplexForge add-on repository",
        "maintainer": {"name": owner, "contact": {"github": f"https://github.com/{owner}"}},
        "packages": {"url": f"{raw}/packages.json", "sha256": sha256(packages),
                     "update_time_utc": now.strftime("%Y-%m-%d %H:%M:%S"), "update_timestamp": int(now.timestamp())},
    }
    os.makedirs(os.path.join(ROOT, "pcm"), exist_ok=True)
    with open(os.path.join(ROOT, "pcm", "packages.json"), "wb") as f:
        f.write(packages)
    with open(os.path.join(ROOT, "pcm", "repository.json"), "w", encoding="utf-8") as f:
        json.dump(repository, f, indent=2)

    print(f"package    dist/{zip_name}  ({len(data) / 1024:.0f} KB, sha256 {sha256(data)[:12]}…)")
    print(f"repository {raw}/repository.json")
    print(f"release    upload dist/{zip_name} to release v{version}")


if __name__ == "__main__":
    main()
