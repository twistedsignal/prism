import base64
import sys
import tempfile
import unittest
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
import appearance
import part_surfaces
import scene

IDENTITY = [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1]


class SurfaceTests(unittest.TestCase):
    def test_all_types_on_all_faces_reach_obj(self):
        for surface in part_surfaces.TYPES:
            for face in part_surfaces.FACES:
                with self.subTest(surface=surface, face=face), tempfile.TemporaryDirectory() as directory:
                    scene.build({"parts": [{"kind": "block", "size": [4, 4, 4], "cframe": IDENTITY,
                                            "surfaces": {face: surface}, "transparency": 0.25}]}, directory)
                    obj = (Path(directory) / "model.obj").read_text()
                    mtl = (Path(directory) / "model.mtl").read_text()
                    self.assertEqual("map_Kd" in mtl, surface in part_surfaces.PATTERNS)
                    vertices = sum(line.startswith("v ") for line in obj.splitlines())
                    self.assertEqual(vertices > 36, surface in part_surfaces.PINS)
                    self.assertIn("d 0.750000", mtl)

    def test_grid_anchor_orientation_and_large_faces_keep_repeating_uvs(self):
        size = [101, 2.5, 99]
        for face in part_surfaces.FACES:
            groups, _, indices = part_surfaces.prepare(scene.block(size), size, "block", {face: "Universal"}, (0.5,) * 3, {})
            tiled = next(group for key, group in groups.items() if key is not None)
            uv = np.asarray([c[1] for c in tiled])
            width, height = part_surfaces.dimensions(face, size, "block")
            np.testing.assert_allclose(uv.min(axis=0), [0, 1 - height / 2])
            np.testing.assert_allclose(uv.max(axis=0), [width / 2, 1])
            self.assertEqual(len(tiled), 6)
            self.assertEqual(len(indices), 36)
        # Origins are the outside-view top-left corners, including top/bottom.
        anchors = {"Front": (0.5, 0.5, -0.5), "Back": (-0.5, 0.5, 0.5),
                   "Right": (0.5, 0.5, -0.5), "Left": (-0.5, 0.5, 0.5),
                   "Top": (0.5, 0.5, -0.5), "Bottom": (0.5, -0.5, 0.5)}
        for face, point in anchors.items():
            np.testing.assert_allclose(appearance.project([point], face, [1, 1, 1]), [[0, 0]])

    def test_wedge_surface_ids_and_studio_slope_spacing(self):
        for kind, face, expected in (("wedge", "Front", 6), ("cornerWedge", "Back", 3), ("cornerWedge", "Left", 3)):
            corners = scene.PRIMITIVES[kind]([4, 4, 4])
            groups, layers, indices = part_surfaces.prepare(corners, [4, 4, 4], kind, {face: "Studs"}, (0.5,) * 3, {})
            tiled = next(group for key, group in groups.items() if key)
            self.assertEqual(len(tiled), expected)
            self.assertEqual(layers[0]["repeat"], [2, 1])
            self.assertEqual(np.ptp([uv[1] for _, uv, _ in tiled]), 4)
            self.assertTrue(all(part_surfaces.FACES[i] == face for i in indices if i == part_surfaces.FACES.index(face)))
        groups, layers, _ = part_surfaces.prepare(scene.wedge([4, 4, 4]), [4, 4, 4], "wedge", {"Top": "Studs"}, (0.5,) * 3, {})
        self.assertIsNone(groups)
        self.assertEqual(layers, [])

    def test_texture_neutral_tint_and_distinct_patterns(self):
        data = []
        for kind in ("Studs", "Weld", "Inlet", "Universal"):
            _, _, pixels = scene.decode_texture(part_surfaces.texture(kind, (0.5, 0.25, 0)))
            image = np.frombuffer(pixels, np.uint8).reshape(128, 128, 4)
            self.assertTrue(np.all(image[..., 2] == 0))
            self.assertTrue(np.all(image[..., 3] == 255))
            self.assertGreater(np.ptp(image[..., 0]), 50)
            np.testing.assert_array_equal(image[0, 0], [128, 64, 0, 255])
            data.append(pixels)
        self.assertEqual(len(set(data)), 4)
        self.assertEqual(part_surfaces.texture("Glue", (0.5,) * 3), part_surfaces.texture("Weld", (0.5,) * 3))

    def test_pins_follow_every_face_and_preserve_part_transform(self):
        for face in part_surfaces.FACES:
            index = part_surfaces.FACES.index(face)
            axis, sign = index // 2, 1 if index % 2 == 0 else -1
            pins = list(part_surfaces.indicators(scene.block([4, 4, 4]), "block", {face: "Motor"}))
            self.assertEqual(len(pins), 2)
            points = np.asarray([c[0] for c in pins[-1][0]])
            extent = points[:, axis] * sign
            np.testing.assert_allclose([extent.min(), extent.max()], [2, 2.5])
            other_axes = [a for a in range(3) if a != axis]
            np.testing.assert_allclose(np.ptp(points[:, other_axes], axis=0), [0.4, 0.4], atol=1e-6)
        transform = [10, 20, 30, 0, -1, 0, 1, 0, 0, 0, 0, 1]
        with tempfile.TemporaryDirectory() as directory:
            scene.build({"parts": [{"kind": "block", "size": [4, 4, 4], "cframe": transform,
                                    "surfaces": {"Top": "Hinge"}}]}, directory)
            points = np.asarray([[float(v) for v in line.split()[1:]] for line in
                                (Path(directory) / "model.obj").read_text().splitlines() if line.startswith("v ")])
            np.testing.assert_allclose(points.min(axis=0), [7.5, 18, 28])

    def test_decals_cover_surface_detail_and_materials_keep_their_texture(self):
        textures = {}
        corners = scene.block([4, 4, 4])
        _, layers, indices = part_surfaces.prepare(corners, [4, 4, 4], "block", {"Top": "Studs"}, (0.5,) * 3, textures)
        textures["decal"] = {"width": 1, "height": 1, "pixels": base64.b64encode(bytes([255, 0, 0, 255])).decode()}
        _, baked = appearance.bake(corners, [4, 4, 4], (0.5,) * 3, None,
                                   layers + [{"id": "decal", "face": "Top"}], textures, surface_faces=indices)
        _, _, pixels = scene.decode_texture(baked)
        atlas = np.frombuffer(pixels, np.uint8).reshape(520, 780, 4)
        np.testing.assert_array_equal(atlas[100, 620], [255, 0, 0, 255])
        with tempfile.TemporaryDirectory() as directory:
            scene.build({"parts": [{"kind": "block", "size": [4, 4, 4], "cframe": IDENTITY,
                                    "material": {"name": "Wood"}, "surfaces": {"Top": "Motor"}}]}, directory)
            mtl = (Path(directory) / "model.mtl").read_text()
            self.assertIn("map_Ke", mtl)
            self.assertNotIn("map_Kd", mtl)

    def test_invalid_surface_payload_is_rejected(self):
        for bad in ([], "Studs", {"Top": "Unknown"}, {"Side": "Studs"}, {"Top": 3}):
            with self.assertRaises(scene.SceneError):
                part_surfaces.validate(bad)


if __name__ == "__main__":
    unittest.main()
