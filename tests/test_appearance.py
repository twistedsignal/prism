import base64
import sys
import tempfile
import unittest
import urllib.error
from pathlib import Path
from unittest.mock import patch

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
import appearance
import render_cache
import scene
from test_assets import mesh_v2

import assets


def texture(pixels):
    pixels = np.asarray(pixels, dtype=np.uint8)
    return {
        "width": pixels.shape[1],
        "height": pixels.shape[0],
        "pixels": base64.b64encode(pixels.tobytes()).decode("ascii"),
    }


def texel(baked, uv):
    w, h, data = scene.decode_texture(baked)
    x, y = min(int(uv[0] * w), w - 1), min(int((1 - uv[1]) * h), h - 1)
    return tuple(data[(y * w + x) * 4 : (y * w + x) * 4 + 4])


class AppearanceTests(unittest.TestCase):
    def test_classic_head_uses_builtin_geometry_and_nonuniform_scale(self):
        original = scene.head([1, 1, 1])
        scaled = scene.head([1.25, 2, 0.75])
        self.assertEqual(len(original), 846 * 3)
        for (point, uv, normal), (new_point, new_uv, new_normal) in zip(original, scaled):
            np.testing.assert_allclose(new_point, np.asarray(point) * [1.25, 2, 0.75])
            self.assertEqual(uv, new_uv)
            np.testing.assert_allclose(new_normal, np.asarray(normal) / [1.25, 2, 0.75])
        bounds = np.ptp([point for point, _, _ in original], axis=0)
        np.testing.assert_allclose(bounds, [1.1978490, 1.2024246, 1.1978490], atol=1e-6)

    def test_classic_head_face_preserves_original_geometry(self):
        original = scene.head([1.25] * 3)
        corners, baked = appearance.bake(
            original, [2, 1, 1], (1, 0, 0), None,
            [{"id": "face", "face": "Front"}],
            {"face": texture([[[0, 0, 255, 255]]])},
        )
        self.assertEqual([c[0] for c in corners], [c[0] for c in original])
        self.assertEqual([c[2] for c in corners], [c[2] for c in original])
        colors = [texel(baked, uv) for _, uv, _ in corners]
        self.assertIn((0, 0, 255, 255), colors)
        self.assertIn((255, 0, 0, 255), colors)

    def test_clothing_and_face_alpha_preserve_geometry(self):
        template = np.zeros((559, 585, 4), dtype=np.uint8)
        for x, y, w, h in appearance.RECTS["torso"].values():
            template[y : y + h, x : x + w] = [255, 0, 0, 255]
        textures = {"shirt": texture(template), "face": texture([[[0, 0, 255, 128]]])}
        original = scene.block([2, 2, 1])
        corners, baked = appearance.bake(
            original,
            [2, 2, 1],
            (0, 1, 0),
            None,
            [{"id": "shirt", "region": "torso"}, {"id": "face", "face": "Front"}],
            textures,
        )
        self.assertEqual([c[0] for c in corners], [c[0] for c in original])
        self.assertEqual([c[2] for c in corners], [c[2] for c in original])
        for _, uv, normal in corners:
            self.assertEqual(
                texel(baked, uv),
                (127, 0, 128, 255) if normal[2] < 0 else (255, 0, 0, 255),
            )

    def test_r15_segments_sample_different_template_rows(self):
        template = np.zeros((559, 585, 4), dtype=np.uint8)
        template[74:138, 231:359] = [255, 0, 0, 255]
        template[138:202, 231:359] = [0, 0, 255, 255]
        for low, high, expected in (
            (0, 0.49, (255, 0, 0, 255)),
            (0.51, 1, (0, 0, 255, 255)),
        ):
            corners, baked = appearance.bake(
                scene.block([2, 1, 1]),
                [2, 1, 1],
                (0, 1, 0),
                None,
                [{"id": "shirt", "region": "torso", "range": [low, high]}],
                {"shirt": texture(template)},
            )
            for _, uv, normal in corners:
                if normal[2] < 0:
                    self.assertEqual(texel(baked, uv), expected)

    def test_shirt_over_pants_and_decal_tint_transparency(self):
        corners, baked = appearance.bake(
            scene.block([2, 2, 1]),
            [2, 2, 1],
            (0, 1, 0),
            None,
            [
                {"id": "pants", "region": "torso"},
                {"id": "shirt", "region": "torso"},
                {"id": "face", "face": "Front", "transparency": 1},
            ],
            {
                "pants": texture([[[0, 0, 255, 255]]]),
                "shirt": texture([[[255, 0, 0, 255]]]),
                "face": texture([[[0, 255, 0, 255]]]),
            },
        )
        self.assertTrue(
            all(texel(baked, uv) == (255, 0, 0, 255) for _, uv, _ in corners)
        )

    def test_spherical_head_face_uses_surface_normals(self):
        corners, baked = appearance.bake(
            scene.ball([2.5, 1.25, 1.25]),
            [2.5, 1.25, 1.25],
            (1, 0, 0),
            None,
            [{"id": "face", "face": "Front"}],
            {"face": texture([[[0, 0, 255, 255]]])},
        )
        colors = [texel(baked, uv) for _, uv, _ in corners]
        self.assertIn((0, 0, 255, 255), colors)
        self.assertIn((255, 0, 0, 255), colors)

    def test_tshirt_graphic_spans_torso_segments(self):
        for low, high, color in (
            (0, 0.49, (255, 0, 0, 255)),
            (0.51, 1, (0, 0, 255, 255)),
        ):
            corners, baked = appearance.bake(
                scene.block([2, 1, 1]),
                [2, 1, 1],
                (0, 1, 0),
                None,
                [
                    {
                        "id": "graphic",
                        "face": "Front",
                        "graphic": True,
                        "range": [low, high],
                    }
                ],
                {"graphic": texture([[[255, 0, 0, 255]], [[0, 0, 255, 255]]])},
            )
            for _, uv, normal in corners:
                self.assertEqual(
                    texel(baked, uv), color if normal[2] < 0 else (0, 255, 0, 255)
                )

    def test_base_texture_preserved_under_transparent_layer(self):
        corners, baked = appearance.bake(
            scene.block([1, 1, 1]),
            [1, 1, 1],
            (1, 0, 0),
            {"id": "base", "mode": "overlay"},
            [{"id": "decal", "face": "Front"}],
            {
                "base": texture([[[0, 255, 0, 255]]]),
                "decal": texture([[[0, 0, 255, 0]]]),
            },
        )
        self.assertTrue(
            all(texel(baked, uv) == (0, 255, 0, 255) for _, uv, _ in corners)
        )


