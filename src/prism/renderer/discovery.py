"""Blender executable discovery without platform-specific hardcoded paths."""

from __future__ import annotations

import shutil
from pathlib import Path


def discover_blender(explicit_path: str | None = None) -> Path | None:
    if explicit_path is not None:
        candidate = Path(explicit_path).expanduser()
        return candidate if candidate.is_file() else None
    located = shutil.which("blender")
    return Path(located) if located is not None else None
