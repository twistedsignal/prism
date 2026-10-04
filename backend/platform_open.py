"""Open folders in the user's file manager, show a native folder picker and copy to the clipboard."""

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


class ClipboardError(RuntimeError):
    pass


def clipboard_command(env):
    """The command that reads text on stdin into the system clipboard, and its encoding."""
    if sys.platform == "win32":
        # clip reads UTF-16 with a byte order mark as Unicode.
        return ["clip"], "utf-16"
    if sys.platform == "darwin":
        return ["pbcopy"], "utf-8"
    if env.get("WAYLAND_DISPLAY") and shutil.which("wl-copy"):
        return ["wl-copy"], "utf-8"
    if shutil.which("xclip"):
        return ["xclip", "-selection", "clipboard"], "utf-8"
    if shutil.which("xsel"):
        return ["xsel", "--clipboard", "--input"], "utf-8"
    raise ClipboardError("No clipboard tool found. Install wl-clipboard (Wayland) or xclip (X11).")


def copy_text(text):
    env = session_environment()
    if sys.platform == "darwin":
        env.setdefault("LC_CTYPE", "UTF-8")  # pbcopy reads ASCII without a UTF-8 locale.
    command, encoding = clipboard_command(env)
    try:
        # wl-copy and xclip keep running to serve the clipboard, so never wait on their output.
        result = subprocess.run(command, input=text.encode(encoding), stdout=subprocess.DEVNULL,
                                stderr=subprocess.DEVNULL, timeout=10, env=env)
    except (OSError, subprocess.TimeoutExpired) as error:
        raise ClipboardError(f"Could not run {command[0]}: {error}") from error
    if result.returncode != 0:
        raise ClipboardError(f"{command[0]} exited with code {result.returncode}")
