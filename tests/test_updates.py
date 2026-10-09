import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
import config
import updater

OLD, NEW = "a" * 64, "b" * 64


class PluginHashTests(unittest.TestCase):
    def test_reads_only_valid_fingerprints(self):
        with tempfile.TemporaryDirectory() as directory:
            self.assertIsNone(config.plugin_hash(directory))
            (Path(directory) / "PLUGIN_HASH").write_text(OLD + "\n", encoding="utf-8")
            self.assertEqual(config.plugin_hash(directory), OLD)
            (Path(directory) / "PLUGIN_HASH").write_text("not a hash", encoding="utf-8")
            self.assertIsNone(config.plugin_hash(directory))

    def test_unknown_fingerprints_count_as_changed(self):
        self.assertFalse(updater.plugin_changed(OLD, OLD))
        self.assertTrue(updater.plugin_changed(OLD, NEW))
        self.assertTrue(updater.plugin_changed(None, OLD))
        self.assertTrue(updater.plugin_changed(OLD, None))

    def test_release_fingerprint_comes_from_its_asset(self):
        release = {"assets": [{"name": "Prism.rbxm", "browser_download_url": "x"},
                              {"name": "plugin-hash.txt", "browser_download_url": "https://example/hash"}]}
        with patch.object(updater, "fetch", return_value=(NEW + "\n").encode()) as fetch:
            self.assertEqual(updater.release_plugin_hash(release), NEW)
        fetch.assert_called_once_with("https://example/hash", timeout=20)
        self.assertIsNone(updater.release_plugin_hash({"assets": []}))
        with patch.object(updater, "fetch", side_effect=updater.UpdateError("offline")):
            self.assertIsNone(updater.release_plugin_hash(release))


class StatusTests(unittest.TestCase):
    def status(self, backend, plugin, plugin_hash, installed_hash, latest="0.21.1", released_hash=NEW):
        checker = updater.Checker()
        release = {"version": latest, "notes": "", "url": "u", "pluginHash": released_hash}
        with (
            patch.object(checker, "latest", return_value=(release, None)),
            patch.object(updater.config, "version", return_value=backend),
            patch.object(updater.config, "plugin_hash", return_value=installed_hash),
            patch.object(updater, "is_source_checkout", return_value=False),
        ):
            return checker.status(plugin, plugin_hash=plugin_hash)

    def test_plugin_kept_by_a_backend_only_update_is_current(self):
        # v0.21.0 plugin still running after a backend-only update to v0.21.1.
        status = self.status("0.21.1", "0.21.0", OLD, OLD)
        self.assertFalse(status["available"])

    def test_old_plugin_with_another_fingerprint_is_outdated(self):
        self.assertTrue(self.status("0.21.1", "0.21.0", NEW, OLD)["available"])
        self.assertTrue(self.status("0.21.1", "0.21.0", None, OLD)["available"])

    def test_reports_whether_the_latest_release_changes_the_plugin(self):
        self.assertFalse(self.status("0.21.0", "0.21.0", NEW, NEW, released_hash=NEW)["pluginChanged"])
        self.assertTrue(self.status("0.21.0", "0.21.0", OLD, OLD, released_hash=NEW)["pluginChanged"])
        self.assertTrue(self.status("0.21.0", "0.21.0", OLD, OLD, released_hash=None)["pluginChanged"])


if __name__ == "__main__":
    unittest.main()


class UpdateRouteTests(unittest.TestCase):
    def post(self, body):
        import http.client
        import json
        import threading
        from types import SimpleNamespace

        import server

        checker = SimpleNamespace(status=lambda force=True: {"latest": "0.21.1", "canUpdate": True, "error": None})
        bridge = SimpleNamespace(updates=checker, updating=threading.Lock())
        http_server = server.ThreadingHTTPServer(("127.0.0.1", 0), server.make_handler(bridge))
        thread = threading.Thread(target=http_server.serve_forever, daemon=True)
        thread.start()
        try:
            with (
                patch.object(updater, "install", return_value=["/plugins/Prism.rbxm"]),
                patch.object(server.config, "plugin_hash", return_value=OLD),
                patch.object(server.threading, "Timer") as timer,
            ):
                connection = http.client.HTTPConnection("127.0.0.1", http_server.server_address[1])
                connection.request("POST", "/update", json.dumps(body), {"X-Prism": "1", "Content-Type": "application/json"})
                result = json.loads(connection.getresponse().read())
                connection.close()
            timer.assert_called_once()
            return result
        finally:
            http_server.shutdown()
            http_server.server_close()

    def test_matching_fingerprint_skips_the_studio_restart(self):
        self.assertFalse(self.post({"pluginHash": OLD})["pluginChanged"])

    def test_other_or_missing_fingerprints_restart_studio(self):
        self.assertTrue(self.post({"pluginHash": NEW})["pluginChanged"])
        self.assertTrue(self.post({})["pluginChanged"])
