import sys
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
import autostart
import cli


class FakeClient:
    port = 47821

    def __init__(self, failures):
        self.failures = failures

    def request(self, method, route, body=None):
        if self.failures > 0:
            self.failures -= 1
            raise RuntimeError("Connection refused")
        return {"version": "1.0.0"}


class StartTests(unittest.TestCase):
    def test_running_backend_is_left_alone(self):
        with patch.object(autostart, "start") as start:
            result, code = cli.start(FakeClient(0), 1)
        start.assert_not_called()
        self.assertEqual((code, result["started"]), (0, False))

    def test_starts_backend_and_waits_for_it(self):
        with patch.object(autostart, "start", return_value="systemd"), patch.object(cli.time, "sleep"):
            result, code = cli.start(FakeClient(3), 5)
        self.assertEqual((code, result["started"], result["method"]), (0, True, "systemd"))

    def test_reports_logs_when_backend_never_answers(self):
        with patch.object(autostart, "start", return_value="direct"), \
             patch.object(autostart, "logs", return_value=("prism.log", "Traceback: boom")), \
             patch.object(cli.time, "sleep"):
            result, code = cli.start(FakeClient(10 ** 6), 0)
        self.assertEqual(code, 1)
        self.assertIn("did not answer", result["error"])
        self.assertEqual(result["log"], "Traceback: boom")

    def test_falls_back_to_spawning_without_a_startup_entry(self):
        with patch.object(autostart.sys, "platform", "linux"), \
             patch.object(autostart, "systemd_unit_path", return_value=Path("/nonexistent/prism.service")), \
             patch.object(autostart.runtime, "spawn_server") as spawn:
            self.assertEqual(autostart.start(), "direct")
        spawn.assert_called_once()


if __name__ == "__main__":
    unittest.main()
