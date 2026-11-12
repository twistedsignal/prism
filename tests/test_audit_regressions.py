import base64
import json
import os
import subprocess
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import numpy as np

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend"))
import appearance
import config
import installation
import jobs
import scene
import server
import updater

IDENTITY = [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1]


def payload(name):
    return {"name": name, "parts": [{"kind": "block", "size": [1, 1, 1], "cframe": IDENTITY}]}


def texture(pixels):
    values = np.asarray(pixels, dtype=np.uint8)
    return {"width": values.shape[1], "height": values.shape[0],
            "pixels": base64.b64encode(values.tobytes()).decode()}


class BatchTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        root = Path(self.temporary.name)
        with patch.object(config, "cache_dir", return_value=root):
            self.bridge = server.Bridge(config.Store(root / "config"))
        self.bridge.store.update_config({"outputFolder": str(root / "output")})
        self.bridge.jobs = SimpleNamespace(submit=lambda function, **kwargs: function())
        self.images = {}

        def add(raw):
            value = json.loads(raw)
            identifier, warnings = self.bridge.scenes.add(raw, value)
            self.images[identifier] = value["name"].encode()
            return {"sceneId": identifier, "warnings": warnings}

        self.bridge.worker = SimpleNamespace(add_scene=add,
            render=lambda identifier, *args, **kwargs: self.images[identifier])

    def item(self, image, name="Handle"):
        raw = json.dumps(payload(image))
        identifier = self.bridge.worker.add_scene(raw.encode())["sceneId"]
        return {"name": name, "sceneId": identifier, "payload": raw}

    def test_duplicate_names_keep_distinct_exports_and_immutable_upload_bytes(self):
        for overwrite in (True, False):
            with self.subTest(overwrite=overwrite):
                self.bridge.store.update_config({"overwrite": overwrite})
                items = [self.item("first", "A:B"), self.item("second", "A?B")]
                uploaded = []

                def upload(path, *args):
                    uploaded.append(Path(path).read_bytes())
                    for exported in Path(self.bridge.store.get_config()["outputFolder"]).glob("*.png"):
                        exported.write_bytes(b"another concurrent export")
                    return {"assetId": "123"}

                handler = server.make_handler(self.bridge)
                request = SimpleNamespace(read_json=lambda: {"items": items, "creator": "user:1"})
                with patch.object(server.uploader, "upload", side_effect=upload), patch.object(server.assets, "Resolver") as resolver:
                    resolver.return_value.decal_image_id.return_value = None
                    _, response = handler.upload(request)
                self.assertEqual(uploaded, [b"first", b"second"])
                self.assertNotEqual(response["results"][0]["path"], response["results"][1]["path"])
                self.assertTrue(all("_uploadPath" not in result for result in response["results"]))

    def test_bulk_export_recovers_evicted_scenes_just_before_each_render(self):
        items = [self.item(str(index), str(index)) for index in range(70)]
        self.assertFalse(self.bridge.scenes.exists(items[0]["sceneId"]))
        results = self.bridge.export(items)
        self.assertEqual(len(results), len(items))
        self.assertFalse(any("error" in result for result in results), results)
        self.assertEqual([Path(result["path"]).read_bytes() for result in results],
                         [str(index).encode() for index in range(70)])

    def test_preparation_errors_remain_in_batch_results(self):
        items = [self.item("ready"), {"name": "Reading", "error": "Still reading"}]
        self.assertEqual(server.read_items({"items": items}), items)
        results = self.bridge.export(items)
        self.assertEqual(len(results), 2)
        self.assertEqual(results[1]["error"], "Still reading")

    def test_unicode_names_and_collision_suffixes_fit_filesystem(self):
        for name in ("金" * 100, "😀" * 100, "a" * 200):
            with self.subTest(name=name[:4]):
                results = self.bridge.export([self.item("one", name), self.item("two", name)])
                self.assertFalse(any("error" in result for result in results), results)
                self.assertNotEqual(results[0]["path"], results[1]["path"])
                self.assertTrue(all(len(Path(result["path"]).name.encode()) <= 255 for result in results))


class QueueTests(unittest.TestCase):
    def test_expired_queued_jobs_never_run_and_release_client_keys(self):
        queue = jobs.JobQueue()
        calls = []
        with self.assertRaises(TimeoutError):
            queue.submit(lambda: calls.append("ran"), client="window", timeout=0)
        queue.run_pending(timeout=0)
        self.assertEqual(calls, [])
        self.assertEqual(queue.latest, {})

    def test_running_job_returns_its_actual_outcome_after_queue_deadline(self):
        queue = jobs.JobQueue()
        started, release, complete = threading.Event(), threading.Event(), threading.Event()
        result = []

        def work():
            started.set()
            release.wait(2)
            return "saved"

        def submit():
            result.append(queue.submit(work, timeout=0.05))
            complete.set()

        caller = threading.Thread(target=submit)
        worker = threading.Thread(target=queue.run_pending, kwargs={"timeout": 1})
        caller.start()
        worker.start()
        try:
            self.assertTrue(started.wait(1))
            self.assertFalse(complete.wait(0.1))
        finally:
            release.set()
            caller.join(2)
            worker.join(2)
        self.assertEqual(result, ["saved"])


