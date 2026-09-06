from __future__ import annotations

import os
from pathlib import Path

import pytest

from prism.renderer.client import BlenderWorkerClient, WorkerState
from prism.renderer.shared_memory import take_preview_frame


@pytest.mark.blender
def test_worker_imports_and_transports_shared_memory_preview(qtbot: object) -> None:
    blender = Path(os.environ.get("PRISM_BLENDER", "/usr/bin/blender"))
    if not blender.is_file():
        pytest.skip("Blender is not installed")
    script = Path("src/prism/blender_worker/main.py")
    fixture = Path("tests/fixtures/cube.obj").resolve()
    client = BlenderWorkerClient(script)
    received_frame = []

    def handle(message: object) -> None:
        if message.type == "worker.ready":
            client.send("model.import", {"path": str(fixture)})
        elif message.type == "model.imported":
            client.send("preview.render", {"generation": 1, "output": {"width": 32, "height": 32}})
        elif message.type == "preview.frame":
            received_frame.append(take_preview_frame(message.payload))
            client.shutdown()

    client.message_received.connect(handle)
    client.start(blender)
    qtbot.waitUntil(lambda: client.state is WorkerState.STOPPED, timeout=30_000)
    assert received_frame[0].size().width() == 32
