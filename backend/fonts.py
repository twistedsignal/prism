"""Find installed fonts (system and Roblox Studio) and pick the closest face for a style.

Reads the family, weight and italic flags straight from TTF/OTF tables, so the server
can list fonts without Blender or extra packages.
"""

import json
import os
import struct
import sys
import threading
import time
from pathlib import Path

EXTENSIONS = (".ttf", ".otf", ".ttc", ".otc")
RESCAN_SECONDS = 30
MAX_FILES = 5000

_lock = threading.Lock()
_cache = {"time": 0.0, "families": {}}


def roblox_font_dirs():
    """content/fonts of every Roblox Studio install Prism knows how to find."""
    roots = []
    if sys.platform == "win32":
        for base in (os.environ.get("LOCALAPPDATA"), os.environ.get("ProgramFiles(x86)"), os.environ.get("ProgramFiles")):
            if base:
                roots.append(Path(base) / "Roblox" / "Versions")
    elif sys.platform == "darwin":
        for app in (Path("/Applications"), Path.home() / "Applications"):
            roots.append(app / "RobloxStudio.app" / "Contents" / "Resources")
    else:
        data = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local" / "share")
        for vinegar in (Path.home() / ".var/app/org.vinegarhq.Vinegar/data/vinegar", data / "vinegar"):
            roots.append(vinegar / "versions")
            roots.extend(vinegar.glob("prefixes/*/drive_c/users/*/AppData/Local/Roblox/Versions"))
    found = []
    for root in roots:
        if (root / "content" / "fonts").is_dir():
            found.append(root / "content" / "fonts")
        elif root.is_dir():
            found.extend(path for path in root.glob("*/content/fonts") if path.is_dir())
    return found


def system_font_dirs():
    if sys.platform == "win32":
        windows = Path(os.environ.get("WINDIR", "C:/Windows"))
        dirs = [windows / "Fonts"]
        if os.environ.get("LOCALAPPDATA"):
            dirs.append(Path(os.environ["LOCALAPPDATA"]) / "Microsoft" / "Windows" / "Fonts")
        return dirs
    if sys.platform == "darwin":
        return [Path("/System/Library/Fonts"), Path("/Library/Fonts"), Path.home() / "Library" / "Fonts"]
    data = Path(os.environ.get("XDG_DATA_HOME") or Path.home() / ".local" / "share")
    # /run/host holds the host's fonts when Blender runs as a flatpak.
    return [Path("/usr/share/fonts"), Path("/usr/local/share/fonts"), data / "fonts", Path.home() / ".fonts",
            Path("/run/host/fonts"), Path("/run/host/user-fonts")]


# ============================================================
# FONT FILES
# ============================================================

def decode_name(platform, data):
    if platform in (0, 3):
        return data.decode("utf-16-be", errors="ignore")
    return data.decode("mac_roman", errors="ignore")


