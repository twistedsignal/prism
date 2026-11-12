"""Persist installer paths outside the backend directory replaced by updates."""
import json
import os
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
ENVIRONMENT = (
    "PRISM_CONFIG_DIR", "PRISM_PLUGINS_DIR", "RAVEN_CONFIG_DIR",
    "XDG_CONFIG_HOME", "XDG_DATA_HOME", "XDG_CACHE_HOME",
)


def read():
    try:
        value = json.loads((ROOT / "installation.json").read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {}
    return value if isinstance(value, dict) else {}


def restore():
    environment = read().get("environment", {})
    if isinstance(environment, dict):
        for key in ENVIRONMENT:
            value = environment.get(key)
            if isinstance(value, str) and value:
                os.environ.setdefault(key, value)


def save(plugin_dirs):
    import config

    environment = {key: os.environ[key] for key in ENVIRONMENT if os.environ.get(key)}
    environment["PRISM_CONFIG_DIR"] = str(config.config_dir().expanduser().resolve())
    folders = [str(Path(folder).expanduser().resolve()) for folder in plugin_dirs]
    config.write_json(ROOT / "installation.json", {"environment": environment, "pluginDirs": folders})
    (ROOT / "plugin-dirs.txt").write_text("".join(folder + "\n" for folder in folders), encoding="utf-8")
    (ROOT / "cache-dir.txt").write_text(str(config.cache_dir().expanduser().resolve()) + "\n", encoding="utf-8")
