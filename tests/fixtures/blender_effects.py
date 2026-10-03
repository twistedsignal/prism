"""Run inside Blender: every image effect renders, extra passes are exact and cached."""
import base64
import struct
import sys
import tempfile
from pathlib import Path
from unittest.mock import patch

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "backend"))
import renderer
import scene
import schema

IDENTITY = [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1]

with tempfile.TemporaryDirectory() as directory:
    directory = Path(directory)

    # A single quad: its depth must be one plane, interpolated linearly across both triangles.
    quad = [(-3, 0, -3), (3, 0, -3), (3, 0, 3), (-3, 0, -3), (3, 0, 3), (-3, 0, 3)]
    quad += [quad[0], quad[2], quad[1], quad[3], quad[5], quad[4]]
    positions = base64.b64encode(struct.pack(f"<{len(quad) * 3}f", *[c for p in quad for c in p])).decode()
    scene.build({"parts": [{"kind": "mesh", "cframe": IDENTITY, "size": [1, 1, 1], "color": "#FFFFFF",
                            "mesh": {"positions": positions, "center": False}}]}, directory / "plane")
    engine = renderer.Renderer()
    key = engine.load(directory / "plane" / "model.obj")
    engine.render(key, {"depthTint": True}, 128, "OFF")
    depth = next(value for name, value in engine.passes.items.items() if name[0] == "depth")
    ys, xs = np.nonzero(depth[..., 3] > 0.99)
    values = depth[..., 0][ys, xs].astype(np.float64)
    points = np.c_[xs, ys, np.ones_like(xs)].astype(np.float64)
    coefficients, *_ = np.linalg.lstsq(points, values, rcond=None)
    error = float(np.sqrt(np.mean((points @ coefficients - values) ** 2)))
    assert error < 1e-3, f"Depth is not linear across triangles (rms {error})"
    assert values.min() < 0.05 and values.max() > 0.95, "Depth is not normalized to the model"

    parts = [
        {"kind": "block", "cframe": IDENTITY, "size": [4, 1, 2], "color": "#C4281C"},
        {"kind": "ball", "cframe": [0, 1.5, 0, *IDENTITY[3:]], "size": [2, 2, 2], "color": "#0D69AC"},
    ]
    scene.build({"parts": parts}, directory / "model")
    key = engine.load(directory / "model" / "model.obj")
    cases = {
        "colorOverlay": {"colorOverlay": True}, "celShading": {"celShading": True},
        "heatmap": {"heatmap": True}, "heatmapDepth": {"heatmap": True, "heatmapSource": "depth"},
        "duotone": {"duotone": True}, "tritone": {"tritone": True}, "halftone": {"halftone": True},
        "dither": {"dither": True}, "pixelate": {"pixelate": True}, "chromatic": {"chromaticAberration": True},
        "crt": {"crt": True}, "bloom": {"bloom": True, "bloomThreshold": 0.3}, "xray": {"xray": True},
        "depthTint": {"depthTint": True}, "depthOutline": {"depthOutlineSize": 3},
        "innerShadow": {"innerShadow": True}, "vignette": {"vignette": True},
        "text": {"text": "Prism\\nIcons", "textItalic": True, "textUnderline": True, "textStrikethrough": True},
    }
    base = engine.render(key, {}, 128, "8")
    for name, values in cases.items():
        pixels = engine.render(key, values, 128, "8")
        assert pixels.shape == base.shape and np.all(np.isfinite(pixels)), name
        assert pixels.min() >= 0 and pixels.max() <= 1, name
        assert not np.allclose(pixels, base), f"{name} changed nothing"

    # Text sits at the center of the image, and strikethrough adds coverage.
    text = engine.text.render(str(directory), schema.normalize({"text": "Prism"}), 128, "8")
    ys, xs = np.nonzero(text > 0.5)
    assert abs(xs.mean() - 64) < 6 and abs(ys.mean() - 64) < 10, (xs.mean(), ys.mean())
    struck = engine.text.render(str(directory), schema.normalize({"text": "Prism", "textStrikethrough": True}), 128, "8")
    assert struck.sum() > text.sum() * 1.05, "Strikethrough drew nothing"
    rotated = engine.text.render(str(directory), schema.normalize({"text": "Prism", "textRotation": 90}), 128, "8")
    ys, xs = np.nonzero(rotated > 0.5)
    assert np.ptp(ys) > np.ptp(xs), "Rotation did not turn the text"

    # Once passes exist, effect edits (including text color) skip Blender.
    settings = {"text": "Hi", "depthTint": True, "xray": True, "celShading": True}
    engine.render(key, settings, 128, "8")
    # Every Blender pass is read back through load_png_pixels.
    with patch.object(renderer, "load_png_pixels", side_effect=AssertionError("Blender rendered")):
        engine.render(key, {**settings, "textColor": "#FF000080", "depthTintColor": "#00FF00", "xrayColor": "#FF00FF",
                            "celLevels": 5}, 128, "8")
    with patch.object(renderer, "load_png_pixels", wraps=renderer.load_png_pixels) as read:
        engine.render(key, {**settings, "text": "Changed"}, 128, "8")
        assert read.call_count == 1, f"Changing the text rerendered {read.call_count} passes"

    text_settings = {"text": "Move", "textColor": "#FF00FFFF", "outlineSize": 0, "dropShadow": False}
    centered = engine.render(key, text_settings, 128, "8")
    bounds = engine.text_bounds(text_settings, 128, "8")
    assert bounds is not None and bounds["width"] > 0 and bounds["height"] > 0
    with patch.object(renderer, "load_png_pixels", side_effect=AssertionError("Offset edit invoked Blender")):
        moved = engine.render(key, {**text_settings, "textOffsetX": 64, "textOffsetY": 32}, 128, "8")
        moved_bounds = engine.text_bounds({**text_settings, "textOffsetX": 64, "textOffsetY": 32}, 128, "8")
    assert not np.array_equal(centered, moved), "Text offset changed nothing"
    assert moved_bounds["x"] == bounds["x"] + 64 and moved_bounds["y"] == bounds["y"] + 32

    # Settings the plugin hides must not change a Blender render either.
    hidden = [
        ({"orthographic": True}, {"fov": 90, "fovAuto": False}),
        ({"castShadows": False}, {"shadowIntensity": 1.0}),
        ({"specular": 0}, {"roughness": 0.0}),
        ({"cavity": False}, {"worldRidge": 0.0, "worldValley": 2.5, "screenRidge": 2.0, "minAngle": 0}),
    ]
    for requirement, change in hidden:
        first = engine.render(key, {**requirement, "outlineSize": 0, "dropShadow": False}, 64, "8")
        second = engine.render(key, {**requirement, **change, "outlineSize": 0, "dropShadow": False}, 64, "8")
        assert np.array_equal(first, second), f"{change} changed the render while {requirement}"

    text_effects = engine.render(key, {"text": "Hi", "textColor": "#FFFFFF00", "textOutlineSize": 4,
                                       "textGlow": True, "textShadow": True, "textGradient": True}, 128, "8")
    assert not np.allclose(text_effects, base), "Outline-only text drew nothing"
    spaced = engine.text.render(str(directory), schema.normalize({"text": "Prism", "textLetterSpacing": 2}), 128, "8")
    assert np.ptp(np.nonzero(spaced > 0.5)[1]) > np.ptp(np.nonzero(text > 0.5)[1]), "Letter spacing did nothing"

print("Blender effect checks passed")
