"""Run inside Blender: check soccer texture orientation and Union colors through OBJ."""
import base64
import sys
import tempfile
from pathlib import Path

import bpy
import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "backend"))
import mesh_asset
import renderer
import scene

IDENTITY = [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1]
fixture = ROOT / "tests" / "fixtures" / "soccer"
image = bpy.data.images.load(str(fixture / "ball.png"))
pixels = np.asarray(image.pixels[:]).reshape(256, 256, 4)
texture = {"width": 256, "height": 256,
           "pixels": base64.b64encode((pixels[::-1] * 255 + 0.5).astype(np.uint8).tobytes()).decode()}
mesh = mesh_asset.decode((fixture / "ball.mesh").read_bytes())
corners = scene.mesh_corners(mesh)
groups = {}
for start in range(0, len(corners), 3):
    triangle = corners[start:start + 3]
    normal = scene.face_normal(*(c[0] for c in triangle))
    groups.setdefault(tuple(round(n, 3) for n in normal), []).extend(triangle)
for polygon in groups.values():
    n = len({tuple(round(v, 4) for v in corner[0]) for corner in polygon})
    uv = np.mean([c[1] for c in polygon], axis=0)
    color = pixels[int(uv[1] * 255), int(uv[0] * 255), :3].mean()
    assert color < 0.2 if n == 5 else color > 0.9, (n, uv, color)

with tempfile.TemporaryDirectory() as temporary:
    directory = Path(temporary)
    part = {"kind": "mesh", "mesh": mesh, "cframe": IDENTITY, "size": [1,1,1],
            "color": "#FFFFFF", "texture": {"id": "ball", "mode": "alpha"}}
    scene.build({"parts": [part], "textures": {"ball": texture}}, directory / "soccer")
    engine = renderer.Renderer()
    key = engine.load(directory / "soccer" / "model.obj")
    result = engine.render(key, {}, 128, "8")
    assert result[..., 3].max() > 0.99
    visible = result[..., :3][result[..., 3] > 0.99]
    assert visible.min() < 0.3 and visible.max() > 0.9

    cube = scene.block([2,2,2])
    rgb = [(1,0,0) if c[2][1] > 0 else (0,0,1) for c in cube]
    mesh = {"positions": mesh_asset.packed(v for c in cube for v in c[0]),
            "normals": mesh_asset.packed(v for c in cube for v in c[2]),
            "colors": mesh_asset.packed(v for c in rgb for v in c), "center": False}
    part = {"kind": "mesh", "mesh": mesh, "cframe": IDENTITY, "size": [2,2,2], "color": "#00FF00"}
    scene.build({"parts": [part]}, directory / "union")
    key = engine.load(directory / "union" / "model.obj")
    result = engine.render(key, {}, 128, "8")
    visible = result[..., :3][result[..., 3] > 0.99]
    assert np.any(visible[:, 0] > visible[:, 2] * 2), "Union lost its red face"
    assert np.any(visible[:, 2] > visible[:, 0] * 2), "Union lost its blue face"
    assert visible[:, 1].max() < 0.1, "Part color replaced stored Union colors"
    print("Blender mesh texture and Union color checks passed")
