import copy
import json
import sys
import tempfile
import threading
import time
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
import agent
import cli
import cli_install
import config


class AgentTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.store = config.Store(self.directory.name)
        self.store.update_config({"outputFolder": self.directory.name, "port": 49999})
        self.calls = []
        self.bridge = SimpleNamespace(store=self.store,
            worker=SimpleNamespace(add_scene=lambda raw: {"sceneId": "scene", "warnings": ["recovered"]}),
            jobs=SimpleNamespace(submit=lambda fn, **kwargs: fn()),
            render=lambda *args, **kwargs: self.calls.append((args, kwargs)) or b"PNG")
        self.now = 0
        self.broker = agent.Broker(self.bridge, clock=lambda: self.now)
        self.broker.register({"id": "studio", "apiVersion": 1, "pluginVersion": "dev"})

    def finish(self, job, snapshots):
        self.broker.poll({"session": "studio"})
        self.broker.complete({"session": "studio", "id": job["id"], "items": snapshots})
        for _ in range(200):
            result = self.broker.get(job["id"])
            if result["status"] in agent.TERMINAL:
                return result
            time.sleep(0.005)
        self.fail("Job did not finish")

    def test_settings_and_options_are_isolated_and_batch_continues(self):
        self.store.save_preset("Icon", {"cameraRotation": 20})
        before = self.store.get_config()
        job = self.broker.submit({"operation": "batch", "defaults": {"preset": "Icon", "size": 1024, "emojiProvider": "apple"},
            "items": [{"path": ["Workspace", "Crate"], "settings": {"cameraRotation": 45, "textColor": "#ff0000"}}, {"path": "Workspace.Missing"}]})
        result = self.finish(job, [{"payload": {"parts": [{}]}, "name": "Crate", "warnings": ["source"]}, {"error": "missing"}])
        self.assertEqual(result["status"], "partial")
        self.assertEqual(Path(result["results"][0]["path"]).read_bytes(), b"PNG")
        self.assertEqual(self.calls[0][0][1]["cameraRotation"], 45)
        self.assertEqual(self.calls[0][0][1]["textColor"], "#FF0000FF")
        self.assertEqual(self.calls[0][0][2], 1024)
        self.assertEqual(self.calls[0][1]["emoji_provider"], "apple")
        self.assertEqual(result["results"][0]["warnings"], ["source", "recovered"])
        self.assertEqual(self.store.get_config(), before)
        self.assertEqual(self.store.get_presets()["Icon"]["cameraRotation"], 20)

    def test_upload_repeated_completion_is_idempotent(self):
        job = self.broker.submit({"operation": "upload", "path": "Workspace.Part", "creator": "user:123"})
        with patch.object(agent.uploader, "upload", return_value={"assetId": "123", "moderation": "Unknown"}) as upload, \
                patch.object(agent.assets, "Resolver") as resolver:
            resolver.return_value.decal_image_id.return_value = "456"
            result = self.finish(job, [{"payload": {"parts": [{}]}, "name": "Part"}])
            self.broker.complete({"session": "studio", "id": job["id"], "items": [{}]})
            self.assertEqual(upload.call_count, 1)
            self.assertEqual(result["results"][0]["imageId"], "456")
            self.assertEqual(upload.call_args.args[2], "user:123")

    def test_session_selection_expiration_and_serial_operations(self):
        self.broker.register({"id": "other", "apiVersion": 1})
        with self.assertRaisesRegex(agent.AgentError, "Choose --session"):
            self.broker.submit({"operation": "models"})
        first = self.broker.submit({"session": "studio", "operation": "models"})
        second = self.broker.submit({"session": "studio", "operation": "models"})
        self.assertEqual(self.broker.poll({"session": "studio"})["job"]["id"], first["id"])
        self.assertIsNone(self.broker.poll({"session": "studio"})["job"])
        self.broker.complete({"session": "studio", "id": first["id"], "models": [{"id": "1"}]})
        self.assertEqual(self.broker.poll({"session": "studio"})["job"]["id"], second["id"])
        self.now = 31
        self.assertEqual(self.broker.get(second["id"])["status"], "failed")
        self.assertEqual(self.broker.session_list(), [])

    def test_invalid_options_and_no_overwrite(self):
        for changes in ({"settings": {"bad": 1}}, {"settings": {"zoom": -1}}, {"size": 100}, {"preset": "missing"}, {"emojiProvider": "bad"}):
            with self.subTest(changes=changes), self.assertRaises(agent.AgentError):
                self.broker.submit(dict(path="Workspace.Part", **changes))
        path = Path(self.directory.name) / "keep.png"
        path.write_bytes(b"keep")
        job = self.broker.submit({"path": "Workspace.Part", "output": str(path)})
        result = self.finish(job, [{"payload": {"parts": [{}]}}])
        self.assertEqual(result["status"], "failed")
        self.assertEqual(path.read_bytes(), b"keep")
        with self.assertRaisesRegex(agent.AgentError, "creator"):
            self.broker.submit({"operation": "upload", "path": "Workspace.Part"})

    def test_cli_parsing_timeout_and_manifest(self):
        args = cli.parser().parse_args(["render", "--path", "Workspace.Part", "--size", "1024", "--settings", '{"zoom":2}'])
        self.assertEqual(args.size, 1024)
        client = cli.Client(49999)
        job = {"id": "job", "status": "queued"}
        result, code = client.wait(job, 0)
        self.assertEqual(code, 2)
        self.assertEqual(result["id"], "job")
        with patch.object(cli, "Client") as client:
            client.return_value.request.side_effect = [{"agentApiVersion": 1}, job]
            client.return_value.wait.return_value = (dict(job, status="completed"), 0)
            result, code = cli.execute(args)
            body = client.return_value.request.call_args.args[2]
            self.assertEqual(body["settings"], {"zoom": 2})
            self.assertEqual(body["size"], 1024)
            self.assertNotIn("PUT", str(client.mock_calls))

    def test_launcher_migration_and_skill_install_are_idempotent(self):
        path = Path(self.directory.name) / "bin" / "prism"
        with patch.object(cli_install, "launcher_path", return_value=path), \
                patch.object(cli_install.runtime, "settings", return_value={"pythonCommand": [sys.executable]}):
            cli_install.install()
            content = path.read_text()
            cli_install.install()
            self.assertEqual(path.read_text(), content)
            self.assertIn("cli.py", content)
            cli_install.uninstall()
            self.assertFalse(path.exists())
            path.write_text("unrelated command")
            cli_install.install()
            self.assertEqual(path.read_text(), "unrelated command")
            cli_install.uninstall()
            self.assertTrue(path.exists())
        args = cli.parser().parse_args(["agent", "install-skill", "--directory", self.directory.name])
        first, _ = cli.execute(args)
        second, _ = cli.execute(args)
        self.assertEqual(first, second)
        self.assertTrue(Path(first["path"]).exists())

