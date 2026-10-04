import sys
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
import platform_open


def which(available):
    return lambda name: f"/usr/bin/{name}" if name in available else None


class ClipboardTests(unittest.TestCase):
    def command(self, platform, env=None, available=()):
        with patch.object(platform_open.sys, "platform", platform), \
             patch.object(platform_open.shutil, "which", which(available)):
            return platform_open.clipboard_command(env or {})

    def test_windows_and_mac_use_their_built_in_tools(self):
        self.assertEqual(self.command("win32"), (["clip"], "utf-16"))
        self.assertEqual(self.command("darwin"), (["pbcopy"], "utf-8"))

    def test_linux_prefers_wayland_then_x11_tools(self):
        self.assertEqual(self.command("linux", {"WAYLAND_DISPLAY": "wayland-1"}, ("wl-copy", "xclip"))[0], ["wl-copy"])
        self.assertEqual(self.command("linux", {}, ("wl-copy", "xclip"))[0], ["xclip", "-selection", "clipboard"])
        self.assertEqual(self.command("linux", {}, ("xsel",))[0], ["xsel", "--clipboard", "--input"])
        with self.assertRaises(platform_open.ClipboardError):
            self.command("linux", {"WAYLAND_DISPLAY": "wayland-1"})

    def test_copy_sends_encoded_text_and_reports_failures(self):
        calls = []
        with patch.object(platform_open, "clipboard_command", return_value=(["clip"], "utf-16")), \
             patch.object(platform_open, "session_environment", return_value={}), \
             patch.object(platform_open.subprocess, "run",
                          side_effect=lambda command, **kwargs: calls.append(kwargs) or SimpleNamespace(returncode=0)):
            platform_open.copy_text("ID ✓")
        self.assertEqual(calls[0]["input"], "ID ✓".encode("utf-16"))
        with patch.object(platform_open, "clipboard_command", return_value=(["clip"], "utf-8")), \
             patch.object(platform_open, "session_environment", return_value={}), \
             patch.object(platform_open.subprocess, "run", return_value=SimpleNamespace(returncode=1)):
            with self.assertRaises(platform_open.ClipboardError):
                platform_open.copy_text("x")


if __name__ == "__main__":
    unittest.main()