def read_face(path):
    """Return {"family", "weight", "italic"} for a font file's first face, or None."""
    with open(path, "rb") as handle:
        def read(offset, length):
            handle.seek(offset)
            data = handle.read(length)
            if len(data) != length:
                raise ValueError("truncated font")
            return data

        start = 0
        if read(0, 4) == b"ttcf":
            start = struct.unpack(">I", read(12, 4))[0]
        version = read(start, 4)
        if version not in (b"\x00\x01\x00\x00", b"OTTO", b"true"):
            return None
        count = struct.unpack(">H", read(start + 4, 2))[0]
        tables = {}
        for index in range(min(count, 128)):
            tag, _, offset, length = struct.unpack(">4sIII", read(start + 12 + index * 16, 16))
            tables[tag] = (offset, length)
        if b"name" not in tables:
            return None

        offset, _ = tables[b"name"]
        _, records, strings = struct.unpack(">HHH", read(offset, 6))
        names = {}
        for index in range(min(records, 1024)):
            platform, encoding, language, name_id, length, string_offset = struct.unpack(
                ">HHHHHH", read(offset + 6 + index * 12, 12),
            )
            if name_id not in (1, 2, 16, 17):
                continue
            # Prefer English Windows names, then any Unicode name, then Mac Roman.
            rank = 0 if platform == 3 and language == 0x409 else 1 if platform in (0, 3) else 2
            if name_id in names and names[name_id][0] <= rank:
                continue
            value = decode_name(platform, read(offset + strings + string_offset, length)).strip()
            if value:
                names[name_id] = (rank, value)
        family = (names.get(16) or names.get(1) or (0, ""))[1]
        style = (names.get(17) or names.get(2) or (0, ""))[1].lower()
        if not family:
            return None

        weight = 400
        italic = "italic" in style or "oblique" in style
        if b"OS/2" in tables and tables[b"OS/2"][1] >= 64:
            os2 = tables[b"OS/2"][0]
            weight = struct.unpack(">H", read(os2 + 4, 2))[0] or 400
            selection = struct.unpack(">H", read(os2 + 62, 2))[0]
            italic = italic or bool(selection & 0x201)
        return {"family": family, "weight": min(max(weight, 100), 1000), "italic": italic}


def scan(directories):
    families = {}
    seen = 0
    for directory in directories:
        source = directory[1]
        for root, _, files in os.walk(directory[0]):
            for name in files:
                if not name.lower().endswith(EXTENSIONS):
                    continue
                seen += 1
                if seen > MAX_FILES:
                    return families
                path = os.path.join(root, name)
                try:
                    face = read_face(path)
                except (OSError, ValueError, struct.error):
                    continue
                # Hidden system families (".SF NS") aren't meant for users.
                if face is None or face["family"].startswith("."):
                    continue
                entry = families.setdefault(face["family"], {"source": source, "faces": []})
                if source == "roblox":
                    entry["source"] = "roblox"
                entry["faces"].append({"path": path, "weight": face["weight"], "italic": face["italic"]})
    return families


def families(force=False):
    """{family: {"source": "roblox" | "system", "faces": [{path, weight, italic}]}}, cached briefly."""
    with _lock:
        if force or time.monotonic() - _cache["time"] > RESCAN_SECONDS or not _cache["time"]:
            directories = [(path, "roblox") for path in roblox_font_dirs()]
            directories += [(path, "system") for path in system_font_dirs() if path.is_dir()]
            _cache["families"] = scan(directories)
            _cache["time"] = time.monotonic()
        return _cache["families"]


def roblox_families():
    """{family name: "rbxasset://fonts/families/<file>.json"} for Studio's font families."""
    found = {}
    for directory in roblox_font_dirs():
        for path in sorted((directory / "families").glob("*.json")):
            try:
                name = json.loads(path.read_text(encoding="utf-8")).get("name")
            except (OSError, ValueError, AttributeError):
                continue
            if isinstance(name, str) and name:
                found.setdefault(name, f"rbxasset://fonts/families/{path.name}")
    return found


def listing():
    """Font options for the plugin: Roblox Studio fonts first, then system fonts.

    robloxFont is the Roblox font family for the same typeface, so the plugin can
    preview each option in its own font.
    """
    entries = families()
    roblox = roblox_families()
    ordered = sorted(entries, key=lambda name: (entries[name]["source"] != "roblox", name.lower()))
    result = []
    for name in ordered:
        option = {"value": name, "label": name, "source": entries[name]["source"]}
        if name in roblox:
            option["robloxFont"] = roblox[name]
        result.append(option)
    return result


def resolve(family, weight=400, italic=False):
    """Closest face to the requested style: (path, face weight, face italic), or None for the default font."""
    if not family:
        return None
    entry = families().get(family)
    if entry is None:
        return None

    def distance(face):
        return (face["italic"] != italic, abs(face["weight"] - weight), face["path"])

    face = min(entry["faces"], key=distance)
    return face["path"], face["weight"], face["italic"]