class MigrationTests(unittest.TestCase):
    def test_new_backend_startup_installs_launcher_without_new_updater(self):
        import main
        import server
        args = SimpleNamespace(command="serve", blender=None, managed=False, log=None, port=49999)
        with patch.object(main, "parse_args", return_value=args), patch.object(main.signal, "signal"), \
                patch.object(cli_install, "install", return_value={"cliHint": "ready"}) as install, \
                patch.object(server, "serve") as serve:
            main.main()
        install.assert_called_once()
        self.assertEqual(serve.call_args.args[1], 49999)

    def test_existing_updater_swap_preserves_config_and_gains_cli_at_startup(self):
        import importlib.util
        import io
        import tarfile
        import updater
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            backend = root / "backend"
            backend.mkdir()
            (backend / "main.py").write_text("# old backend")
            store = config.Store(root / "config")
            store.update_config({"port": 49997, "emojiProvider": "apple", "ravenPath": "raven"})
            store.save_preset("Saved", {"zoom": 2})
            before = store.get_config()
            archive = io.BytesIO()
            with tarfile.open(fileobj=archive, mode="w:gz") as bundle:
                for name in ("main.py", "cli.py", "cli_install.py", "agent-skill.md"):
                    bundle.add(Path(cli.__file__).parent / name, arcname="backend/" + name)
            def fetch(url, **kwargs):
                return b"plugin" * 300 if url.endswith("Prism.rbxm") else archive.getvalue()
            with patch.object(updater, "is_source_checkout", return_value=False), \
                    patch.object(updater, "install_dir", return_value=root), \
                    patch.object(updater, "backend_dir", return_value=backend), \
                    patch.object(updater, "plugin_dirs", return_value=[root / "Plugins"]), \
                    patch.object(updater, "fetch", side_effect=fetch), \
                    patch.object(config, "config_dir", return_value=root / "config"), \
                    patch.object(agent.assets, "ensure_raven", return_value="raven"):
                updater.install("0.15.0")
            self.assertEqual(store.get_config(), before)
            self.assertEqual(store.get_presets()["Saved"]["zoom"], 2)
            spec = importlib.util.spec_from_file_location("migrated_prism_cli_install", backend / "cli_install.py")
            installed = importlib.util.module_from_spec(spec)
            spec.loader.exec_module(installed)
            launcher = root / "bin" / "prism"
            with patch.object(installed, "launcher_path", return_value=launcher), \
                    patch.object(installed.runtime, "settings", return_value={"pythonCommand": [sys.executable]}):
                installed.install()
            self.assertIn(str(backend / "cli.py"), launcher.read_text())
            self.assertEqual((backend / "VERSION").read_text().strip(), "0.15.0")

    def test_platform_launchers_use_console_python_and_preserve_unrelated_files(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "prism.cmd"
            with patch.object(cli_install, "launcher_path", return_value=path), \
                    patch.object(cli_install, "sys", SimpleNamespace(platform="win32", executable=sys.executable)), \
                    patch.object(cli_install.runtime, "settings", return_value={"pythonCommand": ["/Blender/pythonw.exe"]}):
                cli_install.install()
                content = path.read_text()
                self.assertIn("python.exe", content)
                self.assertNotIn("pythonw.exe", content)
                self.assertIn("%*", content)
            path = Path(directory) / "prism"
            with patch.object(cli_install, "launcher_path", return_value=path), \
                    patch.object(cli_install.runtime, "settings", return_value={"pythonCommand": ["flatpak", "run", "--command=/app/python3", "org.blender.Blender"]}):
                cli_install.install()
                self.assertIn("flatpak run", path.read_text())
                self.assertIn('"$@"', path.read_text())

    def test_batch_cli_and_old_backend_capabilities(self):
        with tempfile.TemporaryDirectory() as directory:
            manifest = Path(directory) / "batch.json"
            manifest.write_text(json.dumps({"defaults": {"size": 1024}, "items": [{"path": ["Workspace", "Part"], "output": "./part.png"}]}))
            args = cli.parser().parse_args(["batch", str(manifest), "--session", "studio"])
            with patch.object(cli, "Client") as client:
                client.return_value.request.side_effect = [{"agentApiVersion": 1}, {"id": "job", "status": "queued"}]
                client.return_value.wait.return_value = ({"status": "partial"}, 1)
                _, code = cli.execute(args)
                self.assertEqual(code, 1)
                body = client.return_value.request.call_args.args[2]
                self.assertEqual(body["session"], "studio")
                self.assertEqual(body["defaults"]["size"], 1024)
                self.assertTrue(Path(body["items"][0]["output"]).is_absolute())
            with patch.object(cli, "Client") as client:
                client.return_value.request.return_value = {"version": "0.14.0"}
                with self.assertRaisesRegex(RuntimeError, "update Prism"):
                    cli.execute(args)


if __name__ == "__main__":
    unittest.main()
