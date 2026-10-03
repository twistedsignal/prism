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

    def model(self):
        pixels = np.zeros((48, 48, 4), dtype=np.float32)
        pixels[12:36, 12:36] = [0.8, 0.4, 0.1, 1]
        pixels[18:30, 18:30, :3] = [0.3, 0.6, 0.9]
        return pixels

    def test_every_new_effect_changes_the_image_and_stays_in_range(self):
        pixels = self.model()
        height, width = pixels.shape[:2]
        normals = np.zeros_like(pixels)
        normals[..., 2] = 1.0
        normals[12:36, 12:14, 2] = 0.5
        depth = np.zeros_like(pixels)
        depth[..., 0] = np.linspace(0, 1, width)[None, :]
        depth[18:30, 18:30, 0] = 0.0
        text = np.zeros((height, width), dtype=np.float32)
        text[20:28, 10:38] = 1
        flat = pixels.copy()
        flat[..., :3] = np.clip(pixels[..., :3] * 1.3, 0, 1)
        passes = {"normals": normals, "depth": depth, "text": text, "flat": flat}
        base = effects.post_process_pixels(pixels, schema.normalize({}), 48, passes=passes)
        cases = [
            {"colorOverlay": True}, {"celShading": True}, {"heatmap": True},
            {"heatmap": True, "heatmapSource": "depth"}, {"duotone": True}, {"tritone": True},
            {"halftone": True}, {"dither": True}, {"pixelate": True}, {"chromaticAberration": True},
            {"crt": True}, {"bloom": True, "bloomThreshold": 0.2}, {"xray": True}, {"depthTint": True},
            {"depthOutlineSize": 4}, {"innerShadow": True}, {"vignette": True}, {"text": "Hi"},
        ]
        for values in cases:
            with self.subTest(values=values):
                output = effects.post_process_pixels(pixels, schema.normalize(values), 48, passes=passes)
                self.assertEqual(output.shape, pixels.shape)
                self.assertTrue(np.all(np.isfinite(output)))
                self.assertGreaterEqual(output.min(), 0)
                self.assertLessEqual(output.max(), 1)
                self.assertFalse(np.allclose(output, base), "effect changed nothing")

    def test_text_is_drawn_above_the_color_overlay(self):
        pixels = self.model()
        text = np.zeros(pixels.shape[:2], dtype=np.float32)
        text[24, 24] = 1
        settings = schema.normalize({
            "colorOverlay": True, "colorOverlayColor": "#00FF00FF", "text": "x", "textColor": "#FF0000FF",
            "outlineSize": 0, "dropShadow": False,
        })
        output = effects.post_process_pixels(pixels, settings, 48, passes={"text": text})
        np.testing.assert_allclose(output[24, 24], [1, 0, 0, 1], atol=1e-6)
        np.testing.assert_allclose(output[14, 14], [0, 1, 0, 1], atol=1e-6)

    def test_overlay_alpha_controls_strength(self):
        pixels = self.model()
        settings = schema.normalize({"colorOverlay": True, "colorOverlayColor": "#00000080",
                                     "outlineSize": 0, "dropShadow": False})
        output = effects.post_process_pixels(pixels, settings, 48)
        np.testing.assert_allclose(output[14, 14, :3], np.array([0.8, 0.4, 0.1]) * (1 - 128 / 255), atol=1e-5)

    def test_vignette_covers_the_image_border(self):
        pixels = np.zeros((32, 32, 4), dtype=np.float32)
        settings = schema.normalize({"vignette": True, "vignetteStrength": 1, "vignetteOpacity": 1,
                                     "dropShadow": False})
        output = effects.post_process_pixels(pixels, settings, 32)
        self.assertGreater(output[0, 0, 3], 0.9)
        self.assertLess(output[16, 16, 3], 0.05)

    def test_required_passes(self):
        self.assertEqual(effects.required_passes(schema.normalize({})), set())
        self.assertEqual(effects.required_passes(schema.normalize({"xray": True})), {"normals"})
        self.assertEqual(effects.required_passes(schema.normalize({"heatmap": True})), set())
        self.assertEqual(effects.required_passes(schema.normalize({"heatmap": True, "heatmapSource": "depth"})), {"depth"})
        self.assertEqual(effects.required_passes(schema.normalize({"depthOutlineSize": 2})), {"depth"})
        self.assertEqual(effects.required_passes(schema.normalize({"celShading": True})), {"flat"})
        self.assertEqual(effects.required_passes(schema.normalize({"text": "  "})), set())
        self.assertEqual(effects.required_passes(schema.normalize({"text": "Hi", "textColor": "#FFFFFF00"})), set())
        self.assertEqual(effects.required_passes(schema.normalize({"text": "Hi"})), {"text"})


