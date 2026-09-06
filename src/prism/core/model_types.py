"""Model format validation kept independent from Blender's UI integration."""

from __future__ import annotations

from pathlib import Path

SUPPORTED_MODEL_SUFFIXES = frozenset({".blend", ".fbx", ".glb", ".gltf", ".obj", ".stl"})


def validate_model_path(path: Path) -> Path:
    candidate = path.expanduser()
    if not candidate.is_file():
        raise ValueError("The selected model file does not exist.")
    if candidate.suffix.lower() not in SUPPORTED_MODEL_SUFFIXES:
        raise ValueError("Prism supports BLEND, FBX, GLB, glTF, OBJ, and STL models.")
    return candidate
