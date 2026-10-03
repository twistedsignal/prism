"""Register the backend to start at login: systemd (Linux), launchd (macOS), Task Scheduler (Windows)."""

import os
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path
from xml.sax.saxutils import escape

import config

SERVICE_NAME = "prism"
LAUNCH_AGENT = "dev.ivadsiuls.prism"
# Label used by v0.1.0; removed on install and uninstall.
LEGACY_LAUNCH_AGENTS = ("com.ivadsiuls.prism",)
TASK_NAME = "Prism"


def blender_command(blender=None):
    """The command that launches this Blender, including when it runs as a flatpak."""
    if blender:
        return [blender]
    if os.environ.get("FLATPAK_ID"):
        return ["flatpak", "run", "--filesystem=home", os.environ["FLATPAK_ID"]]
    import bpy

    path = Path(bpy.app.binary_path)
    if sys.platform == "win32":
        # blender-launcher.exe runs Blender without opening a console window.
        launcher = path.with_name("blender-launcher.exe")
        if launcher.exists():
            return [str(launcher)]
    return [str(path)]


def serve_command(blender=None, log=None):
    main = Path(__file__).resolve().with_name("main.py")
    command = blender_command(blender) + [
        "--background", "--factory-startup", "--python-exit-code", "1", "--python", str(main), "--", "serve",
    ]
    if log:
        command += ["--log", str(log)]
    return command


def run(command, check=True):
    print("[prism]", " ".join(command))
    return subprocess.run(command, check=check, capture_output=True, text=True)


# ============================================================
# LINUX
# ============================================================

def systemd_unit_path():
    base = Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config")
    return base / "systemd" / "user" / f"{SERVICE_NAME}.service"


def install_linux(blender):
    command = " ".join(shlex.quote(part) for part in serve_command(blender))
    unit = systemd_unit_path()
    unit.parent.mkdir(parents=True, exist_ok=True)
    unit.write_text(
        "[Unit]\n"
        "Description=Prism Roblox Studio to Blender bridge\n"
        "After=default.target\n"
        "\n"
        "[Service]\n"
        f"ExecStart={command}\n"
        "Restart=on-failure\n"
        "RestartSec=3\n"
        "\n"
        "[Install]\n"
        "WantedBy=default.target\n"
    )
    run(["systemctl", "--user", "daemon-reload"])
    run(["systemctl", "--user", "enable", f"{SERVICE_NAME}.service"])
    run(["systemctl", "--user", "restart", f"{SERVICE_NAME}.service"])


def uninstall_linux():
    run(["systemctl", "--user", "disable", "--now", f"{SERVICE_NAME}.service"], check=False)
    systemd_unit_path().unlink(missing_ok=True)
    run(["systemctl", "--user", "daemon-reload"], check=False)


# ============================================================
# MACOS
# ============================================================

def launch_agent_path(label=LAUNCH_AGENT):
    return Path.home() / "Library" / "LaunchAgents" / f"{label}.plist"


def remove_legacy_launch_agents():
    for label in LEGACY_LAUNCH_AGENTS:
        plist = launch_agent_path(label)
        run(["launchctl", "bootout", f"gui/{os.getuid()}", str(plist)], check=False)
        plist.unlink(missing_ok=True)


def install_macos(blender):
    remove_legacy_launch_agents()
    log = Path.home() / "Library" / "Logs" / "Prism.log"
    log.parent.mkdir(parents=True, exist_ok=True)
    arguments = "\n".join(f"        <string>{escape(part)}</string>" for part in serve_command(blender))
    plist = launch_agent_path()
    plist.parent.mkdir(parents=True, exist_ok=True)
    plist.write_text(
        '<?xml version="1.0" encoding="UTF-8"?>\n'
        '<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">\n'
        '<plist version="1.0">\n'
        "<dict>\n"
        f"    <key>Label</key>\n    <string>{LAUNCH_AGENT}</string>\n"
        f"    <key>ProgramArguments</key>\n    <array>\n{arguments}\n    </array>\n"
        "    <key>RunAtLoad</key>\n    <true/>\n"
        "    <key>KeepAlive</key>\n    <dict>\n        <key>SuccessfulExit</key>\n        <false/>\n    </dict>\n"
        f"    <key>StandardOutPath</key>\n    <string>{escape(str(log))}</string>\n"
        f"    <key>StandardErrorPath</key>\n    <string>{escape(str(log))}</string>\n"
        "</dict>\n"
        "</plist>\n"
    )
    domain = f"gui/{os.getuid()}"
    run(["launchctl", "bootout", domain, str(plist)], check=False)
    run(["launchctl", "bootstrap", domain, str(plist)])


