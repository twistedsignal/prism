import io
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "backend"))
import emoji
import config
import effects
import schema


class EmojiTests(unittest.TestCase):
    def test_sequences_and_text_presentation(self):
        self.assertEqual(list(emoji.tokens("Hi 👍🏽🇧🇷👨‍👩‍👧‍👦1️⃣!")), [
            ("Hi ", False), ("👍🏽", True), ("🇧🇷", True), ("👨‍👩‍👧‍👦", True), ("1️⃣", True), ("!", False)])
        self.assertEqual(list(emoji.tokens("123 plain text ♥\ufe0e")), [("123 plain text ♥\ufe0e", False)])
        for code in range(0xE000, 0xE004):
            text = chr(code)
            self.assertEqual(list(emoji.tokens(text)), [(text, True)])
            self.assertTrue(emoji.asset(text, "apple").is_file())

    def test_lua_unicode_escapes(self):
        self.assertEqual(emoji.decode_text(r"\u{E002} 500\n\u{1F600} \u{E003}"), "\ue002 500\n😀 \ue003")
        self.assertEqual(emoji.decode_text(r"\u{110000} \u{D800}"), r"\u{110000} \u{D800}")

    def test_download_cache_and_provider_isolation(self):
        data = b"\x89PNG\r\n\x1a\nexample"
        with tempfile.TemporaryDirectory() as directory, patch.object(config, "cache_dir", return_value=Path(directory)), \
                patch.object(emoji.urllib.request, "urlopen", side_effect=lambda *args, **kwargs: io.BytesIO(data)) as fetch:
            google = emoji.asset("😀", "google")
            apple = emoji.asset("😀", "apple")
            self.assertNotEqual(google, apple)
            self.assertEqual(fetch.call_count, 2)
            with patch.object(emoji.urllib.request, "urlopen", side_effect=OSError("offline")):
                self.assertEqual(emoji.asset("😀", "google"), google)
                with self.assertRaisesRegex(RuntimeError, "Check your connection"):
                    emoji.asset("😎", "google")
            self.assertEqual(len(list(Path(directory).rglob("*.png"))), 2)

    def test_unavailable_vendor_falls_back_and_invalid_data_is_not_cached(self):
        entry = {"😀": ["1f600.png", ["google"]]}
        with tempfile.TemporaryDirectory() as directory, patch.object(config, "cache_dir", return_value=Path(directory)), \
                patch.object(emoji, "index", return_value=entry), \
                patch.object(emoji.urllib.request, "urlopen", return_value=io.BytesIO(b"not png")) as fetch:
            with self.assertRaisesRegex(RuntimeError, "PNG"):
                emoji.asset("😀", "facebook")
            self.assertIn("emoji-datasource-google@16.0.0", fetch.call_args.args[0])
            self.assertFalse(list(Path(directory).rglob("*.png")))

    def test_rotated_clipped_sprite_preserves_alpha_and_input(self):
        sprite = np.ones((4, 4, 4), dtype=np.float32)
        sprite[..., :3] = [1, 0, 0]
        sprite[..., 3] = 0.5
        original = sprite.copy()
        canvas = np.zeros((16, 16, 4), dtype=np.float32)
        emoji.place(canvas, sprite, (0, 0), 10, 45)
        self.assertGreater(np.count_nonzero(canvas[..., 3]), 0)
        self.assertLessEqual(canvas[..., 3].max(), 0.5)
        self.assertTrue(np.isfinite(canvas).all())
        np.testing.assert_array_equal(sprite, original)
        np.testing.assert_array_equal(canvas[12:], 0)

    def test_colored_emoji_and_monochrome_text_with_offsets_and_effects(self):
        pixels = np.zeros((32, 32, 4), dtype=np.float32)
        text = np.zeros((32, 32, 5), dtype=np.float32)
        text[16, 12, :4] = [0, 1, 0, 1]
        text[16, 18, 4] = 1
        original = text.copy()
        settings = schema.normalize({"text": "😀\ue002", "textColor": "#FF0000FF", "outlineSize": 0,
                                     "dropShadow": False, "textOffsetX": 16, "textOffsetY": 16})
        output = effects.post_process_pixels(pixels, settings, 32, passes={"text": text})
        np.testing.assert_allclose(output[15, 13], [0, 1, 0, 1])
        np.testing.assert_allclose(output[15, 19], [1, 0, 0, 1])
        np.testing.assert_array_equal(text, original)
        settings.update(textOutlineSize=4, textGlow=True, textShadow=True, textColor="#FF000000")
        output = effects.post_process_pixels(pixels, settings, 32, passes={"text": text})
        self.assertTrue(np.isfinite(output).all())
        self.assertGreater(np.count_nonzero(output[..., 3]), 2)

    def test_provider_preferences_and_unicode_normalization(self):
        with tempfile.TemporaryDirectory() as directory:
            store = config.Store(directory)
            for provider in emoji.PROVIDERS:
                self.assertEqual(store.update_config({"emojiProvider": provider})["emojiProvider"], provider)
                self.assertEqual(store.get_config()["emojiProvider"], provider)
            self.assertEqual(store.update_config({"emojiProvider": "invalid"})["emojiProvider"], "google")
        text = "😀\ue002\n👨‍👩‍👧‍👦\t\ue003"
        self.assertEqual(schema.normalize({"text": text})["text"], text)
        self.assertEqual(schema.normalize({"textEmojiProvider": "invalid"})["textEmojiProvider"], "google")


if __name__ == "__main__":
    unittest.main()
