import base64
import gzip
import io
import json
import struct
import sys
import tempfile
import unittest
from pathlib import Path
from types import ModuleType, SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
import mesh_asset
import scene
import updater
import uploader

import assets


def mesh_v2(indices=(0, 1, 2)):
    vertices = b"".join(
        struct.pack("<8fI4B", *p, 0, 0, 1, 0, 0, 0, 255, 255, 255, 255)
        for p in ((0, 0, 0), (1, 0, 0), (0, 1, 0))
    )
    return (
        b"version 2.00\n"
        + struct.pack("<HBBII", 12, 40, 12, 3, 1)
        + vertices
        + struct.pack("<3I", *indices)
    )


def part(identifier="123"):
    return {
        "kind": "mesh",
        "mesh": {
            "assetId": identifier,
            "scale": [2, 3, 4],
            "offset": [1, 2, 3],
            "center": False,
        },
        "size": [1, 1, 1],
        "cframe": [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1],
        "color": "#FFFFFF",
    }


class MeshTests(unittest.TestCase):
    def test_v1_and_v3(self):
        values = b"[0,0,0][0,1,0][0,0,0][2,0,0][0,1,0][1,0,0][0,2,0][0,1,0][0,1,0]"
        decoded = mesh_asset.decode(b"version 1.00\r\n1\r\n" + values)
        self.assertEqual(
            struct.unpack("<9f", base64.b64decode(decoded["positions"])),
            (0, 0, 0, 1, 0, 0, 0, 1, 0),
        )
        data = mesh_v2()
        binary = (
            b"version 3.00\n"
            + struct.pack("<HBBHHII", 16, 40, 12, 4, 2, 3, 1)
            + data[25:]
            + struct.pack("<2I", 0, 1)
        )
        self.assertEqual(
            mesh_asset.decode(binary)["positions"], mesh_asset.decode(data)["positions"]
        )

    def test_ascii_uvs_normalized_without_changing_binary_uvs(self):
        vectors = b"[0,0,0][0,0,1][0.2,0.3,0]" * 3
        for version in (b"1.00", b"1.01"):
            mesh = mesh_asset.decode(b"version " + version + b"\n1\n" + vectors)
            uv = struct.unpack("<6f", base64.b64decode(mesh["uvs"]))
            self.assertAlmostEqual(uv[0], 0.2)
            self.assertAlmostEqual(uv[1], 0.7)
            self.assertAlmostEqual(scene.mesh_corners(mesh)[0][1][1], 0.3)
        self.assertEqual(base64.b64decode(mesh_asset.decode(mesh_v2())["uvs"]), bytes(24))

    def test_classic_soccer_ball_uvs_and_winding(self):
        fixture = Path(__file__).parent / "fixtures" / "soccer" / "ball.mesh"
        corners = scene.mesh_corners({**mesh_asset.decode(fixture.read_bytes()), "center": False})
        groups = {}
        for start in range(0, len(corners), 3):
            triangle = corners[start:start + 3]
            normal = scene.face_normal(*(corner[0] for corner in triangle))
            self.assertGreater(sum(normal[a] * triangle[0][2][a] for a in range(3)), 0)
            key = tuple(round(n, 3) for n in normal)
            groups.setdefault(key, []).extend(triangle)
        polygon_counts = {5: 0, 6: 0}
        for polygon in groups.values():
            count = len({tuple(round(v, 4) for v in corner[0]) for corner in polygon})
            polygon_counts[count] += 1
            # PNG's dark pentagon is above its white hexagon. OBJ V is bottom-up.
            v = sum(corner[1][1] for corner in polygon) / len(polygon)
            if count == 5:
                self.assertGreater(v, 0.5)
            else:
                self.assertLess(v, 0.5)
        self.assertEqual(polygon_counts, {5: 12, 6: 20})

    def test_v2_and_transform(self):
        mesh = mesh_asset.decode(mesh_v2())
        self.assertEqual(len(base64.b64decode(mesh["positions"])), 36)
        corners = scene.mesh_corners({**mesh, **part()["mesh"]})
        self.assertEqual(corners[0][0], (1, 2, 3))
        self.assertEqual(corners[1][0], (3, 2, 3))
        self.assertEqual(corners[2][0], (1, 5, 3))
        centered = scene.mesh_corners({**mesh, "scale": [2, 2, 2], "center": True})
        self.assertEqual(centered[0][0], (-1, -1, 0))

    def test_v4_lod_and_envelopes(self):
        data = mesh_v2()
        vertices = data[25:145]
        header = struct.pack("<HHIIHHIHH", 24, 4, 3, 2, 3, 1, 0, 0, 1)
        binary = (
            b"version 4.01\n"
            + header
            + vertices
            + bytes(3 * 8)
            + struct.pack("<6I3I", 0, 1, 2, 2, 1, 0, 0, 1, 2)
        )
        self.assertEqual(
            mesh_asset.decode(binary)["positions"], mesh_asset.decode(data)["positions"]
        )

    def test_v7_keeps_only_the_highest_detail_level(self):
        core = b"draco"
        # LODS revision 1: type, high quality count, then face offsets per level.
        lods = struct.pack("<HBI5I", 4, 1, 5, 0, 388, 507, 569, 581)
        binary = (
            b"version 7.00\n"
            + struct.pack("<8sII", b"COREMESH", 2, len(core) + 4) + struct.pack("<I", len(core)) + core
            + struct.pack("<8sII", b"LODS\0\0\0\0", 1, len(lods)) + lods
        )
        with patch.object(mesh_asset, "draco_mesh", return_value={}) as draco:
            mesh_asset.decode(binary)
        draco.assert_called_once_with(core, (0, 388, 507, 569, 581))
        self.assertEqual(mesh_asset.lod0_range((0, 388, 507, 569, 581), 581), (0, 388))
        self.assertEqual(mesh_asset.lod0_range((), 581), (0, 581))
        with self.assertRaises(mesh_asset.MeshError):
            mesh_asset.lod0_range((0, 600), 581)

    def test_legacy_draco_library_lookup(self):
        modules = {}
        for name in ("io_scene_gltf2", "io_scene_gltf2.io", "io_scene_gltf2.io.com"):
            modules[name] = ModuleType(name)
            modules[name].__path__ = []
        legacy = ModuleType(
            "io_scene_gltf2.io.com.gltf2_io_draco_compression_extension"
        )
        legacy.dll_path = lambda: "/bundled/libextern_draco.so"
        modules[legacy.__name__] = legacy
        with (
            patch.dict(sys.modules, modules),
            patch.object(mesh_asset.ct, "CDLL", side_effect=OSError("fixture")) as load,
            self.assertRaises(mesh_asset.MeshError),
        ):
            mesh_asset.draco_mesh(b"fixture")
        load.assert_called_once_with("/bundled/libextern_draco.so")

    def test_malformed(self):
        for data in (
            b"bad",
            b"version 9.00\n",
            mesh_v2()[:-1],
            mesh_v2((0, 1, 5)),
            b"version 7.00\nCOREMESH",
            b"version 7.00\n" + struct.pack("<8sII", b"COREMESH", 2, 100),
        ):
            with self.subTest(data=data[:20]), self.assertRaises(mesh_asset.MeshError):
                mesh_asset.decode(data)


class ResolverTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.resolver = assets.Resolver(self.temporary.name)

    def tearDown(self):
        self.temporary.cleanup()

    def test_public_gzip_delivery_and_expanded_size_limit(self):
        response = io.BytesIO(gzip.compress(mesh_v2()))
        response.headers = {"Content-Encoding": "gzip"}
        with patch.object(assets.urllib.request, "urlopen", return_value=response):
            self.assertEqual(assets.read_public("123"), mesh_v2())
        response = io.BytesIO(gzip.compress(b"x" * 100))
        response.headers = {"Content-Encoding": "gzip"}
        with (patch.object(assets.urllib.request, "urlopen", return_value=response),
              patch.object(assets, "MAX_BYTES", 50), self.assertRaises(assets.AssetError)):
            assets.read_public("123")

    def test_public_and_cache(self):
        with (
            patch.object(assets, "read_public", return_value=mesh_v2()) as public,
            patch.object(assets, "run_raven") as raven,
        ):
            self.assertEqual(self.resolver.download("123"), mesh_v2())
            self.assertEqual(self.resolver.download("123"), mesh_v2())
            self.assertEqual(public.call_count, 1)
            raven.assert_not_called()

    def test_old_mesh_decode_cache_is_rebuilt(self):
        import hashlib
        data = mesh_v2()
        cache = self.resolver.root / "123.mesh.json"
        cache.write_text(json.dumps({"digest": hashlib.sha256(data).hexdigest(),
                                     "data": {"uvs": "old flipped UVs"}}))
        with patch.object(self.resolver, "download", return_value=data):
            result = self.resolver.mesh("123")
        self.assertEqual(result, mesh_asset.decode(data))
        self.assertEqual(json.loads(cache.read_text())["revision"], assets.MESH_DECODER_VERSION)

    def test_authenticated_fallback(self):
        def download(_, args, **kwargs):
            Path(args[-1]).write_bytes(mesh_v2())
            return type(
                "Result",
                (),
                {
                    "returncode": 0,
                    "stdout": json.dumps({"assetId": "123", "bytes": len(mesh_v2())}),
                },
            )()

        with (
            patch.object(assets, "read_public", side_effect=OSError("401")),
            patch.object(assets.uploader, "find_raven", return_value="raven"),
            patch.object(assets, "run_raven", side_effect=download),
        ):
            self.assertEqual(self.resolver.download("123"), mesh_v2())
        self.assertFalse(list(self.resolver.root.glob(".*")))

    def test_failure_then_credentials_repaired_and_scene_cache(self):
        payload = {"parts": [part()], "textures": [], "warnings": ["Union warning"]}
        cache = scene.SceneCache(self.temporary.name, self.resolver)
        with patch.object(
            self.resolver,
            "download",
            side_effect=assets.AssetError("Add Legacy Assets Manage"),
        ):
            identifier, warnings = cache.add(b"payload", payload)
            self.assertIn("using a box", warnings[0])
            self.assertIn("Union warning", warnings)
            failed_id = identifier
        with patch.object(self.resolver, "download", return_value=mesh_v2()):
            identifier, warnings = cache.add(b"payload", payload)
            self.assertNotEqual(failed_id, identifier)
            self.assertEqual(warnings, ["Union warning"])
            again, cached_warnings = cache.add(b"payload", payload)
            self.assertEqual((again, cached_warnings), (identifier, warnings))
        self.assertNotIn(
            "positions",
            payload["parts"][0]["mesh"],
            "Resolver must not mutate caller input",
        )

    def test_mixed_parts_and_texture_failure(self):
        payload = {"parts": [part("123"), part("456")], "textures": {}}
        payload["parts"][0]["texture"] = {"assetId": "789", "mode": "alpha"}
        with (
            patch.object(
                self.resolver,
                "download",
                side_effect=lambda identifier: (
                    mesh_v2()
                    if identifier == "123"
                    else (_ for _ in ()).throw(assets.AssetError("denied"))
                ),
            ),
            patch.object(
                self.resolver, "texture", side_effect=assets.AssetError("denied")
            ),
        ):
            resolved, warnings, incomplete = self.resolver.resolve(payload)
        self.assertTrue(incomplete)
        self.assertEqual(resolved["parts"][0]["kind"], "mesh")
        self.assertEqual(resolved["parts"][1]["kind"], "block")
        self.assertNotIn("texture", resolved["parts"][0])
        self.assertEqual(len(warnings), 2)

    def test_decal_image_id(self):
        decal = (
            b'<roblox version="4"><Item class="Decal"><Properties>'
            b'<Content name="Texture"><url>http://www.roblox.com/asset/?id=456</url></Content>'
            b"</Properties></Item></roblox>"
        )
        with patch.object(assets, "read_public", return_value=decal):
            self.assertEqual(self.resolver.decal_image_id("123"), "456")
        with (
            patch.object(assets, "read_public", side_effect=OSError("403")),
            patch.object(assets.uploader, "find_raven", return_value=None),
        ):
            self.assertIsNone(self.resolver.decal_image_id("789"))

    def test_invalid_id(self):
        for identifier in ("../123", "0", 123):
            with self.assertRaises(assets.AssetError):
                self.resolver.download(identifier)

    def test_existing_raven_enables_download_without_upgrade(self):
        with (
            patch.object(assets.uploader, "find_raven", return_value="/bin/raven"),
            patch.object(assets, "supports_download", return_value=True),
            patch.object(assets, "enable_download") as enable,
        ):
            self.assertEqual(assets.ensure_raven(), "/bin/raven")
            enable.assert_called_once_with("/bin/raven")