def uninstall_macos():
    remove_legacy_launch_agents()
    plist = launch_agent_path()
    run(["launchctl", "bootout", f"gui/{os.getuid()}", str(plist)], check=False)
    plist.unlink(missing_ok=True)


# ============================================================
# WINDOWS
# ============================================================

def install_windows(blender):
    log = Path(os.environ.get("LOCALAPPDATA", Path.home())) / "Prism" / "prism.log"
    log.parent.mkdir(parents=True, exist_ok=True)
    command = serve_command(blender, log)
    arguments = subprocess.list2cmdline(command[1:])
    user = os.environ.get("USERDOMAIN", "") + "\\" + os.environ.get("USERNAME", "")
    task = f"""<?xml version="1.0" encoding="UTF-16"?>
<Task version="1.2" xmlns="http://schemas.microsoft.com/windows/2004/02/mit/task">
  <RegistrationInfo><Description>Prism Roblox Studio to Blender bridge</Description></RegistrationInfo>
  <Triggers><LogonTrigger><Enabled>true</Enabled><UserId>{escape(user)}</UserId></LogonTrigger></Triggers>
  <Principals><Principal id="Author"><UserId>{escape(user)}</UserId><LogonType>InteractiveToken</LogonType><RunLevel>LeastPrivilege</RunLevel></Principal></Principals>
  <Settings>
    <MultipleInstancesPolicy>IgnoreNew</MultipleInstancesPolicy>
    <DisallowStartIfOnBatteries>false</DisallowStartIfOnBatteries>
    <StopIfGoingOnBatteries>false</StopIfGoingOnBatteries>
    <ExecutionTimeLimit>PT0S</ExecutionTimeLimit>
    <RestartOnFailure><Interval>PT1M</Interval><Count>999</Count></RestartOnFailure>
    <Hidden>true</Hidden>
  </Settings>
  <Actions Context="Author"><Exec><Command>{escape(command[0])}</Command><Arguments>{escape(arguments)}</Arguments></Exec></Actions>
</Task>
"""
    with tempfile.NamedTemporaryFile("w", suffix=".xml", delete=False, encoding="utf-16") as handle:
        handle.write(task)
        path = handle.name
    try:
        run(["schtasks", "/End", "/TN", TASK_NAME], check=False)
        run(["schtasks", "/Create", "/TN", TASK_NAME, "/XML", path, "/F"])
        run(["schtasks", "/Run", "/TN", TASK_NAME])
    finally:
        os.unlink(path)


def uninstall_windows():
    run(["schtasks", "/End", "/TN", TASK_NAME], check=False)
    run(["schtasks", "/Delete", "/TN", TASK_NAME, "/F"], check=False)


# ============================================================
# ENTRY
# ============================================================

def install(blender=None, raven=None, creator=None):
    store = config.Store()
    changes = {"blenderPath": " ".join(blender_command(blender))}
    if raven:
        changes["ravenPath"] = raven
    if creator:
        current = store.get_config()
        if not current["defaultCreator"]:
            changes["defaultCreator"] = creator
    store.update_config(changes)
    if sys.platform == "win32":
        install_windows(blender)
    elif sys.platform == "darwin":
        install_macos(blender)
    else:
        install_linux(blender)
    print("[prism] Startup entry installed")


def uninstall():
    if sys.platform == "win32":
        uninstall_windows()
    elif sys.platform == "darwin":
        uninstall_macos()
    else:
        uninstall_linux()
    print("[prism] Startup entry removed")