class AppearanceRegressionTests(unittest.TestCase):
    def test_native_overlay_and_base_cover_shared_edges_once(self):
        corners = [(point, (0.5, 0.5), normal) for point, _, normal in scene.block([1, 1, 1])]
        textures = {"blue": texture([[[0, 0, 255, 128]]])}
        for base, layers in ((None, [{"id": "blue", "nativeUv": True}]),
                             ({"id": "blue", "mode": "overlay"}, [])):
            with self.subTest(base=base):
                _, baked = appearance.bake(corners, [1, 1, 1], [1, 0, 0], base, layers, textures, native_uv=True)
                _, _, pixels = scene.decode_texture(baked)
                values = np.unique(np.frombuffer(pixels, dtype=np.uint8).reshape(-1, 4), axis=0)
                self.assertEqual(values.tolist(), [[127, 0, 128, 255]])

    def test_texture_tints_and_tint_mask_survive_scene_export(self):
        pixels = [[[200, 100, 50, 0], [200, 100, 50, 128], [200, 100, 50, 255]]]
        for mode in ("alpha", "overlay", "tintMask"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as directory:
                value = payload("tint")
                value["textures"] = {"source": texture(pixels)}
                value["parts"][0]["texture"] = {"id": "source", "mode": mode, "tint": [1, 0.5, 0]}
                captured = []
                original = scene.write_png

                def capture(path, width, height, rgba):
                    captured.append(np.frombuffer(rgba, dtype=np.uint8).reshape(-1, 4).tolist())
                    original(path, width, height, rgba)

                with patch.object(scene, "write_png", side_effect=capture):
                    scene.build(value, directory)
                actual = captured[0]
                if mode == "tintMask":
                    self.assertEqual(actual, [[200, 100, 50, 255], [200, 75, 25, 255], [200, 50, 0, 255]])
                elif mode == "alpha":
                    self.assertEqual(actual, [[200, 50, 0, 0], [200, 50, 0, 128], [200, 50, 0, 255]])
                else:
                    self.assertEqual(actual[-1], [200, 50, 0, 255])


class InstallationTests(unittest.TestCase):
    def test_paths_restore_in_clean_process_and_updater_uses_recorded_plugins(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            environment = {"PRISM_CONFIG_DIR": str(root / "config"), "RAVEN_CONFIG_DIR": str(root / "credentials")}
            plugins = [root / "Studio A", root / "Studio B"]
            with patch.object(installation, "ROOT", root), patch.dict(os.environ, environment):
                installation.save(plugins)
                with patch.dict(os.environ, {}, clear=True):
                    installation.restore()
                    self.assertEqual(config.config_dir(), root / "config")
                    self.assertEqual(os.environ["RAVEN_CONFIG_DIR"], str(root / "credentials"))
                    self.assertEqual(updater.plugin_dirs(), plugins)
                self.assertEqual((root / "plugin-dirs.txt").read_text().splitlines(), list(map(str, plugins)))

    def test_service_entrypoint_restores_paths_before_loading_configuration(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            backend = root / "backend"
            backend.mkdir()
            for name in ("main.py", "installation.py", "config.py", "schema.py"):
                (backend / name).write_text((ROOT / "backend" / name).read_text())
            (backend / "runtime.py").write_text("")
            (backend / "cli_install.py").write_text('def install(): return {"cliHint": "test launcher"}\n')
            (backend / "server.py").write_text(
                'import json, os\ndef serve(store, port):\n'
                '    print(json.dumps({"directory": str(store.directory), "port": port, "raven": os.environ.get("RAVEN_CONFIG_DIR")}))\n')
            settings = root / "custom config"
            config.Store(settings).update_config({"port": 49998})
            value = {"environment": {"PRISM_CONFIG_DIR": str(settings), "RAVEN_CONFIG_DIR": str(root / "credentials")}}
            (root / "installation.json").write_text(json.dumps(value))
            environment = {key: value for key, value in os.environ.items() if key not in installation.ENVIRONMENT}
            result = subprocess.run([sys.executable, str(backend / "main.py"), "serve"],
                                    env=environment, capture_output=True, text=True, check=True)
            restored = json.loads(result.stdout.splitlines()[-1])
            self.assertEqual(restored, {"directory": str(settings), "port": 49998, "raven": str(root / "credentials")})

    def test_installers_propagate_python_exceptions(self):
        bash = (ROOT / "install.sh").read_text()
        for line in bash.splitlines():
            if '"${blender[@]}" --background' in line:
                self.assertIn("--python-exit-code 1", line)
        powershell = (ROOT / "install.ps1").read_text()
        self.assertIn('"--python-exit-code", "1", "--python"', powershell)
        self.assertIn('install_args+=(--plugins "$dir")', bash)
        self.assertIn('"--plugins", $pluginsDir', powershell)
        self.assertIn('fail "The backend did not start.', bash)
        self.assertIn('Stop-Install "The backend did not start.', powershell)


if __name__ == "__main__":
    unittest.main()
