"""Check GitHub for new Prism releases and update the installed backend and plugin in place."""

import json
import os
import re
import shutil
import ssl
import subprocess
import sys
import tarfile
import tempfile
import threading
import time
import urllib.error
import urllib.request
import zipfile
from pathlib import Path

import config

REPO = "twistedsignal/prism"
LATEST_URL = f"https://api.github.com/repos/{REPO}/releases/latest"
DOWNLOAD_URL = f"https://github.com/{REPO}/releases/download/v{{version}}/{{asset}}"
CHECK_INTERVAL = 60 * 60
RESTART_EXIT_CODE = 75
PLUGIN_FILE = "Prism.rbxm"


class UpdateError(RuntimeError):
    pass


def parse_version(value):
    match = re.match(r"^v?(\d+)\.(\d+)\.(\d+)", str(value or ""))
    return tuple(int(part) for part in match.groups()) if match else None


def backend_dir():
    return Path(__file__).resolve().parent


def install_dir():
    return backend_dir().parent


def is_source_checkout():
    """Never overwrite a development checkout with release files."""
    root = install_dir()
    return (root / "wally.toml").exists() or (root / ".git").exists()


# ============================================================
# DOWNLOADS
# ============================================================

def ssl_context():
    try:
        import certifi

        return ssl.create_default_context(cafile=certifi.where())
    except Exception:  # noqa: BLE001 - fall back to the system store
        return ssl.create_default_context()


def fetch(url, timeout=60):
    """Download bytes. Some Blender builds ship without CA certificates, so fall back to curl."""
    request = urllib.request.Request(url, headers={"User-Agent": "Prism", "Accept": "*/*"})
    try:
        with urllib.request.urlopen(request, timeout=timeout, context=ssl_context()) as response:
            return response.read()
    except urllib.error.HTTPError as error:
        raise UpdateError(f"GitHub returned HTTP {error.code} for {url}") from error
    except (urllib.error.URLError, ssl.SSLError, OSError) as error:
        curl = shutil.which("curl") or shutil.which("curl.exe")
        if curl is None:
            raise UpdateError(f"Could not reach GitHub: {error}") from error
        result = subprocess.run(
            [curl, "-fsSL", "--max-time", str(timeout), "-A", "Prism", url],
            capture_output=True, timeout=timeout + 10,
        )
        if result.returncode != 0:
            raise UpdateError(f"Could not download {url}") from error
        return result.stdout


# ============================================================
# CHECKING
# ============================================================

class Checker:
    """Caches the latest release so the plugin can poll freely without hitting GitHub's rate limit."""

    def __init__(self):
        self.lock = threading.Lock()
        self.checked_at = 0.0
        self.release = None
        self.error = None

    def latest(self, force=False):
        with self.lock:
            if force or time.time() - self.checked_at > CHECK_INTERVAL:
                try:
                    release = json.loads(fetch(LATEST_URL, timeout=20))
                    self.release = {
                        "version": str(release.get("tag_name", "")).lstrip("v"),
                        "notes": str(release.get("body") or "")[:2000],
                        "url": release.get("html_url") or f"https://github.com/{REPO}/releases",
                    }
                    self.error = None
                except (UpdateError, ValueError) as error:
                    self.error = str(error)
                self.checked_at = time.time()
            return self.release, self.error

    def status(self, plugin_version=None, force=False):
        current = config.version()
        release, error = self.latest(force)
        latest = release["version"] if release else None
        latest_tuple = parse_version(latest)
        installed = [parse_version(current), parse_version(plugin_version)]
        outdated = latest_tuple is not None and any(
            version is not None and version < latest_tuple for version in installed
        )
        return {
            "current": current,
            "plugin": plugin_version,
            "latest": latest,
            "available": outdated and not is_source_checkout(),
            "canUpdate": not is_source_checkout(),
            "notes": release["notes"] if release else "",
            "url": release["url"] if release else f"https://github.com/{REPO}/releases",
            "error": error,
        }


# ============================================================
# PLUGIN FOLDERS
# ============================================================

