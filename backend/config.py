"""Per-OS paths plus the JSON-backed server config, preset and history stores."""

import json
import os
import re
import sys
import tempfile
import threading
import time
from pathlib import Path

import schema

APP_NAME = "Prism"
DEFAULT_PORT = 47821
AA_OPTIONS = ("OFF", "FXAA", "5", "8", "11", "16", "32")
PREVIEW_SIZE_OPTIONS = (128, 256, 384, 512, 768, 1024)
RENDER_SIZE_OPTIONS = (*PREVIEW_SIZE_OPTIONS, 2048, 4096)


def config_dir():
    if os.environ.get("PRISM_CONFIG_DIR"):
        return Path(os.environ["PRISM_CONFIG_DIR"])
    if sys.platform == "win32":
        return Path(os.environ.get("APPDATA", Path.home() / "AppData" / "Roaming")) / APP_NAME
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Application Support" / APP_NAME
    return Path(os.environ.get("XDG_CONFIG_HOME") or Path.home() / ".config") / "prism"


def cache_dir():
    if sys.platform == "win32":
        return Path(os.environ.get("LOCALAPPDATA", Path.home() / "AppData" / "Local")) / APP_NAME / "cache"
    if sys.platform == "darwin":
        return Path.home() / "Library" / "Caches" / APP_NAME
    return Path(os.environ.get("XDG_CACHE_HOME") or Path.home() / ".cache") / "prism"


def default_output_folder():
    pictures = Path.home() / "Pictures"
    return str(pictures / APP_NAME)


def version():
    path = Path(__file__).resolve().parent / "VERSION"
    try:
        return path.read_text().strip() or "dev"
    except OSError:
        return "dev"


CONFIG_DEFAULTS = {
    "outputFolder": default_output_folder(),
    "previewSize": 256,
    "renderSize": 512,
    "previewAA": "8",
    "renderAA": "32",
    "filenamePattern": "{name}",
    "overwrite": True,
    "blenderPath": "",
    "ravenPath": "",
    "defaultCreator": "",
    "port": DEFAULT_PORT,
    "emojiProvider": "google",
}

CREATOR_PATTERN = re.compile(r"^(user|group):\d+$")
MAX_HISTORY = 500
HISTORY_FIELDS = ("name", "path", "assetId", "imageId", "moderation", "creator", "source", "parent")


def normalize_config(values):
    config = dict(CONFIG_DEFAULTS)
    if not isinstance(values, dict):
        return config
    for key, default in CONFIG_DEFAULTS.items():
        value = values.get(key)
        if value is None:
            continue
        if isinstance(default, bool):
            if isinstance(value, bool):
                config[key] = value
        elif isinstance(default, int):
            if isinstance(value, (int, float)) and not isinstance(value, bool):
                config[key] = int(value)
        elif isinstance(value, str):
            config[key] = value.strip()
    if config["previewSize"] not in PREVIEW_SIZE_OPTIONS:
        config["previewSize"] = CONFIG_DEFAULTS["previewSize"]
    if config["renderSize"] not in RENDER_SIZE_OPTIONS:
        config["renderSize"] = CONFIG_DEFAULTS["renderSize"]
    for key in ("previewAA", "renderAA"):
        if config[key] not in AA_OPTIONS:
            config[key] = CONFIG_DEFAULTS[key]
    if not 1024 <= config["port"] <= 65535:
        config["port"] = DEFAULT_PORT
    if config["emojiProvider"] not in ("apple", "google", "facebook", "twitter"):
        config["emojiProvider"] = CONFIG_DEFAULTS["emojiProvider"]
    if config["defaultCreator"] and not CREATOR_PATTERN.match(config["defaultCreator"]):
        config["defaultCreator"] = ""
    if "{name}" not in config["filenamePattern"] and "{index}" not in config["filenamePattern"]:
        config["filenamePattern"] = CONFIG_DEFAULTS["filenamePattern"]
    if not config["outputFolder"]:
        config["outputFolder"] = CONFIG_DEFAULTS["outputFolder"]
    return config


def read_json(path, fallback):
    try:
        return json.loads(Path(path).read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return fallback


def write_json(path, value):
    """Write atomically so a crash never leaves a half-written file."""
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(
        "w", encoding="utf-8", dir=path.parent, prefix=f".{path.name}.", delete=False,
    ) as handle:
        json.dump(value, handle, indent=2)
        handle.write("\n")
        temporary = handle.name
    os.replace(temporary, path)


class Store:
    """Thread-safe access to config.json, presets.json and history.json."""

    def __init__(self, directory=None):
        self.directory = Path(directory) if directory else config_dir()
        self.lock = threading.Lock()

    @property
    def config_path(self):
        return self.directory / "config.json"

    @property
    def presets_path(self):
        return self.directory / "presets.json"

    @property
    def history_path(self):
        return self.directory / "history.json"

    def get_config(self):
        with self.lock:
            return normalize_config(read_json(self.config_path, {}))

    def update_config(self, changes):
        with self.lock:
            current = read_json(self.config_path, {})
            if not isinstance(current, dict):
                current = {}
            if isinstance(changes, dict):
                current.update({key: value for key, value in changes.items() if key in CONFIG_DEFAULTS})
            config = normalize_config(current)
            write_json(self.config_path, config)
            return config

    def get_presets(self):
        with self.lock:
            presets = read_json(self.presets_path, {})
        if not isinstance(presets, dict):
            return {}
        return {
            name: schema.normalize(settings)
            for name, settings in presets.items()
            if isinstance(name, str) and isinstance(settings, dict)
        }

    def save_preset(self, name, settings):
        name = name.strip()[:64]
        if not name:
            raise ValueError("Preset name cannot be empty")
        with self.lock:
            presets = read_json(self.presets_path, {})
            if not isinstance(presets, dict):
                presets = {}
            presets[name] = schema.normalize(settings)
            write_json(self.presets_path, presets)
        return name

    def delete_preset(self, name):
        with self.lock:
            presets = read_json(self.presets_path, {})
            if not isinstance(presets, dict) or name not in presets:
                return False
            del presets[name]
            write_json(self.presets_path, presets)
            return True

    def get_history(self):
        with self.lock:
            history = read_json(self.history_path, [])
        if not isinstance(history, list):
            return []
        return [entry for entry in history if isinstance(entry, dict)]

    def record_history(self, kind, results, creator=None):
        """Add successful render or upload results, newest first."""
        now = int(time.time())
        entries = []
        for result in results:
            if "error" in result and not result.get("path"):
                continue
            uploaded = kind == "upload" and bool(result.get("assetId"))
            entry = {"kind": "upload" if uploaded else "render", "time": now}
            if uploaded and creator:
                entry["creator"] = creator
            for key in HISTORY_FIELDS:
                if isinstance(result.get(key), str) and result[key]:
                    entry[key] = result[key]
            entries.append(entry)
        if not entries:
            return
        entries.reverse()
        with self.lock:
            history = read_json(self.history_path, [])
            if not isinstance(history, list):
                history = []
            try:
                write_json(self.history_path, (entries + history)[:MAX_HISTORY])
            except OSError as error:
                # History is a convenience; a full disk must not fail the render.
                print(f"[prism] Could not save history: {error}", flush=True)

    def clear_history(self):
        with self.lock:
            write_json(self.history_path, [])
