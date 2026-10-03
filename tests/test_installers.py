import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]


def embedded(name):
    source = (ROOT / "install.sh").read_text()
    marker = f"local {name}='\n"
    return source.split(marker, 1)[1].split("\n'", 1)[0]


class InstallerTests(unittest.TestCase):
    def validate(self, scopes):
        result = subprocess.run(
            [sys.executable, "-c", embedded("parse_code")],
            input=json.dumps({"scopes": scopes}),
            text=True,
            capture_output=True,
            check=True,
        )
        return result.stdout.strip()

    def test_requires_upload_and_download_scopes(self):
        self.assertTrue(
            self.validate(
                ["asset:read", "asset:write", "legacy-asset:manage"]
            ).startswith("ok")
        )
        self.assertIn("Legacy Assets", self.validate(["asset:read", "asset:write"]))
        self.assertIn(
            "Read and Write", self.validate(["asset:write", "legacy-asset:manage"])
        )
        self.assertTrue(
            self.validate(
                [
                    {"name": "assets", "operations": ["Read", "Write"]},
                    {"name": "legacy-asset", "operations": ["Manage"]},
                ]
            ).startswith("ok")
        )

    def test_reused_key_preserves_features_and_enables_download(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "credentials.json"
            path.write_text(
                json.dumps({"apiKey": "test-key", "features": ["publish", "asset"]})
            )
            subprocess.run(
                [
                    sys.executable,
                    "-c",
                    embedded("save_code"),
                    str(path),
                    "test-key-name",
                    "123",
                ],
                input="test-key",
                text=True,
                check=True,
            )
            saved = json.loads(path.read_text())
            self.assertEqual(saved["features"], ["publish", "asset", "asset-download"])
            self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_older_key_keeps_all_commands_enabled(self):
        with tempfile.TemporaryDirectory() as temporary:
            path = Path(temporary) / "credentials.json"
            path.write_text(json.dumps({"apiKey": "test-key"}))
            subprocess.run(
                [sys.executable, "-c", embedded("save_code"), str(path), "", "123"],
                input="test-key",
                text=True,
                check=True,
            )
            self.assertNotIn("features", json.loads(path.read_text()))


class ConsistencyTests(unittest.TestCase):
    def test_raven_version_matches_backend(self):
        sys.path.insert(0, str(ROOT / "backend"))
        import assets

        self.assertIn(f'local raven_version="{assets.RAVEN_VERSION}"', (ROOT / "install.sh").read_text())
        self.assertIn(f'$ravenVersion = "{assets.RAVEN_VERSION}"', (ROOT / "install.ps1").read_text())

    def test_uninstall_runs_before_network_and_blender(self):
        source = (ROOT / "install.sh").read_text()
        uninstall = source.index('if [[ "$uninstall" == true ]]')
        self.assertLess(uninstall, source.index("api.github.com"))
        self.assertLess(uninstall, source.index("find_blender()"))
        windows = (ROOT / "install.ps1").read_text()
        self.assertLess(windows.index("if ($Remove)"), windows.index("api.github.com"))
        self.assertLess(windows.index("if ($Remove)"), windows.index("$env:PRISM_BLENDER"))


if __name__ == "__main__":
    unittest.main()
