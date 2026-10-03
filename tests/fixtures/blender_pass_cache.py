"""Run inside Blender: verify actual pass reuse and camera invalidation."""
import sys
import tempfile
from pathlib import Path
from unittest.mock import patch

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "backend"))
import renderer

with tempfile.TemporaryDirectory() as directory:
    obj = Path(directory) / "cube.obj"
    obj.write_text("\n".join([
        "v -1 -1 -1", "v 1 -1 -1", "v 1 1 -1", "v -1 1 -1",
        "v -1 -1 1", "v 1 -1 1", "v 1 1 1", "v -1 1 1",
        "f 1 4 3 2", "f 5 6 7 8", "f 1 2 6 5", "f 2 3 7 6", "f 3 4 8 7", "f 4 1 5 8",
    ]))
    engine = renderer.Renderer()
    key = engine.load(obj)
    with patch.object(renderer, "load_png_pixels", wraps=renderer.load_png_pixels) as read:
        first = engine.render(key, {"minAngle": 30}, 128, "8")
        original = first.copy()
        assert read.call_count == 3, read.call_count
        colored = engine.render(key, {"minAngle": 30, "saturation": 0.2, "glow": True}, 128, "8")
        assert read.call_count == 3, "Effect edits triggered Blender"
        engine.render(key, {"minAngle": 60}, 128, "8")
        assert read.call_count == 3, "Angle edits rerendered cached passes"
        engine.render(key, {"cavity": False}, 128, "8")
        assert read.call_count == 3, "Cavity off rerendered the base pass"
        turned = engine.render(key, {"cameraRotation": 70}, 128, "8")
        assert read.call_count == 6, "Camera edit reused obsolete passes"
        assert not np.array_equal(first, turned)
        np.testing.assert_array_equal(first, original)
        assert np.all(np.isfinite(colored))
    print("Blender pass-cache checks passed")
