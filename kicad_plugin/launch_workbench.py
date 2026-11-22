"""KiCad IPC plugin action: open the current board in the PerplexForge workbench.

KiCad runs this with pythonw (no console), so everything is logged to
perplexforge_plugin.log next to this file. The board is never modified; the
workbench reads the last saved .kicad_pcb from disk.

Where the Julia project is found (first match):
  PERPLEXFORGE_HOME env var       development setups (e.g. a sandbox launcher)
  <this folder>/julia             installed add-on package
  <this folder>/..                running from a source checkout (kicad_plugin/ in the repo)

Optional: PERPLEXFORGE_JULIA = path to the julia executable (default: julia on PATH).
"""

import datetime
import os
import shutil
import subprocess
import sys
import traceback

HERE = os.path.dirname(os.path.abspath(__file__))
LOG_PATH = os.path.join(HERE, "perplexforge_plugin.log")


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
    candidates.append(os.path.join(os.path.realpath(HERE), os.pardir))   # repo checkout / junction
    for c in candidates:
        c = os.path.normpath(c)
        if os.path.isfile(os.path.join(c, "bin", "launch.jl")):
            return c
    raise FileNotFoundError("PerplexForge project not found. Tried: " + ", ".join(candidates))


def find_julia():
    env = os.environ.get("PERPLEXFORGE_JULIA")
    if env and os.path.isfile(env):
        return env
    found = shutil.which("julia")
    if found:
        return found
    alias = os.path.join(os.environ.get("LOCALAPPDATA", ""), "Microsoft", "WindowsApps", "julia.exe")
    if os.path.exists(alias):
        return alias
    raise FileNotFoundError(
        "Julia was not found.\n\nPerplexForge runs on Julia. Install it from https://julialang.org/install/ "
        "(the 'juliaup' installer), then click the PerplexForge button again.\n\n"
        "If Julia is installed in an unusual place, set the PERPLEXFORGE_JULIA environment variable to julia.exe.")


def show_error(msg):
    """KiCad runs this script without a console: show problems in a message box (Windows)."""
    try:
        import ctypes
        ctypes.windll.user32.MessageBoxW(None, msg, "PerplexForge", 0x30)
    except Exception:
        pass


def main():
    log("---- PerplexForge action started (python %s)" % sys.version.split()[0])
    board_path = find_board_path()
    log("Board: " + board_path)
    if not os.path.isfile(board_path):
        raise FileNotFoundError("Board file not on disk (save it in KiCad first): " + board_path)

    home = find_perplexforge_home()
    julia = find_julia()
    cmd = [julia, "--project=" + home, os.path.join(home, "bin", "launch.jl"), board_path]
    log("Launching: " + subprocess.list2cmdline(cmd))

    flags = getattr(subprocess, "CREATE_NEW_CONSOLE", 0)
    subprocess.Popen(cmd, cwd=os.path.dirname(board_path), creationflags=flags, close_fds=True)
    log("Workbench process started.")


if __name__ == "__main__":
    try:
        main()
    except Exception as err:
        log("ERROR:\n" + traceback.format_exc())
        show_error(str(err) + "\n\nDetails: " + LOG_PATH)
        sys.exit(1)
