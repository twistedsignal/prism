import sys
import unittest
from pathlib import Path
from unittest.mock import patch

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
import effects
import schema
from render_cache import RenderCache


class EffectsTests(unittest.TestCase):
    def check_disk(self, mask, radius):
        yy, xx = np.indices(mask.shape)
        expected = np.empty_like(mask)
        for y, x in np.ndindex(mask.shape):
            neighbors = (yy - y) ** 2 + (xx - x) ** 2 <= radius ** 2
            expected[y, x] = mask[neighbors].max()
        np.testing.assert_array_equal(effects.dilate_mask(mask, radius), expected)

    def test_disk_filter_preserves_soft_edges_translucency_and_borders(self):
        random = np.random.default_rng(42)
        for radius in (0, 1, 3, 7, 20):
            self.check_disk(random.random((11, 13), dtype=np.float32), radius)
        mask = np.zeros((25, 27), dtype=np.float32)
        mask[4:20, 4:21] = 1
        mask[3, 4:21] = 0.3
        mask[20, 4:21] = 0.7
        for radius in (3, 6):
            self.check_disk(mask, radius)
        self.check_disk((mask > 0).astype(np.float32), 8)

    def test_gaussian_matches_direct_convolution_with_zero_padding(self):
        mask = np.random.default_rng(12).random((17, 19), dtype=np.float32)
        mask[0, 0] = 1
        for sigma in (0, 0.5, 1.1, 4, 20):
            expected = mask.copy()
            if sigma:
                radius = int(np.ceil(3 * sigma))
                offsets = np.arange(-radius, radius + 1, dtype=np.float64)
                kernel = np.exp(-0.5 * (offsets / sigma) ** 2)
                kernel /= kernel.sum()
                for axis in (0, 1):
                    expected = np.apply_along_axis(
                        lambda row: np.convolve(row, kernel)[radius:radius + len(row)], axis, expected,
                    )
            np.testing.assert_allclose(effects.blur_mask(mask, sigma), expected, atol=1e-6)

    def test_post_processing_preserves_input_and_straight_alpha(self):
        pixels = np.array([[[0.8, 0.3, 0.1, 0.5]]], dtype=np.float32)
        original = pixels.copy()
        settings = schema.normalize({"outlineSize": 0, "dropShadow": False})
        np.testing.assert_allclose(effects.post_process_pixels(pixels, settings, 512), pixels)
        np.testing.assert_array_equal(pixels, original)
        settings.update(saturation=0, brightness=0.5)
        output = effects.post_process_pixels(pixels, settings, 512)
        gray = (0.8 * 0.2126 + 0.3 * 0.7152 + 0.1 * 0.0722) * 0.5
        np.testing.assert_allclose(output[0, 0], [gray, gray, gray, 0.5], atol=1e-7)
        np.testing.assert_array_equal(pixels, original)

    def test_mask_cache_survives_color_opacity_and_offset_edits(self):
        pixels = np.zeros((64, 64, 4), dtype=np.float32)
        pixels[16:48, 16:48] = [0.8, 0.4, 0.1, 1]
        cache = RenderCache()
        settings = schema.normalize({"glow": True})
        effects.post_process_pixels(pixels, settings, 128, cache, "scene")
        edited = {**settings, "saturation": 0.3, "glowColor": "#FF0000", "shadowOpacity": 0.9, "shadowOffsetX": 8}
        with patch.object(effects, "blur_mask", side_effect=AssertionError("Mask recomputed")):
            cached = effects.post_process_pixels(pixels, edited, 128, cache, "scene")
        np.testing.assert_array_equal(cached, effects.post_process_pixels(pixels, edited, 128))


if __name__ == "__main__":
    unittest.main()
