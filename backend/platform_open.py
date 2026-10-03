"""Open folders in the user's file manager and show a native folder picker."""

import os
import shutil
import subprocess
import sys
from pathlib import Path


SESSION_VARIABLES = ("DISPLAY", "WAYLAND_DISPLAY", "DBUS_SESSION_BUS_ADDRESS", "XDG_RUNTIME_DIR",
                     "XDG_CURRENT_DESKTOP", "XDG_SESSION_TYPE", "XAUTHORITY")


def session_environment():
    """Linux services can start before the desktop exports its display variables;
    read the current ones from the systemd user manager instead."""
    env = dict(os.environ)
    if sys.platform in ("win32", "darwin") or not shutil.which("systemctl"):
        return env
    try:
        result = subprocess.run(["systemctl", "--user", "show-environment"],
                                capture_output=True, text=True, timeout=5)
    except (OSError, subprocess.TimeoutExpired):
        return env
    for line in result.stdout.splitlines():
        key, _, value = line.partition("=")
        if key in SESSION_VARIABLES and value:
            env[key] = value
    return env


def open_folder(path):
    path = Path(path).expanduser()
    path.mkdir(parents=True, exist_ok=True)
    if sys.platform == "win32":
        os.startfile(str(path))  # noqa: S606 - opens Explorer on a local folder
    elif sys.platform == "darwin":
        subprocess.Popen(["open", str(path)])
    else:
        subprocess.Popen(["xdg-open", str(path)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                         env=session_environment())


def pick_folder(initial):
    """Ask the user for a folder. Returns a path, or None if cancelled or no picker exists."""
    initial = str(Path(initial).expanduser())
    if sys.platform == "win32":
        script = (
            "Add-Type -AssemblyName System.Windows.Forms;"
            "$d = New-Object System.Windows.Forms.FolderBrowserDialog;"
            "$d.Description = 'Choose where Prism saves icons';"
            f"$d.SelectedPath = '{initial.replace(chr(39), chr(39) * 2)}';"
            "if ($d.ShowDialog() -eq 'OK') { $d.SelectedPath }"
        )
        command = ["powershell", "-NoProfile", "-STA", "-Command", script]
    elif sys.platform == "darwin":
        command = ["osascript", "-e", 'POSIX path of (choose folder with prompt "Choose where Prism saves icons")']
    elif shutil.which("zenity"):
        command = ["zenity", "--file-selection", "--directory", "--title=Choose where Prism saves icons",
                   f"--filename={initial}/"]
    elif shutil.which("kdialog"):
        command = ["kdialog", "--getexistingdirectory", initial]
    else:
        return None
    try:
        result = subprocess.run(command, capture_output=True, text=True, timeout=600, env=session_environment())
    except (OSError, subprocess.TimeoutExpired):
        return None
    chosen = result.stdout.strip()
    return chosen if result.returncode == 0 and chosen else None
