"""KiCad IPC plugin action: open the current board in the PerplexForge workbench.

KiCad runs this without a console, so everything is logged to
perplexforge_plugin.log next to this file. The board is never modified; the
workbench reads the last saved .kicad_pcb from disk.

Where the Julia project is found (first match):
  PERPLEXFORGE_HOME env var       development setups (e.g. a sandbox launcher)
  <this folder>/julia             installed add-on package
  <this folder>/..                running from a source checkout (kicad_plugin/ in the repo)

Optional: PERPLEXFORGE_JULIA = path to the julia executable (default: julia on PATH, then
the places the Julia installers use).

Windows: the workbench runs in a new console window.
macOS:   the workbench runs in a new Terminal window, so first-run setup progress and any
         errors are visible. Apps started from the Dock don't get your shell's PATH, which is
         why Julia is also looked for in ~/.juliaup/bin, Homebrew and /Applications.
"""

import datetime
import glob
import os
import shlex
import shutil
import subprocess
import sys
import tempfile
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
LOG_PATH = os.path.join(HERE, "perplexforge_plugin.log")
IS_MAC = sys.platform == "darwin"
IS_WINDOWS = sys.platform == "win32"


def log(msg):
    stamp = datetime.datetime.now().strftime("%Y-%m-%d %H:%M:%S")
    try:
        with open(LOG_PATH, "a", encoding="utf-8") as f:
            f.write(f"[{stamp}] {msg}\n")
    except OSError:
        pass


def find_board_path():
    from kipy import KiCad

    kicad = KiCad()
    board = kicad.get_board()
    name = board.name
    if os.path.isabs(name):
        return os.path.normpath(name)
    project_dir = board.get_project().path
    return os.path.normpath(os.path.join(project_dir, name))


def find_perplexforge_home():
    candidates = []
    env = os.environ.get("PERPLEXFORGE_HOME")
    if env:
        candidates.append(env)
    candidates.append(os.path.join(HERE, "julia"))                       # installed package
    candidates.append(os.path.join(os.path.realpath(HERE), os.pardir))   # repo checkout / link
    for c in candidates:
        c = os.path.normpath(c)
        if os.path.isfile(os.path.join(c, "bin", "launch.jl")):
            return c
    raise FileNotFoundError("PerplexForge project not found. Tried: " + ", ".join(candidates))


def julia_candidates():
    """Places the Julia installers put julia, for when it isn't on KiCad's PATH."""
    home = os.path.expanduser("~")
    if IS_WINDOWS:
        return [os.path.join(os.environ.get("LOCALAPPDATA", ""), "Microsoft", "WindowsApps", "julia.exe")]
    found = [os.path.join(home, ".juliaup", "bin", "julia"),   # juliaup (the official installer)
             "/opt/homebrew/bin/julia",                        # Homebrew, Apple silicon
             "/usr/local/bin/julia"]                           # Homebrew, Intel
    if IS_MAC:                                                 # the Julia-1.x.app download
        apps = glob.glob("/Applications/Julia-*.app/Contents/Resources/julia/bin/julia")
        apps += glob.glob(os.path.join(home, "Applications", "Julia-*.app", "Contents", "Resources", "julia", "bin", "julia"))
        found += sorted(apps, reverse=True)
    return found


def find_julia():
    env = os.environ.get("PERPLEXFORGE_JULIA")
    if env and os.path.isfile(env):
        return env
    found = shutil.which("julia")
    if found:
        return found
    for c in julia_candidates():
        if os.path.exists(c):
            return c
    exe = "julia.exe" if IS_WINDOWS else "julia"
    raise FileNotFoundError(
        "Julia was not found.\n\nPerplexForge runs on Julia. Install it from https://julialang.org/install/ "
        "(the 'juliaup' installer), then click the PerplexForge button again.\n\n"
        f"If Julia is installed in an unusual place, set the PERPLEXFORGE_JULIA environment variable to {exe}.")


def show_error(msg):
    """KiCad runs this script without a console: show problems in a message box."""
    try:
        if IS_WINDOWS:
            import ctypes
            ctypes.windll.user32.MessageBoxW(None, msg, "PerplexForge", 0x30)
        elif IS_MAC:
            subprocess.run(["osascript",
                            "-e", "on run argv",
                            "-e", 'display dialog (item 1 of argv) with title "PerplexForge" '
                                  'buttons {"OK"} default button 1 with icon caution',
                            "-e", "end run", msg], timeout=600)
    except Exception:
        pass


def mac_terminal_script(cmd, cwd):
    """A self-deleting .command script that runs `cmd` in `cwd`; Terminal opens these."""
    return ("#!/bin/bash\n"
            'rm -f "$0"\n'
            f"cd {shlex.quote(cwd)} || exit 1\n"
            "clear\n"
            f"exec {shlex.join(cmd)}\n")


def launch_in_mac_terminal(cmd, cwd):
    fd, path = tempfile.mkstemp(prefix="perplexforge-", suffix=".command")
    with os.fdopen(fd, "w", encoding="utf-8") as f:
        f.write(mac_terminal_script(cmd, cwd))
    os.chmod(path, 0o755)
    subprocess.run(["open", "-a", "Terminal", path], check=True)


def main():
    log("---- PerplexForge action started (python %s, %s)" % (sys.version.split()[0], sys.platform))
    board_path = find_board_path()
    log("Board: " + board_path)
    if not os.path.isfile(board_path):
        raise FileNotFoundError("Board file not on disk (save it in KiCad first): " + board_path)

    home = find_perplexforge_home()
    julia = find_julia()
    cmd = [julia, "--project=" + home, os.path.join(home, "bin", "launch.jl"), board_path]
    cwd = os.path.dirname(board_path)

    if IS_MAC:
        log("Launching in Terminal: " + shlex.join(cmd))
        launch_in_mac_terminal(cmd, cwd)
    else:
        log("Launching: " + subprocess.list2cmdline(cmd))
        flags = getattr(subprocess, "CREATE_NEW_CONSOLE", 0)
        subprocess.Popen(cmd, cwd=cwd, creationflags=flags, close_fds=True)
    log("Workbench process started.")


if __name__ == "__main__":
    try:
        main()
    except Exception as err:
        log("ERROR:\n" + traceback.format_exc())
        show_error(str(err) + "\n\nDetails: " + LOG_PATH)
        sys.exit(1)
