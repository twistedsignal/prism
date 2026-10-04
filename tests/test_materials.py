import base64
import json
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
import assets
import materials
import scene

IDENTITY = [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1]


def block(material, color="#808080", **extra):
    return {"kind": "block", "cframe": IDENTITY, "size": [8, 2, 4], "color": color, "material": material, **extra}


def texture_of(width, height, value):
    pixels = np.full((height, width, 4), value, dtype=np.uint8)
    return {"width": width, "height": height, "pixels": base64.b64encode(pixels.tobytes()).decode()}


class MaterialTextureTests(unittest.TestCase):
    def test_every_material_texture_tiles_and_stays_in_range(self):
        cases = [(name, False) for name in materials.GENERATORS]
        cases += [(name, True) for name in materials.LEGACY_GENERATORS]
        for name, legacy in cases:
            with self.subTest(name=name, legacy=legacy):
                data = materials.texture(name, legacy)
                pixels = np.frombuffer(base64.b64decode(data["pixels"]), np.uint8).reshape(256, 256, 4)
                self.assertTrue(np.all(pixels[..., 3] == 255))
                gray = pixels[..., 0].astype(np.float32) / 255
                self.assertGreater(gray.mean(), 0.55)
                self.assertGreater(np.ptp(gray), 0.05, "material has no visible detail")
                # Seamless: the wrap-around step is no larger than steps inside the tile.
                inner = np.abs(np.diff(gray, axis=1)).max(axis=0).mean()
                self.assertLessEqual(np.abs(gray[:, 0] - gray[:, -1]).mean(), inner * 2 + 0.02)

    def test_no_material_looks_like_wood_grain(self):
        # Grain is long streaks: rows stay similar along one axis but vary across it.
        def gray(name):
            pixels = np.frombuffer(base64.b64decode(materials.texture(name)["pixels"]), np.uint8)
            return pixels.reshape(256, 256, 4)[..., 0].astype(np.float32) / 255

        for name in ("Grass", "Slate", "Sandstone", "LeafyGrass"):
            with self.subTest(name=name):
                along = np.abs(np.diff(gray(name), axis=1)).mean()
                across = np.abs(np.diff(gray(name), axis=0)).mean()
                self.assertLess(max(along, across) / max(min(along, across), 1e-6), 3.0)
        # Brushed metal has direction, but only as faint hairlines, never as broad bands.
        metal = gray("Metal")
        self.assertLess(max(metal.mean(axis=0).std(), metal.mean(axis=1).std()), 0.006)

    def test_legacy_materials_only_change_materials_that_existed(self):
        self.assertTrue(materials.is_legacy("Wood", True))
        self.assertFalse(materials.is_legacy("Wood", False))
        self.assertFalse(materials.is_legacy("Carpet", True), "Carpet was added with the 2022 materials")
        self.assertNotEqual(materials.texture("Grass", True)["pixels"], materials.texture("Grass")["pixels"])

    def test_plain_materials_have_no_texture(self):
        for name in ("Plastic", "SmoothPlastic", "Neon", "Glass", "ForceField"):
            self.assertFalse(materials.has_texture(name))


