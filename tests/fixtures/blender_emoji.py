"""Run inside Blender: test real inline glyph layout and compositing, without network."""
import sys
import tempfile
from pathlib import Path
from unittest.mock import patch

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT / "backend"))
import renderer
import schema
import emoji

with tempfile.TemporaryDirectory() as directory:
    layer = renderer.TextLayer()
    resolve = emoji.asset
    def local_asset(sequence, provider):
        return resolve(sequence, provider) if sequence in emoji.ROBLOX else emoji.GLYPHS / "e000.png"
    with patch.object(emoji, "asset", side_effect=local_asset):
        settings = schema.normalize({"text": "Hi 😀👍🏽🇧🇷👨‍👩‍👧‍👦\\n\ue000 \ue001 \ue002 \ue003", "textSize": 48})
        rendered = layer.render(directory, settings, 256, "8")
        assert rendered.shape == (256, 256, 5)
        assert np.count_nonzero(rendered[..., 3]) > 100
        assert np.count_nonzero(rendered[..., 4]) > 100
        assert np.isfinite(rendered).all()
        assert not layer.objects, "Text objects must be released after rendering"
        rotated = layer.render(directory, dict(settings, textRotation=45), 256, "8")
        assert not np.array_equal(rendered, rotated)
        for code in range(0xE000, 0xE004):
            glyph = layer.render(directory, schema.normalize({"text": chr(code), "textSize": 80}), 128, "8")
            assert np.count_nonzero(np.maximum(glyph[..., 3], glyph[..., 4])) > 50
        plain = layer.render(directory, schema.normalize({"text": "Normal text"}), 128, "8")
        assert plain.shape == (128, 128) and np.count_nonzero(plain) > 0
        obj = Path(directory) / "cube.obj"
        obj.write_text("v -1 -1 0\nv 1 -1 0\nv 0 1 0\nf 1 2 3\n")
        engine = renderer.Renderer()
        key = engine.load(obj)
        with patch.object(engine.text, "render", wraps=engine.text.render) as draw:
            first = engine.render(key, settings, 128, "8")
            bounds = engine.text_bounds(settings, 128, "8")
            assert bounds and bounds["width"] > 0 and bounds["height"] > 0
            assert draw.call_count == 1
            engine.render(key, dict(settings, textOffsetX=30, textColor="#FF0000FF"), 128, "8")
            assert draw.call_count == 1, "Offsets and fill colors must reuse the glyph pass"
            engine.render(key, dict(settings, textEmojiProvider="apple"), 128, "8")
            assert draw.call_count == 2, "Provider changes must invalidate the text cache"
            assert np.isfinite(first).all()
print("Blender emoji, Roblox glyph, rotation, bounds and provider cache checks passed")
