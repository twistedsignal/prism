import base64
import json
import os
import plistlib
import subprocess
import sys
import tempfile
import threading
import unittest
import urllib.request
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "backend"))

import autostart
import config
import runtime
import server
import updater
import worker_client
from scene import SceneError


class WorkerTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.worker = worker_client.Worker(
            command=[sys.executable, str(ROOT / "tests" / "fixtures" / "worker.py")],
            cache=self.temporary.name,
        )

    def tearDown(self):
        self.worker.close()
        self.temporary.cleanup()

    def test_lazy_start_reuse_idle_stop_and_restart(self):
        self.assertIsNone(self.worker.process)
        result = self.worker.add_scene(b'{"parts": []}')
        self.assertEqual(result["sceneId"], "testscene")
        process = self.worker.process
        directory = self.worker.directory.name
        self.assertEqual(self.worker.render("testscene", {}, 128, "8"), b"image")
        self.assertIs(self.worker.process, process)
        self.worker.last_used -= 61
        self.worker.stop_if_idle()
        self.assertIsNotNone(process.poll())
        self.assertFalse(Path(directory).exists())
        self.assertIsNone(self.worker.process)
        self.assertEqual(self.worker.render("testscene", {}, 128, "8", "png"), b"image")
        self.assertNotEqual(self.worker.process.pid, process.pid)

    def test_crashed_worker_is_reaped_and_next_job_recovers(self):
        self.worker.start()
        process = self.worker.process
        with self.assertRaisesRegex(RuntimeError, "disconnected"):
            self.worker.render("testscene", {"test": "crash"}, 128, "8")
        self.assertIsNone(self.worker.process)
        self.assertIsNotNone(process.poll())
        self.assertEqual(self.worker.render("testscene", {}, 128, "8"), b"image")

    def test_timed_out_worker_is_stopped(self):
        with patch.object(worker_client, "RENDER_TIMEOUT", 0.05):
            with self.assertRaises(TimeoutError):
                self.worker.render("testscene", {"test": "timeout"}, 128, "8")
        self.assertIsNone(self.worker.process)
        self.assertEqual(self.worker.render("testscene", {}, 128, "8"), b"image")

    def test_startup_failure_cleans_up(self):
        self.worker.command = [sys.executable, "-c", "raise SystemExit(2)"]
        with self.assertRaisesRegex(RuntimeError, "startup"):
            self.worker.start()
        self.assertIsNone(self.worker.process)
        self.assertIsNone(self.worker.directory)

    def test_scene_errors_preserve_worker(self):
        with self.assertRaises(SceneError):
            self.worker.call("invalid")
        self.assertIsNotNone(self.worker.process)

    def test_http_status_scene_preview_export_and_shutdown(self):
        with patch.object(config, "cache_dir", return_value=Path(self.temporary.name)):
            store = config.Store(self.temporary.name)
            store.update_config({"outputFolder": str(Path(self.temporary.name) / "output")})
            bridge = server.Bridge(store)
        bridge.worker = self.worker
        httpd = server.bind(bridge, 0)
        http_thread = threading.Thread(target=httpd.serve_forever)
        stop = threading.Event()

        def jobs():
            while not stop.is_set():
                bridge.jobs.run_pending(timeout=0.01)

        job_thread = threading.Thread(target=jobs)
        http_thread.start()
        job_thread.start()

        def request(path, data=None):
            body = json.dumps(data).encode() if data is not None else None
            req = urllib.request.Request(
                f"http://127.0.0.1:{httpd.server_port}{path}", data=body,
                headers={"X-Prism": "1"},
            )
            with urllib.request.urlopen(req, timeout=5) as response:
                return json.load(response)

        try:
            self.assertFalse(request("/status")["workerRunning"])
            scene = request("/scenes", {"parts": []})
            # Fake scene is represented in the disk cache, as with a real worker.
            path = bridge.scenes.path(scene["sceneId"])
            path.parent.mkdir(parents=True)
            path.touch()
            preview = request("/preview", {"sceneId": scene["sceneId"], "size": 128})
            self.assertEqual(base64.b64decode(preview["pixels"]), b"image")
            self.assertEqual(preview["width"], 128)
            exported = request("/export", {"items": [{"sceneId": scene["sceneId"], "name": "Head"}]})
            self.assertEqual(Path(exported["results"][0]["path"]).read_bytes(), b"image")
            self.assertTrue(request("/status")["workerRunning"])
        finally:
            httpd.shutdown()
            httpd.server_close()
            stop.set()
            http_thread.join()
            job_thread.join()


