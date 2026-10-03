"""Remember Blender's Python and executable without loading bpy in the server."""

import os
import shutil
import subprocess
import sys
from pathlib import Path

import config


def settings():
    value = config.read_json(config.config_dir() / "runtime.json", {})
    return value if isinstance(value, dict) else {}


def configure(blender=None):
    bpy = sys.modules.get("bpy")
    python = Path(sys.executable)
    if not python.is_file() or "python" not in python.name.lower():
        candidates = list((Path(sys.prefix) / "bin").glob("python3*"))
        candidates += [Path(sys.prefix) / "bin" / "python.exe"]
        python = next((path for path in candidates if path.is_file()), None)
        if python is None:
            raise RuntimeError("Could not find Blender's Python executable. Reinstall Blender.")
    server_python = python
    if sys.platform == "win32" and python.with_name("pythonw.exe").is_file():
        server_python = python.with_name("pythonw.exe")
    binary = blender or (bpy.app.binary_path if bpy else shutil.which("blender"))
    if not binary:
        raise RuntimeError("Could not find Blender. Pass --blender with its executable path.")
    binary = str(Path(shutil.which(binary) or binary).resolve())
    if Path(binary).name.lower() == "blender-launcher.exe":
        binary = str(Path(binary).with_name("blender.exe"))
    python_command = [str(server_python)]
    if os.environ.get("FLATPAK_ID"):
        python_command = [
            "flatpak", "run", "--filesystem=home", f"--command={server_python}",
            os.environ["FLATPAK_ID"],
        ]
    value = {
        "pythonCommand": python_command,
        "python": str(server_python),
        "blenderCommand": [binary],
        "blenderVersion": bpy.app.version_string if bpy else "",
    }
    config.write_json(config.config_dir() / "runtime.json", value)
    return value


def blender_command():
    value = settings().get("blenderCommand")
    if value:
        return value
    binary = shutil.which("blender")
    if binary:
        return [binary]
    raise RuntimeError("Blender is not configured. Re-run the Prism installer.")


def serve_command(log=None):
    value = settings()
    command = value.get("pythonCommand", [sys.executable]) + [
        str(Path(__file__).with_name("main.py").resolve()), "serve",
    ]
    if log:
        command += ["--log", str(log)]
    return command


def restart_windows_task():
    # Let the current task exit before /Run, since its policy ignores overlaps.
    python = settings().get("python", sys.executable)
    subprocess.Popen([
        python, "-c",
        "import time, subprocess; time.sleep(2); "
        "subprocess.run(['schtasks', '/Run', '/TN', 'Prism'], check=True)",
    ], creationflags=subprocess.CREATE_NO_WINDOW, close_fds=True)