class SceneMaterialTests(unittest.TestCase):
    def build(self, parts, textures=None):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        scene.build({"parts": parts, "textures": textures or {}}, directory.name)
        root = Path(directory.name)
        return (root / "model.obj").read_text(), (root / "model.mtl").read_text(), root

    def uvs(self, obj):
        return np.array([[float(v) for v in line.split()[1:]] for line in obj.splitlines() if line.startswith("vt ")])

    def test_built_in_material_tiles_in_studs(self):
        obj, mtl, root = self.build([block({"name": "Wood"})])
        self.assertIn("map_Ke", mtl)
        self.assertNotIn("map_Kd", mtl)
        uvs = self.uvs(obj)
        # An 8-stud face spans two 4-stud Wood tiles.
        self.assertAlmostEqual(np.ptp(uvs[:, 0]), 2.0, places=5)

    def test_legacy_places_use_legacy_material_textures(self):
        def detail(legacy):
            directory = tempfile.TemporaryDirectory()
            self.addCleanup(directory.cleanup)
            payload = {"parts": [block({"name": "Grass"}), block({"name": "Carpet"})], "legacyMaterials": legacy}
            scene.build(payload, directory.name)
            return sorted(path.read_bytes() for path in Path(directory.name).glob("detail*.png"))

        modern, legacy = detail(False), detail(True)
        self.assertEqual(len(modern), 2)
        self.assertEqual(len(set(modern) & set(legacy)), 1, "Only Grass has a legacy texture")

    def test_plastic_and_textured_parts_ignore_the_material(self):
        _, mtl, _ = self.build([block({"name": "Plastic"})])
        self.assertNotIn("map_Kd", mtl)
        textures = {"face": texture_of(4, 4, 200)}
        obj, _, _ = self.build([block({"name": "Wood"}, texture={"id": "face", "mode": "overlay"})], textures)
        self.assertLessEqual(self.uvs(obj).max(), 1.0 + 1e-6, "TextureIDs replace material tiling")

    def test_variant_color_map_uses_its_studs_per_tile(self):
        textures = {"oak": texture_of(8, 8, 180)}
        obj, mtl, _ = self.build([block({"name": "Wood", "studsPerTile": 2, "texture": {"id": "oak"}})], textures)
        self.assertAlmostEqual(np.ptp(self.uvs(obj)[:, 0]), 4.0, places=5)

    def test_material_is_tinted_by_part_color(self):
        _, mtl, root = self.build([
            block({"name": "Concrete"}, color="#FF0000"),
            block({"name": "Concrete"}, color="#00FF00"),
        ])
        import zlib
        self.assertEqual(mtl.count("map_Ke"), 2)
        self.assertEqual(len(list(root.glob("detail*.png"))), 1)
        self.assertNotIn("map_Kd", mtl)
        png = (root / mtl.split("map_Ke ")[1].split()[0]).read_bytes()
        data = zlib.decompress(png[png.index(b"IDAT") + 4:png.index(b"IEND") - 8])
        rows = np.frombuffer(data, np.uint8).reshape(256, 1 + 256 * 4)[:, 1:].reshape(256, 256, 4)
        self.assertTrue(np.array_equal(rows[..., 0], rows[..., 1]))
        self.assertTrue(np.array_equal(rows[..., 1], rows[..., 2]))
        self.assertIn("Kd 1.000000 0.000000 0.000000", mtl)
        self.assertIn("Kd 0.000000 1.000000 0.000000", mtl)

    def test_neon_is_brightened(self):
        _, plain, _ = self.build([block({"name": "SmoothPlastic"}, color="#004080")])
        _, neon, _ = self.build([block({"name": "Neon"}, color="#004080")])
        brightness = lambda mtl: sum(float(v) for v in mtl.split("Kd ")[1].split()[:3])
        self.assertGreater(brightness(neon), brightness(plain))

    def test_decals_sit_on_top_of_the_material(self):
        textures = {"decal": texture_of(4, 4, 255)}
        decal = {"id": "decal", "face": "Front", "transparency": 0, "tint": [1, 1, 1]}
        _, mtl, _ = self.build([block({"name": "Brick"}, layers=[decal])], textures)
        self.assertIn("map_Kd", mtl)


class ResolverMaterialTests(unittest.TestCase):
    def test_variant_texture_downloads_and_falls_back_to_the_base_material(self):
        with tempfile.TemporaryDirectory() as directory:
            resolver = assets.Resolver(directory)
            part = block({"name": "Wood", "variant": "Oak", "texture": {"assetId": "555", "mode": "overlay"}})
            with patch.object(resolver, "texture", return_value=texture_of(2, 2, 90)):
                payload, warnings, incomplete = resolver.resolve({"parts": [json.loads(json.dumps(part))]})
            self.assertEqual(payload["parts"][0]["material"]["texture"]["id"], "555")
            self.assertIn("555", payload["textures"])
            self.assertFalse(incomplete)
            with patch.object(resolver, "texture", side_effect=assets.AssetError("denied")):
                payload, warnings, incomplete = resolver.resolve({"parts": [json.loads(json.dumps(part))]})
            self.assertNotIn("texture", payload["parts"][0]["material"])
            self.assertTrue(any("base material" in warning for warning in warnings))
            self.assertTrue(incomplete)


if __name__ == "__main__":
    unittest.main()