class RuntimeTests(unittest.TestCase):
    def test_server_import_keeps_blender_and_numpy_unloaded(self):
        subprocess.run([
            sys.executable, "-c",
            "import sys; sys.path.insert(0, 'backend'); import server; "
            "assert 'bpy' not in sys.modules; assert 'numpy' not in sys.modules",
        ], cwd=ROOT, check=True)

    def test_install_uses_plain_python_and_preserves_blender_command(self):
        with tempfile.TemporaryDirectory() as temporary:
            with (
                patch.object(config, "config_dir", return_value=Path(temporary)),
                patch.dict(sys.modules, {"bpy": SimpleNamespace(app=SimpleNamespace(
                    binary_path="/opt/Blender App/blender", version_string="5.2",
                ))}),
                patch.dict(os.environ, {"FLATPAK_ID": ""}),
            ):
                value = runtime.configure()
                command = autostart.serve_command(log="/tmp/prism.log")
                self.assertEqual(command[0], value["python"])
                self.assertNotIn("--background", command)
                self.assertEqual(runtime.blender_command(), ["/opt/Blender App/blender"])
                self.assertEqual(command[-2:], ["--log", "/tmp/prism.log"])

    def test_linux_migration_does_not_restart_running_service(self):
        with tempfile.TemporaryDirectory() as temporary:
            with (
                patch.object(autostart, "systemd_unit_path", return_value=Path(temporary) / "prism.service"),
                patch.object(autostart, "serve_command", return_value=["/opt/Python App/python", "/opt/Prism/main.py", "serve"]),
                patch.object(autostart, "run") as run,
            ):
                autostart.install_linux(None, start=False)
                commands = [call.args[0] for call in run.call_args_list]
                self.assertFalse(any("restart" in command for command in commands))
                self.assertIn("Python App/python", (Path(temporary) / "prism.service").read_text())

    def test_macos_migration_writes_python_launch_agent_without_stopping_server(self):
        with tempfile.TemporaryDirectory() as temporary:
            plist = Path(temporary) / "prism.plist"
            with (
                patch.object(autostart, "launch_agent_path", return_value=plist),
                patch.object(autostart, "remove_legacy_launch_agents"),
                patch.object(autostart.Path, "home", return_value=Path(temporary)),
                patch.object(autostart, "serve_command", return_value=["/opt/python", "/opt/Prism/main.py", "serve"]),
                patch.object(autostart, "run") as run,
            ):
                autostart.install_macos(None, start=False)
                value = plistlib.loads(plist.read_bytes())
                self.assertEqual(value["ProgramArguments"][0], "/opt/python")
                run.assert_not_called()

    def test_windows_migration_writes_python_task_without_ending_current_task(self):
        with tempfile.TemporaryDirectory() as temporary:
            documents = []

            def run(command, **_options):
                if "/XML" in command:
                    documents.append(Path(command[command.index("/XML") + 1]).read_text(encoding="utf-16"))
                self.assertNotIn("/End", command)
                self.assertNotIn("/Run", command)

            with (
                patch.dict(os.environ, {"LOCALAPPDATA": temporary}),
                patch.object(autostart, "serve_command", return_value=["C:\\Python App\\pythonw.exe", "C:\\Prism\\main.py", "serve"]),
                patch.object(autostart, "run", side_effect=run),
            ):
                autostart.install_windows(None, start=False)
                self.assertIn("pythonw.exe</Command>", documents[0])
                self.assertIn("--managed", documents[0])
                self.assertNotIn("--background", documents[0])

    def test_windows_bundled_python_discovery(self):
        with tempfile.TemporaryDirectory() as temporary:
            root = Path(temporary)
            binary = root / "python" / "bin"
            binary.mkdir(parents=True)
            (binary / "python.exe").touch()
            (binary / "pythonw.exe").touch()
            with (
                patch.object(config, "config_dir", return_value=root / "config"),
                patch.object(sys, "executable", str(root / "blender.exe")),
                patch.object(sys, "prefix", str(root / "python")),
                patch.object(sys, "platform", "win32"),
                patch.dict(os.environ, {"FLATPAK_ID": ""}),
            ):
                value = runtime.configure(str(root / "blender-launcher.exe"))
                self.assertEqual(value["pythonCommand"], [str(binary / "pythonw.exe")])
                self.assertEqual(value["blenderCommand"], [str(root / "blender.exe")])

    def test_windows_managed_update_restarts_registered_task(self):
        with (
            patch.object(sys, "platform", "win32"),
            patch.dict(os.environ, {"PRISM_MANAGED": "1"}),
            patch.object(runtime, "restart_windows_task") as restart,
            patch.object(updater.os, "_exit", side_effect=SystemExit),
        ):
            with self.assertRaises(SystemExit):
                updater.restart()
            restart.assert_called_once_with()


@unittest.skipUnless(os.environ.get("PRISM_TEST_BLENDER"), "Set PRISM_TEST_BLENDER to run Blender integration")
class BlenderWorkerTests(unittest.TestCase):
    def test_real_blender_pass_cache(self):
        result = subprocess.run([
            os.environ["PRISM_TEST_BLENDER"], "--background", "--factory-startup",
            "--python-exit-code", "1", "--python", str(ROOT / "tests" / "fixtures" / "blender_pass_cache.py"),
        ], capture_output=True, text=True, timeout=180)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Blender pass-cache checks passed", result.stdout)

    def test_real_scene_render_export_idle_restart_and_recovery(self):
        with tempfile.TemporaryDirectory() as temporary:
            worker = worker_client.Worker(command=[
                os.environ["PRISM_TEST_BLENDER"], "--background", "--factory-startup",
                "--python-exit-code", "1", "--python", str(ROOT / "backend" / "worker.py"), "--",
            ], cache=temporary)
            try:
                self.assertIsNone(worker.process)
                scene = worker.add_scene(json.dumps({"parts": [{
                    "kind": "head", "size": [1, 1, 1], "color": "#F5CD30",
                    "cframe": [0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1],
                }], "textures": {}}).encode())
                pixels = worker.render(scene["sceneId"], {}, 128, "8")
                self.assertEqual(len(pixels), 128 * 128 * 4)
                self.assertTrue(any(pixels[3::4]))
                png = worker.render(scene["sceneId"], {}, 128, "8", "png")
                self.assertTrue(png.startswith(b"\x89PNG\r\n\x1a\n"))
                worker.last_used -= 61
                worker.stop_if_idle()
                self.assertIsNone(worker.process)
                self.assertEqual(worker.render(scene["sceneId"], {}, 128, "8"), pixels)
                worker.process.kill()
                worker.process.wait()
                self.assertEqual(worker.render(scene["sceneId"], {}, 128, "8"), pixels)
            finally:
                worker.close()


if __name__ == "__main__":
    unittest.main()
