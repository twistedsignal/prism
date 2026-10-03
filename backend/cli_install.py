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
        content = f'@echo off\nrem {MARKER}\n' + subprocess.list2cmdline(command + [str(script)]) + ' %*\n'
    else:
        content = f'#!/bin/sh\n# {MARKER}\nexec ' + shlex.join(command + [str(script)]) + ' "$@"\n'
    path.parent.mkdir(parents=True, exist_ok=True)
    if not path.exists() or path.read_text(encoding="utf-8", errors="replace") != content:
        path.write_text(content, encoding="utf-8")
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
