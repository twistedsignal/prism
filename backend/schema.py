"""Render settings schema: the single source of truth for the plugin UI and renderer."""

import math
import re

# Key light direction defaults reproduce the original fixed camera rig:
# camera direction (1.4, -1.7, 1.15) and key light (-0.45, 0.55, 0.80).
SECTIONS = [
    {
        "id": "stance",
        "label": "Model stance",
        "settings": [
            {"key": "pitch", "label": "Pitch (X)", "type": "number", "min": -180, "max": 180, "step": 1, "default": 0,
             "description": "Model rotation about the X axis, in degrees."},
            {"key": "yaw", "label": "Yaw (Y)", "type": "number", "min": -180, "max": 180, "step": 1, "default": 0,
             "description": "Model rotation about the vertical (Y) axis, in degrees."},
            {"key": "roll", "label": "Roll (Z)", "type": "number", "min": -180, "max": 180, "step": 1, "default": 0,
             "description": "Model rotation about the Z axis, in degrees."},
        ],
    },
    {
        "id": "camera",
        "label": "Camera",
        "settings": [
            {"key": "cameraRotation", "label": "Rotation", "type": "number", "min": -180, "max": 180, "step": 0.5, "default": 39.5,
             "description": "Orbits the camera around the model, in degrees. 0 faces the model's front."},
            {"key": "cameraElevation", "label": "Elevation", "type": "number", "min": -89, "max": 89, "step": 0.5, "default": 27.5,
             "description": "Camera height angle above the model, in degrees."},
            {"key": "cameraRoll", "label": "Roll", "type": "number", "min": -180, "max": 180, "step": 0.5, "default": 0,
             "description": "Tilts the camera around its view axis, in degrees."},
            {"key": "zoom", "label": "Zoom", "type": "number", "min": 0.1, "max": 5, "step": 0.01, "default": 1,
             "description": "Larger values zoom in on the model."},
            {"key": "fov", "label": "FOV", "type": "number", "min": 5, "max": 120, "step": 0.5, "default": 30, "auto": "fovAuto",
             "description": "Perspective field of view in degrees. Auto uses a long lens that matches the orthographic framing."},
            {"key": "fovAuto", "label": "FOV auto", "type": "bool", "default": True, "hidden": True},
            {"key": "orthographic", "label": "Orthographic", "type": "bool", "default": True,
             "description": "Use an orthographic camera instead of perspective."},
        ],
    },
    {
        "id": "lighting",
        "label": "Lighting",
        "settings": [
            {"key": "castShadows", "label": "Cast shadows", "type": "bool", "default": True,
             "description": "Let the sun cast shadows onto the model."},
            {"key": "shadowIntensity", "label": "Shadow intensity", "type": "number", "min": 0, "max": 1, "step": 0.01, "default": 0.32,
             "description": "How dark cast shadows are."},
            {"key": "sunColor", "label": "Sun color", "type": "color", "default": "#FFFFFF",
             "description": "Color of the main light."},
            {"key": "sunIntensity", "label": "Sun intensity", "type": "number", "min": 0, "max": 3, "step": 0.01, "default": 1,
             "description": "Strength of the main light."},
            {"key": "sunRotation", "label": "Sun rotation", "type": "number", "min": -180, "max": 180, "step": 0.5, "default": -29.5,
             "description": "Main light direction around the view, relative to the camera, in degrees."},
            {"key": "sunElevation", "label": "Sun elevation", "type": "number", "min": -89, "max": 89, "step": 0.5, "default": 31,
             "description": "Main light height relative to the camera, in degrees."},
            {"key": "secondaryColor", "label": "Secondary color", "type": "color", "default": "#FFFFFF",
             "description": "Color of the fill and rim lights."},
            {"key": "secondaryIntensity", "label": "Secondary intensity", "type": "number", "min": 0, "max": 3, "step": 0.01, "default": 1,
             "description": "Strength of the fill and rim lights."},
            {"key": "ambientColor", "label": "Ambient color", "type": "color", "default": "#FFFFFF",
             "description": "Color of the light that reaches every surface."},
            {"key": "ambientIntensity", "label": "Ambient intensity", "type": "number", "min": 0, "max": 2, "step": 0.01, "default": 0.5145,
             "description": "Strength of the ambient light."},
            {"key": "exposure", "label": "Global exposure", "type": "number", "min": -3, "max": 3, "step": 0.01, "default": 0,
             "description": "Scene exposure in stops."},
        ],
    },
    {
        "id": "material",
        "label": "Material",
        "settings": [
            {"key": "transparency", "label": "Enable transparency", "type": "bool", "default": True,
             "description": "Honor part transparency and texture alpha."},
            {"key": "specular", "label": "Specular", "type": "number", "min": 0, "max": 1, "step": 0.01, "default": 0,
             "description": "Strength of specular highlights. Roughness only matters above zero."},
            {"key": "roughness", "label": "Roughness", "type": "number", "min": 0, "max": 1, "step": 0.01, "default": 0.5,
             "description": "Surface roughness used for specular highlights."},
        ],
    },
    {
        "id": "effects",
        "label": "Effects",
        "settings": [
            {"key": "saturation", "label": "Saturation", "type": "number", "min": 0, "max": 3, "step": 0.01, "default": 1,
             "description": "0 is grayscale, 1 leaves colors unchanged."},
            {"key": "contrast", "label": "Contrast", "type": "number", "min": 0, "max": 3, "step": 0.01, "default": 1,
             "description": "1 leaves contrast unchanged."},
            {"key": "brightness", "label": "Brightness", "type": "number", "min": 0, "max": 3, "step": 0.01, "default": 1,
             "description": "1 leaves brightness unchanged."},
            {"key": "outlineColor", "label": "Outline color", "type": "color", "default": "#000000",
             "description": "Color of the silhouette outline."},
            {"key": "outlineSize", "label": "Outline size", "type": "number", "min": 0, "max": 40, "step": 1, "default": 10,
             "description": "Outline width in pixels at 512px. 0 disables the outline."},
            {"key": "dropShadow", "label": "Enable drop shadow", "type": "bool", "default": True,
             "description": "Draw a soft shadow behind the silhouette."},
            {"key": "shadowColor", "label": "Shadow color", "type": "color", "default": "#000000",
             "description": "Color of the drop shadow."},
            {"key": "shadowOpacity", "label": "Shadow opacity", "type": "number", "min": 0, "max": 1, "step": 0.01, "default": 0.35,
             "description": "Opacity of the drop shadow."},
            {"key": "shadowBlur", "label": "Shadow blur", "type": "number", "min": 0, "max": 60, "step": 0.5, "default": 25,
             "description": "Blur radius of the drop shadow in pixels at 512px."},
            {"key": "shadowOffsetX", "label": "Shadow X offset", "type": "number", "min": -64, "max": 64, "step": 1, "default": 12,
             "description": "Positive values move the shadow right."},
            {"key": "shadowOffsetY", "label": "Shadow Y offset", "type": "number", "min": -64, "max": 64, "step": 1, "default": 12,
             "description": "Positive values move the shadow down."},
            {"key": "glow", "label": "Enable glow", "type": "bool", "default": False,
             "description": "Draw a soft colored glow behind the silhouette."},
            {"key": "glowColor", "label": "Glow color", "type": "color", "default": "#FFD966",
             "description": "Color of the glow."},
            {"key": "glowOpacity", "label": "Glow opacity", "type": "number", "min": 0, "max": 1, "step": 0.01, "default": 0.8,
             "description": "Opacity of the glow."},
            {"key": "glowSize", "label": "Glow size", "type": "number", "min": 0, "max": 64, "step": 1, "default": 16,
             "description": "Glow spread in pixels at 512px."},
        ],
    },
    {
        "id": "geometry",
        "label": "Geometry",
        "settings": [
            {"key": "subdivision", "label": "Subdivision levels", "type": "number", "min": 0, "max": 3, "step": 1, "default": 0,
             "description": "Subdivision surface levels. Higher values are smoother and slower."},
            {"key": "smooth", "label": "Smooth shading", "type": "bool", "default": False,
             "description": "Merge split vertices and shade smooth instead of using the mesh's own normals."},
        ],
    },
    {
        "id": "cavity",
        "label": "Cavity",
        "settings": [
            {"key": "cavity", "label": "Enable cavity", "type": "bool", "default": True,
             "description": "Highlight ridges and darken valleys."},
            {"key": "worldRidge", "label": "World ridge", "type": "number", "min": 0, "max": 2.5, "step": 0.01, "default": 2,
             "description": "World space ridge highlight strength."},
            {"key": "worldValley", "label": "World valley", "type": "number", "min": 0, "max": 2.5, "step": 0.01, "default": 1.5,
             "description": "World space valley darkening strength."},
            {"key": "screenRidge", "label": "Screen ridge", "type": "number", "min": 0, "max": 2, "step": 0.01, "default": 0.15,
             "description": "Screen space ridge highlight strength."},
            {"key": "screenValley", "label": "Screen valley", "type": "number", "min": 0, "max": 2, "step": 0.01, "default": 0.15,
             "description": "Screen space valley darkening strength."},
            {"key": "minAngle", "label": "Minimum angle", "type": "number", "min": 0, "max": 180, "step": 1, "default": 35,
             "description": "Ignore curves gentler than this many degrees. 0 keeps all cavity; 180 disables it."},
        ],
    },
]

