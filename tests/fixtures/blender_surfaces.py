"""Run inside Blender to verify surface textures and pins in actual renders."""
import sys
import tempfile
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "backend"))
import part_surfaces
import renderer
import scene

IDENTITY = [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1]
output = Path("/tmp/prism-surface-renders")
output.mkdir(exist_ok=True)
engine = renderer.Renderer()
with tempfile.TemporaryDirectory() as temporary:
    directory = Path(temporary)
    images = {}
    for surface in sorted(part_surfaces.TYPES):
        payload = {"parts": [{"kind": "block", "size": [4, 1, 4], "cframe": IDENTITY,
                              "color": "#A3A2A5", "surfaces": {"Top": surface, "Front": surface}}]}
        target = directory / surface
        scene.build(payload, target)
        key = engine.load(target / "model.obj")
        result = engine.render(key, {"cameraElevation": 65}, 256, "16")
        assert result[..., 3].max() > 0.99, surface
        images[surface] = result.copy()
        renderer.save_png_pixels(result, output / f"{surface}.png")
    smooth = images["Smooth"]
    np.testing.assert_allclose(images["SmoothNoOutlines"], smooth)
    np.testing.assert_allclose(images["Glue"], images["Weld"])
    np.testing.assert_allclose(images["Motor"], images["SteppingMotor"])
    for surface in part_surfaces.PATTERNS:
        assert np.max(np.abs(images[surface] - smooth)) > 0.1, f"{surface} disappeared in Workbench"
    for surface in part_surfaces.PINS:
        result = images[surface]
        visible = result[..., :3][result[..., 3] > 0.99]
        assert np.any((visible[:, 0] > 0.8) & (visible[:, 1] > 0.8) & (visible[:, 2] < visible[:, 0] - 0.05)), surface
    for kind in ("wedge", "cornerWedge", "ball", "cylinder"):
        payload = {"parts": [{"kind": kind, "size": [4, 4, 4], "cframe": IDENTITY,
                              "surfaces": {face: "Universal" for face in part_surfaces.FACES}}]}
        target = directory / kind
        scene.build(payload, target)
        key = engine.load(target / "model.obj")
        result = engine.render(key, {}, 256, "16")
        renderer.save_png_pixels(result, output / f"{kind}.png")
        assert result[..., 3].max() > 0.99, kind
    # Large surfaces must use the original tile, rather than a blurred face bake.
    target = directory / "large"
    scene.build({"parts": [{"kind": "block", "size": [64, 1, 64], "cframe": IDENTITY,
                            "surfaces": {"Top": "Studs"}}]}, target)
    key = engine.load(target / "model.obj")
    result = engine.render(key, {"cameraElevation": 89}, 512, "16")
    renderer.save_png_pixels(result, output / "large.png")
    assert result[..., 3].max() > 0.99
print("Blender surface texture, shape, pin and tiling checks passed")