class RecoveryCacheTests(unittest.TestCase):
    def test_decoded_cache_reused_after_restart(self):
        with tempfile.TemporaryDirectory() as temporary:
            first = assets.Resolver(temporary)
            with patch.object(assets, "read_public", return_value=mesh_v2()):
                expected = first.mesh("123")
            second = assets.Resolver(temporary)
            with patch.object(
                assets.mesh_asset, "decode", side_effect=AssertionError("Decoded twice")
            ):
                self.assertEqual(second.mesh("123"), expected)
            # Corrupt entries must be rebuilt rather than treated as successful assets.
            (second.root / "123.mesh.json").write_text("broken JSON")
            third = assets.Resolver(temporary)
            self.assertEqual(third.mesh("123"), expected)

    def test_denied_legacy_route_skipped_after_failed_auth_and_restart(self):
        with tempfile.TemporaryDirectory() as temporary:
            resolver = assets.Resolver(temporary)
            with (
                patch.object(
                    assets,
                    "read_public",
                    side_effect=urllib.error.HTTPError("url", 403, "", None, None),
                ) as public,
                patch.object(assets.uploader, "find_raven", return_value=None),
            ):
                with self.assertRaises(assets.AssetError):
                    resolver.download("123")
                self.assertEqual(public.call_count, 1)
            resolver = assets.Resolver(temporary)
            with (
                patch.object(
                    assets,
                    "read_public",
                    side_effect=AssertionError("Retried denied legacy"),
                ),
                patch.object(assets.uploader, "find_raven", return_value=None),
                self.assertRaises(assets.AssetError),
            ):
                resolver.download("123")
            self.assertFalse((resolver.root / "123").exists())

    def test_asset_document_image_reference(self):
        with tempfile.TemporaryDirectory() as temporary:
            resolver = assets.Resolver(temporary)
            document = b'<roblox><Content name="Texture"><url>rbxassetid://456</url></Content></roblox>'
            expected = texture([[[255, 0, 0, 128]]])
            with (
                patch.object(resolver, "download", return_value=document),
                patch.object(resolver, "texture", return_value=expected) as load,
            ):
                self.assertEqual(resolver.load_texture("123", document, 0), expected)
                load.assert_called_once_with("456", 1)
            with self.assertRaises(assets.AssetError):
                resolver.texture("123", 5)

    def test_render_cache_bounded_lru(self):
        cache = render_cache.RenderCache(max_bytes=8)
        a, b, c = (np.zeros(4, dtype=np.uint8) for _ in range(3))
        cache.put("a", a)
        cache.put("b", b)
        self.assertIs(cache.get("a"), a)
        cache.put("c", c)
        self.assertIsNone(cache.get("b"))
        self.assertIs(cache.get("a"), a)
        cache.put("oversized", np.zeros(9, dtype=np.uint8))
        self.assertEqual(cache.bytes, 8)
        self.assertIsNone(cache.get("oversized"))


if __name__ == "__main__":
    unittest.main()
