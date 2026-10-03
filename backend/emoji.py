"""Unicode emoji sequences, provider assets and inline sprite compositing."""

import json
import math
import os
import re
import tempfile
import urllib.request
from functools import lru_cache
from pathlib import Path

import numpy as np
import config

PROVIDERS = ("apple", "google", "facebook", "twitter")
VERSION = "16.0.0"
GLYPHS = Path(__file__).resolve().parent / "glyphs"
ROBLOX = {chr(code): f"{code:04x}.png" for code in range(0xE000, 0xE004)}


@lru_cache(maxsize=1)
def index():
    return json.loads((GLYPHS / "emoji-index.json").read_text(encoding="utf-8"))


def tokens(text):
    """Longest-match sequences keep flags, skin tones and ZWJ families together."""
    entries = index()
    maximum = max(map(len, entries))
    position = 0
    plain = ""
    while position < len(text):
        match = None
        if text[position] in ROBLOX:
            match = text[position]
        else:
            for length in range(min(maximum, len(text) - position), 0, -1):
                candidate = text[position:position + length]
                if candidate in entries:
                    # VS15 explicitly requests a text glyph, rather than an emoji image.
                    if text[position + length:position + length + 1] != "\ufe0e":
                        match = candidate
                    break
        if match:
            if plain:
                yield plain, False
                plain = ""
            yield match, True
            position += len(match)
        else:
            plain += text[position]
            position += 1
    if plain:
        yield plain, False


def decode_text(text):
    """Accept pasted characters and the Lua Unicode notation used in Roblox docs."""
    def replace(match):
        code = int(match.group(1), 16)
        return chr(code) if code <= 0x10FFFF and not 0xD800 <= code <= 0xDFFF else match.group(0)
    return re.sub(r"\\u\{([0-9a-fA-F]{1,6})\}", replace, text).replace("\\n", "\n")


def asset(sequence, provider):
    if sequence in ROBLOX:
        return GLYPHS / ROBLOX[sequence]
    filename, available = index()[sequence]
    provider = provider if provider in PROVIDERS else "google"
    if provider not in available:
        provider = next((p for p in ("google", "apple", "twitter", "facebook") if p in available), None)
    if provider is None:
        raise RuntimeError(f"No emoji artwork is available for {sequence}")
    folder = config.cache_dir() / "emoji" / VERSION / provider
    path = folder / filename
    if path.is_file():
        return path
    folder.mkdir(parents=True, exist_ok=True)
    url = f"https://cdn.jsdelivr.net/npm/emoji-datasource-{provider}@{VERSION}/img/{provider}/64/{filename}"
    temporary = None
    try:
        with urllib.request.urlopen(url, timeout=15) as response:
            data = response.read(1024 * 1024)
        if not data.startswith(b"\x89PNG\r\n\x1a\n"):
            raise ValueError("Emoji download did not return a PNG")
        with tempfile.NamedTemporaryFile(dir=folder, delete=False) as handle:
            temporary = handle.name
            handle.write(data)
        os.replace(temporary, path)
    except (OSError, ValueError) as error:
        raise RuntimeError(f"Could not download {provider} emoji {sequence}. Check your connection and retry: {error}") from error
    finally:
        if temporary and os.path.exists(temporary):
            os.unlink(temporary)
    return path


def place(canvas, sprite, center, side, degrees):
    """Bilinearly sample a rotated sprite into bottom-first straight RGBA pixels."""
    height, width = canvas.shape[:2]
    cx, cy = center
    radius = side * math.sqrt(2) / 2 + 1
    left, right = max(0, int(cx - radius)), min(width, math.ceil(cx + radius))
    bottom, top = max(0, int(cy - radius)), min(height, math.ceil(cy + radius))
    if left >= right or bottom >= top or side <= 0:
        return
    yy, xx = np.mgrid[bottom:top, left:right]
    angle = math.radians(degrees)
    dx, dy = xx + 0.5 - cx, yy + 0.5 - cy
    u = (np.cos(angle) * dx - np.sin(angle) * dy) / side + 0.5
    v = (np.sin(angle) * dx + np.cos(angle) * dy) / side + 0.5
    inside = (u >= 0) & (u <= 1) & (v >= 0) & (v <= 1)
    sh, sw = sprite.shape[:2]
    x, y = np.clip(u * sw - 0.5, 0, sw - 1), np.clip(v * sh - 0.5, 0, sh - 1)
    x0, y0 = x.astype(int), y.astype(int)
    x1, y1 = np.minimum(x0 + 1, sw - 1), np.minimum(y0 + 1, sh - 1)
    fx, fy = (x - x0)[..., None], (y - y0)[..., None]
    premultiplied = sprite.copy()
    premultiplied[..., :3] *= premultiplied[..., 3:4]
    sampled = ((premultiplied[y0, x0] * (1 - fx) + premultiplied[y0, x1] * fx) * (1 - fy)
               + (premultiplied[y1, x0] * (1 - fx) + premultiplied[y1, x1] * fx) * fy)
    sampled *= inside[..., None]
    target = canvas[bottom:top, left:right]
    alpha = sampled[..., 3:4]
    combined = sampled[..., :3] + target[..., :3] * target[..., 3:4] * (1 - alpha)
    coverage = alpha + target[..., 3:4] * (1 - alpha)
    np.divide(combined, coverage, out=target[..., :3], where=coverage > 0)
    target[..., 3:4] = coverage
