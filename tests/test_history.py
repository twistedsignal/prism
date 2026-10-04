import sys
import tempfile
import unittest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
import agent
import config


class HistoryTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.addCleanup(self.directory.cleanup)
        self.store = config.Store(self.directory.name)

    def test_records_renders_and_uploads_newest_first(self):
        self.store.record_history("render", [
            {"name": "Crate", "path": "/out/Crate.png"},
            {"name": "Broken", "error": "no parts"},
        ])
        self.store.record_history("upload", [
            {"name": "Sword", "path": "/out/Sword.png", "assetId": "111", "imageId": "222", "moderation": "Approved"},
            {"name": "Shield", "path": "/out/Shield.png", "error": "quota"},
        ], "user:5")
        history = self.store.get_history()
        self.assertEqual([entry["name"] for entry in history], ["Shield", "Sword", "Crate"])
        self.assertEqual(history[0]["kind"], "render")
        self.assertNotIn("creator", history[0])
        self.assertEqual(history[1]["kind"], "upload")
        self.assertEqual(history[1]["assetId"], "111")
        self.assertEqual(history[1]["imageId"], "222")
        self.assertEqual(history[1]["creator"], "user:5")
        self.assertIsInstance(history[2]["time"], int)

    def test_records_studio_source_and_parent(self):
        self.store.record_history("upload", [{"name": "Sword", "path": "/Sword.png", "assetId": "1",
                                              "source": "ReplicatedStorage/Weapons/Sword", "parent": "Weapons"}])
        entry = self.store.get_history()[0]
        self.assertEqual(entry["source"], "ReplicatedStorage/Weapons/Sword")
        self.assertEqual(entry["parent"], "Weapons")

    def test_agent_origin_from_dotted_or_list_paths(self):
        self.assertEqual(agent.origin({"path": "Workspace.Props.Crate"}), {"source": "Workspace/Props/Crate", "parent": "Props"})
        self.assertEqual(agent.origin({"path": ["Workspace"]}), {"source": "Workspace"})
        self.assertEqual(agent.origin({"target": "abc"}), {})

    def test_history_is_capped_and_clearable(self):
        self.store.record_history("render", [{"name": str(i), "path": f"/{i}.png"} for i in range(config.MAX_HISTORY + 10)])
        history = self.store.get_history()
        self.assertEqual(len(history), config.MAX_HISTORY)
        self.assertEqual(history[0]["name"], str(config.MAX_HISTORY + 9))
        self.store.clear_history()
        self.assertEqual(self.store.get_history(), [])

    def test_corrupt_history_reads_as_empty(self):
        self.store.history_path.write_text("{not json")
        self.assertEqual(self.store.get_history(), [])
        self.store.record_history("render", [{"name": "Crate", "path": "/Crate.png"}])
        self.assertEqual(len(self.store.get_history()), 1)


if __name__ == "__main__":
    unittest.main()