def plugin_dirs():
    """Studio Plugins folders: ones that already have Prism, else every Studio install found."""
    candidates = []
    if os.environ.get("PRISM_PLUGINS_DIR"):
        candidates.append(Path(os.environ["PRISM_PLUGINS_DIR"]))
    if sys.platform == "win32":
        local = os.environ.get("LOCALAPPDATA")
        if local:
            candidates.append(Path(local) / "Roblox" / "Plugins")
    elif sys.platform == "darwin":
        candidates.append(Path.home() / "Documents" / "Roblox" / "Plugins")
    else:
        data = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local" / "share")
        for root in (Path.home() / ".var/app/org.vinegarhq.Vinegar/data/vinegar", data / "vinegar"):
            candidates += [roblox / "Plugins" for roblox in root.glob("prefixes/*/drive_c/users/*/AppData/Local/Roblox")]
    with_prism = [path for path in candidates if (path / PLUGIN_FILE).exists()]
    return with_prism or [path for path in candidates if path.parent.is_dir()]


# ============================================================
# UPDATING
# ============================================================

def extract_backend(archive, destination):
    if archive.suffix == ".zip":
        with zipfile.ZipFile(archive) as bundle:
            for member in bundle.namelist():
                target = (destination / member).resolve()
                if not str(target).startswith(str(destination.resolve())):
                    raise UpdateError("The update archive contains unsafe paths")
            bundle.extractall(destination)
    else:
        with tarfile.open(archive) as bundle:
            try:
                bundle.extractall(destination, filter="data")
            except TypeError:
                # Pythons without extraction filters: check member paths ourselves.
                for member in bundle.getmembers():
                    target = (destination / member.name).resolve()
                    if not str(target).startswith(str(destination.resolve())) or member.issym() or member.islnk():
                        raise UpdateError("The update archive contains unsafe paths")
                bundle.extractall(destination)
    backend = destination / "backend"
    if not (backend / "main.py").exists():
        raise UpdateError("The update archive is missing the backend")
    return backend


def install(version):
    """Download a release, swap the backend directory and copy the plugin. Returns plugin paths."""
    if is_source_checkout():
        raise UpdateError("Prism is running from a source checkout; update it with git instead.")
    asset = "prism-backend.zip" if sys.platform == "win32" else "prism-backend.tar.gz"
    root = install_dir()
    with tempfile.TemporaryDirectory(prefix="prism-update-", dir=root) as staging:
        staging = Path(staging)
        archive = staging / asset
        archive.write_bytes(fetch(DOWNLOAD_URL.format(version=version, asset=asset), timeout=120))
        plugin = fetch(DOWNLOAD_URL.format(version=version, asset=PLUGIN_FILE), timeout=120)
        if len(plugin) < 1024:
            raise UpdateError("The downloaded plugin looks incomplete")

        new_backend = extract_backend(archive, staging / "extract")
        for cache in new_backend.rglob("__pycache__"):
            shutil.rmtree(cache, ignore_errors=True)
        (new_backend / "VERSION").write_text(f"{version}\n", encoding="utf-8")

        # Swap directories so a failed copy never leaves a half-updated backend.
        current = backend_dir()
        previous = root / ".backend-previous"
        shutil.rmtree(previous, ignore_errors=True)
        os.replace(current, previous)
        try:
            shutil.move(str(new_backend), str(current))
        except Exception:
            os.replace(previous, current)
            raise
        shutil.rmtree(previous, ignore_errors=True)

        installed = []
        for directory in plugin_dirs():
            try:
                directory.mkdir(parents=True, exist_ok=True)
                (directory / PLUGIN_FILE).write_bytes(plugin)
                installed.append(str(directory / PLUGIN_FILE))
            except OSError as error:
                print(f"[prism] Could not write plugin to {directory}: {error}")
    return installed


def restart():
    """Exit so the service manager starts the updated backend; spawn it ourselves when unmanaged."""
    managed = bool(os.environ.get("INVOCATION_ID")) or os.environ.get("XPC_SERVICE_NAME", "").endswith("prism")
    if not managed:
        import bpy

        main = backend_dir() / "main.py"
        command = [bpy.app.binary_path, "--background", "--factory-startup", "--python", str(main), "--", "serve"]
        if sys.platform == "win32":
            log = Path(os.environ.get("LOCALAPPDATA", Path.home())) / "Prism" / "prism.log"
            command += ["--log", str(log)]
            flags = subprocess.DETACHED_PROCESS | subprocess.CREATE_NEW_PROCESS_GROUP
            subprocess.Popen(command, creationflags=flags, close_fds=True)
        else:
            subprocess.Popen(command, start_new_session=True, close_fds=True,
                             stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        sys.stdout.flush()
        os._exit(0)
    sys.stdout.flush()
    # systemd (Restart=on-failure) and launchd (KeepAlive SuccessfulExit=false) restart non-zero exits.
    os._exit(RESTART_EXIT_CODE)