class SchemaTests(unittest.TestCase):
    def test_new_setting_types_are_validated(self):
        settings = schema.normalize({
            "colorOverlayColor": "#abcdef", "textColor": "12345678", "text": "Hi\x07there" + "x" * 200,
            "heatmapSource": "nope", "textFont": "Fredoka One",
        })
        self.assertEqual(settings["colorOverlayColor"], "#ABCDEFFF")
        self.assertEqual(settings["textColor"], "#12345678")
        self.assertTrue(settings["text"].startswith("Hithere"))
        self.assertEqual(len(settings["text"]), 120)
        self.assertEqual(settings["heatmapSource"], "brightness")
        self.assertEqual(settings["textFont"], "Fredoka One")
        self.assertEqual(schema.normalize({"colorOverlayColor": "red"})["colorOverlayColor"], "#FF3B3B80")

    def requirements(self):
        """Each setting's own requirement plus those inherited from its groups."""
        found = {}

        def visit(items, inherited):
            for item in items:
                needs = inherited + ([item["requires"]] if "requires" in item else [])
                if item.get("type") == "group":
                    visit(item["settings"], needs)
                else:
                    found[item["key"]] = needs

        for section in schema.SECTIONS:
            visit(section["settings"], [])
        return found

    def test_requirements_name_real_settings(self):
        for key, needs in self.requirements().items():
            for need in needs:
                self.assertIn(need.lstrip("!"), schema.SETTINGS, key)
                self.assertNotEqual(need.lstrip("!"), key)

    def test_hidden_effect_settings_never_change_the_render(self):
        pixels = np.zeros((32, 32, 4), dtype=np.float32)
        pixels[8:24, 8:24] = [0.8, 0.4, 0.1, 1]
        normals = np.zeros_like(pixels)
        normals[..., 2] = 0.8
        depth = np.zeros_like(pixels)
        depth[..., 0] = np.linspace(0, 1, 32)[None, :]
        text = np.zeros((32, 32), dtype=np.float32)
        text[12:20, 6:26] = 1
        passes = {"normals": normals, "depth": depth, "text": text, "flat": pixels.copy()}

        def off(need, values):
            key = need.lstrip("!")
            setting = schema.SETTINGS[key]
            if need.startswith("!"):
                values[key] = True
            elif setting["type"] == "bool":
                values[key] = False
            elif setting["type"] == "number":
                values[key] = 0
            else:
                values[key] = ""

        def changed(setting):
            kind = setting["type"]
            if kind == "bool":
                return not setting["default"]
            if kind == "number":
                return setting["max"] if setting["default"] != setting["max"] else setting["min"]
            if kind == "color":
                return "#123456"
            if kind == "rgba":
                return "#12345678"
            if kind == "select":
                others = [option["value"] for option in setting["options"] if option["value"] != setting["default"]]
                return others[0] if others else "Some font"
            return "changed"

        checked = 0
        for key, needs in self.requirements().items():
            if not needs or key not in schema.EFFECT_KEYS:
                continue
            values = {"dropShadow": False}
            for need in needs:
                off(need, values)
            with self.subTest(key=key):
                base = effects.post_process_pixels(pixels, schema.normalize(values), 32, passes=passes)
                values[key] = changed(schema.SETTINGS[key])
                hidden = effects.post_process_pixels(pixels, schema.normalize(values), 32, passes=passes)
                np.testing.assert_array_equal(hidden, base)
                checked += 1
        self.assertGreater(checked, 40)

    def test_effect_sections_never_rerender_in_blender(self):
        for key in ("text", "textFont", "xray", "vignetteOpacity", "colorOverlayColor", "saturation", "glow"):
            self.assertIn(key, schema.EFFECT_KEYS)
        for key in ("zoom", "cavity", "pitch", "exposure", "subdivision"):
            self.assertNotIn(key, schema.EFFECT_KEYS)


if __name__ == "__main__":
    unittest.main()