SETTINGS = {setting["key"]: setting for section in SECTIONS for setting in section["settings"]}
DEFAULTS = {key: setting["default"] for key, setting in SETTINGS.items()}
HEX_COLOR = re.compile(r"^#?([0-9a-fA-F]{6})$")


def schema():
    return {"sections": SECTIONS, "defaults": DEFAULTS}


def normalize_value(setting, value):
    kind = setting["type"]
    if kind == "bool":
        return value if isinstance(value, bool) else setting["default"]
    if kind == "color":
        match = HEX_COLOR.match(value) if isinstance(value, str) else None
        return f"#{match.group(1).upper()}" if match else setting["default"]
    if kind == "number":
        if isinstance(value, bool) or not isinstance(value, (int, float)) or not math.isfinite(value):
            return setting["default"]
        return min(max(float(value), setting["min"]), setting["max"])
    return setting["default"]


def normalize(settings):
    """Merge defaults into a settings dict and clamp every value to its schema."""
    settings = settings if isinstance(settings, dict) else {}
    return {
        key: normalize_value(setting, settings.get(key, setting["default"]))
        for key, setting in SETTINGS.items()
    }


def hex_to_rgb(value):
    """Parse #RRGGBB into display-space floats."""
    value = value.lstrip("#")
    return tuple(int(value[i:i + 2], 16) / 255 for i in (0, 2, 4))


def srgb_to_linear(channel):
    return channel / 12.92 if channel <= 0.04045 else ((channel + 0.055) / 1.055) ** 2.4
