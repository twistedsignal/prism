"""Install a stable, version-independent CLI wrapper outside the swapped backend."""
import os
import shlex
import shutil
import subprocess
import sys
from pathlib import Path

import runtime

MARKER = "Prism managed CLI launcher"


def launcher_path():
    if sys.platform == "win32":
        return Path(os.environ.get("LOCALAPPDATA", Path.home() / "AppData" / "Local")) / "Prism" / "bin" / "prism.cmd"
    return Path.home() / ".local" / "bin" / "prism"


def batch_line(parts):
    """cmd.exe reads batch files in the OEM code page and expands %, so escape % and
    refer to profile folders through their variables to keep user names out of the file."""
    line = subprocess.list2cmdline(parts).replace("%", "%%")
    for name in ("LOCALAPPDATA", "APPDATA", "USERPROFILE"):
        folder = os.environ.get(name)
        if folder:
            line = line.replace(folder.replace("%", "%%"), f"%{name}%")
    return line


def install():
    script = Path(__file__).with_name("cli.py").resolve()
    value = runtime.settings()
    command = list(value.get("pythonCommand") or [sys.executable])
    # Console commands need python.exe, even when the background server uses pythonw.exe.
    command = [str(Path(part).with_name("python.exe")) if Path(part).name.lower() == "pythonw.exe" else part for part in command]
    path = launcher_path()
    if path.exists() and MARKER not in path.read_text(encoding="utf-8", errors="replace"):
        print(f"[prism] CLI launcher conflict at {path}; existing command left in place")
        return discovery()
    if sys.platform == "win32":
        content = f'@echo off\nrem {MARKER}\n' + batch_line(command + [str(script)]) + ' %*\n'
        try:
            data = content.encode("oem")
        except (LookupError, UnicodeEncodeError):  # no OEM codec off Windows, or a name it can't hold
            data = content.encode("utf-8")
    else:
        content = f'#!/bin/sh\n# {MARKER}\nexec ' + shlex.join(command + [str(script)]) + ' "$@"\n'
        data = content.encode("utf-8")
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists() or path.read_bytes() != data:
        path.write_bytes(data)
    if sys.platform != "win32":
        path.chmod(0o755)
    return discovery()


def discovery():
    path = launcher_path()
    found = shutil.which("prism")
    on_path = found is not None and Path(found).resolve() == path.resolve()
    return {"cliPath": str(path), "cliOnPath": on_path,
            "cliHint": "prism is on PATH" if on_path else f"Use {path}; add {path.parent} to PATH and open a new terminal"}


def uninstall():
    path = launcher_path()
    if path.is_file() and MARKER in path.read_text(encoding="utf-8", errors="replace"):
        path.unlink()
