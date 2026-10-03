"""Run inside Blender: material detail sharing and loaded-model eviction."""

import sys
import tempfile
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "backend"))
import renderer
import scene

IDENTITY = [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1]


def rss_mib():
    status = Path("/proc/self/status")
    if not status.exists():
        return None
    for line in status.read_text().splitlines():
        if line.startswith("VmRSS:"):
            return int(line.split()[1]) / 1024
    return None

with tempfile.TemporaryDirectory() as directory:
    engine = renderer.Renderer()
    keys = []
    for index in range(5):
        path = Path(directory) / f"model{index}"
        parts = [{
            "kind": "block", "cframe": [offset * 2, 0, 0, *IDENTITY[3:]],
            "size": [2, 2, 2], "color": color, "material": {"name": "Concrete"},
        } for offset, color in enumerate(("#FF0000", "#00FF00", "#0000FF"))]
        scene.build({"parts": parts}, path)
        key = engine.load(path / "model.obj")
        keys.append(key)
        model = engine.models[key]
        assert all(state["detail"] is not None for state in model["materials"])
        detail_images = {state["detail"].image.as_pointer() for state in model["materials"]}
        assert len(detail_images) == 1, "Part colors duplicated the material image"
        pixels = engine.render(key, {}, 128, "8")
        assert np.ptp(pixels[..., :3]) > 0.1
        detail = next(value for name, value in engine.passes.items.items() if name[0] == "detail" and name[1][0] == key)
        assert np.ptp(detail[..., 0]) > 0.05, "Material detail pass is flat"
        assert len(engine.models) <= 2
        print(f"After model {index + 1}: {rss_mib()} MiB RSS")
    assert set(engine.models) == set(keys[-2:]), "Older Blender models were retained"
    key = engine.load(Path(keys[0]))
    assert key in engine.models and len(engine.models) == 2, "Evicted model was not imported again"
    engine.render(key, {}, 128, "8")

print("Blender memory checks passed")
