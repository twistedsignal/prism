"""Shared-memory RGBA frame transfer from Blender to Qt."""

from __future__ import annotations

from contextlib import suppress
from multiprocessing import shared_memory
from typing import Any

from PySide6.QtGui import QImage, QPixmap


def take_preview_frame(payload: dict[str, Any]) -> QPixmap:
    name = payload.get("name")
    width = payload.get("width")
    height = payload.get("height")
    stride = payload.get("stride")
    if (
        not isinstance(name, str)
        or not isinstance(width, int)
        or not isinstance(height, int)
        or not isinstance(stride, int)
    ):
        raise ValueError("Blender sent invalid shared-memory frame metadata.")
    memory = shared_memory.SharedMemory(name=name)
    try:
        assert memory.buf is not None
        image = QImage(memory.buf, width, height, stride, QImage.Format.Format_RGBA8888)
        return QPixmap.fromImage(image.copy())
    finally:
        memory.close()
        with suppress(FileNotFoundError):
            memory.unlink()