class IntegrationTests(unittest.TestCase):
    def test_upload_preserves_existing_cli_contract(self):
        result = SimpleNamespace(
            returncode=0,
            stdout=json.dumps(
                {"assetId": "123", "moderationResult": {"moderationState": "Approved"}}
            ),
        )
        with (
            patch.object(uploader, "find_raven", return_value="raven"),
            patch.object(assets, "run_raven", return_value=result) as run,
        ):
            self.assertEqual(
                uploader.upload("icon.png", "Icon", "user:42"),
                {"assetId": "123", "moderation": "Approved"},
            )
        args = run.call_args.args[1]
        self.assertEqual(args[:5], ["--json", "asset", "upload", "--path", "icon.png"])
        self.assertIn("user:42", args)

    def test_failed_raven_upgrade_keeps_installed_backend(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            current = root / "backend"
            current.mkdir()
            (current / "main.py").write_text("working")
            replacement = root / "replacement"
            replacement.mkdir()
            with (
                patch.object(updater, "is_source_checkout", return_value=False),
                patch.object(updater, "install_dir", return_value=root),
                patch.object(updater, "backend_dir", return_value=current),
                patch.object(updater, "fetch", return_value=b"x" * 2048),
                patch.object(updater, "extract_backend", return_value=replacement),
                patch.object(updater.config, "Store") as store,
                patch.object(
                    assets,
                    "ensure_raven",
                    side_effect=assets.AssetError("upgrade failed"),
                ),
                self.assertRaisesRegex(updater.UpdateError, "upgrade failed"),
            ):
                store.return_value.get_config.return_value = {"ravenPath": ""}
                updater.install("0.3.0")
            self.assertEqual((current / "main.py").read_text(), "working")
            self.assertFalse((root / ".backend-previous").exists())


if __name__ == "__main__":
    unittest.main()
