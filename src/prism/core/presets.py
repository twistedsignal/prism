"""Deterministic, offline Prism P1 preset codes."""

from __future__ import annotations

import base64
import json
import zlib
from dataclasses import asdict
from typing import Any

from prism.core.settings import (
    CameraSettings,
    CavitySettings,
    Color,
    GeometrySettings,
    LightingSettings,
    MaterialSettings,
    OutputSettings,
    Projection,
    RenderEngine,
    RenderSettings,
)

PREFIX = "P1."


class PresetError(ValueError):
    """Raised for invalid, corrupted, or unsupported preset codes."""


def encode(settings: RenderSettings) -> str:
    document = {"version": 1, **asdict(settings)}
    canonical = json.dumps(document, sort_keys=True, separators=(",", ":")).encode("utf-8")
    return PREFIX + base64.urlsafe_b64encode(zlib.compress(canonical, level=9)).rstrip(b"=").decode(
        "ascii"
    )


def decode(code: str) -> RenderSettings:
    if not code.startswith(PREFIX):
        raise PresetError("This is not a Prism P1 preset code.")
    try:
        payload = code[len(PREFIX) :].encode("ascii")
        raw = zlib.decompress(base64.urlsafe_b64decode(payload + b"=" * (-len(payload) % 4)))
        document: object = json.loads(raw)
    except (UnicodeEncodeError, ValueError, zlib.error) as error:
        raise PresetError("The preset code is corrupted.") from error
    if not isinstance(document, dict) or document.get("version") != 1:
        raise PresetError("This preset version is not supported.")
    try:
        return _from_document(document)
    except (KeyError, TypeError, ValueError) as error:
        raise PresetError("The preset settings are invalid.") from error


def _color(value: dict[str, Any]) -> Color:
    return Color(**value)


def _from_document(document: dict[str, Any]) -> RenderSettings:
    camera = dict(document["camera"])
    camera["projection"] = Projection(camera["projection"])
    output = dict(document["output"])
    output["background"] = _color(output["background"])
    output["engine"] = RenderEngine(output["engine"])
    material = dict(document["material"])
    material["base_color"] = _color(material["base_color"])
    return RenderSettings(
        camera=CameraSettings(**camera),
        output=OutputSettings(**output),
        lighting=LightingSettings(**document["lighting"]),
        material=MaterialSettings(**material),
        geometry=GeometrySettings(**document["geometry"]),
        cavity=CavitySettings(**document["cavity"]),
    )
