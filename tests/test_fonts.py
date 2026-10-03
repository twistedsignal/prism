import struct
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
import fonts


def font_file(family, style, weight, italic=False):
    """A minimal TrueType file with just the name and OS/2 tables."""
    strings = [(1, family), (2, style)]
    data = b""
    records = b""
    for name_id, value in strings:
        encoded = value.encode("utf-16-be")
        records += struct.pack(">HHHHHH", 3, 1, 0x409, name_id, len(encoded), len(data))
        data += encoded
    name = struct.pack(">HHH", 0, len(strings), 6 + len(records)) + records + data
    os2 = bytearray(78)
    struct.pack_into(">H", os2, 4, weight)
    struct.pack_into(">H", os2, 62, 1 if italic else 0)
    tables = [(b"OS/2", bytes(os2)), (b"name", name)]
    offset = 12 + 16 * len(tables)
    header = struct.pack(">IHHHH", 0x00010000, len(tables), 0, 0, 0)
    directory, body = b"", b""
    for tag, content in tables:
        directory += struct.pack(">4sIII", tag, 0, offset + len(body), len(content))
        body += content
    return header + directory + body


class FontTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        root = Path(self.temporary.name)
        (root / "roblox").mkdir()
        (root / "system").mkdir()
        (root / "roblox" / "Fredoka.ttf").write_bytes(font_file("Fredoka One", "Regular", 400))
        (root / "system" / "Sans-Regular.ttf").write_bytes(font_file("Test Sans", "Regular", 400))
        (root / "system" / "Sans-Bold.ttf").write_bytes(font_file("Test Sans", "Bold", 700))
        (root / "system" / "Sans-Italic.otf").write_bytes(font_file("Test Sans", "Italic", 400, italic=True))
        (root / "system" / "Hidden.ttf").write_bytes(font_file(".Hidden UI", "Regular", 400))
        (root / "system" / "broken.ttf").write_bytes(b"not a font")
        fonts._cache["time"] = 0.0
        self.patches = [
            patch.object(fonts, "roblox_font_dirs", return_value=[root / "roblox"]),
            patch.object(fonts, "system_font_dirs", return_value=[root / "system"]),
        ]
        for active in self.patches:
            active.start()

    def tearDown(self):
        for active in self.patches:
            active.stop()
        fonts._cache["time"] = 0.0
        self.temporary.cleanup()

    def test_listing_puts_roblox_fonts_first_and_skips_hidden_or_broken_files(self):
        self.assertEqual([entry["label"] for entry in fonts.listing()], ["Fredoka One", "Test Sans"])
        self.assertEqual(fonts.listing()[0]["source"], "roblox")

    def test_resolve_picks_the_closest_face(self):
        self.assertTrue(fonts.resolve("Test Sans", 800, False)[0].endswith("Sans-Bold.ttf"))
        self.assertTrue(fonts.resolve("Test Sans", 400, True)[0].endswith("Sans-Italic.otf"))
        self.assertEqual(fonts.resolve("Test Sans", 300, False)[1:], (400, False))
        self.assertIsNone(fonts.resolve("Missing", 400, False))
        self.assertIsNone(fonts.resolve("", 400, False))


if __name__ == "__main__":
    unittest.main()
