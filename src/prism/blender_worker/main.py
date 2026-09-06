"""Persistent Blender JSON Lines worker. Run through Blender's --python option."""

from __future__ import annotations

import json
import queue
import sys
import threading
import traceback
from pathlib import Path
from typing import Any

import bpy

PROTOCOL_VERSION = 1
commands: queue.Queue[dict[str, Any]] = queue.Queue()
running = True


def reply(identifier: int, message_type: str, payload: dict[str, Any]) -> None:
    sys.stdout.write(
        json.dumps(
            {"v": PROTOCOL_VERSION, "id": identifier, "type": message_type, "payload": payload}
        )
        + "\n"
    )
    sys.stdout.flush()


def reader() -> None:
    for line in sys.stdin:
        try:
            command = json.loads(line)
            if isinstance(command, dict):
                commands.put(command)
        except json.JSONDecodeError:
            print("Ignoring malformed Prism command.", file=sys.stderr)


def clear_scene() -> None:
    bpy.ops.object.select_all(action="SELECT")
    bpy.ops.object.delete(use_global=False)


def import_model(path: Path) -> None:
    suffix = path.suffix.lower()
    if suffix == ".obj":
        bpy.ops.wm.obj_import(filepath=str(path))
    elif suffix in {".glb", ".gltf"}:
        bpy.ops.import_scene.gltf(filepath=str(path))
    elif suffix == ".fbx":
        bpy.ops.import_scene.fbx(filepath=str(path))
    elif suffix == ".stl":
        bpy.ops.wm.stl_import(filepath=str(path))
    elif suffix == ".blend":
        bpy.ops.wm.open_mainfile(filepath=str(path))
    else:
        raise ValueError(f"Unsupported model format: {suffix}")


def handle(command: dict[str, Any]) -> None:
    global running
    identifier = command.get("id")
    message_type = command.get("type")
    payload = command.get("payload")
    if (
        not isinstance(identifier, int)
        or not isinstance(message_type, str)
        or not isinstance(payload, dict)
    ):
        return
    try:
        if message_type == "worker.hello":
            reply(identifier, "worker.ready", {"blender_version": bpy.app.version_string})
        elif message_type == "worker.shutdown":
            reply(identifier, "worker.stopped", {})
            running = False
            bpy.ops.wm.quit_blender()
        elif message_type == "model.import":
            model_path = Path(str(payload["path"])).expanduser()
            if not model_path.is_file():
                raise ValueError("The selected model file does not exist.")
            clear_scene()
            import_model(model_path)
            reply(identifier, "model.imported", {"path": str(model_path)})
        else:
            reply(
                identifier,
                f"{message_type}.error",
                {"code": "unsupported_command", "message": "Command is not implemented."},
            )
    except (KeyError, RuntimeError, ValueError) as error:
        print(traceback.format_exc(), file=sys.stderr)
        reply(identifier, f"{message_type}.error", {"code": "worker_error", "message": str(error)})


def drain_commands() -> float | None:
    while not commands.empty():
        handle(commands.get_nowait())
    return 0.1 if running else None


threading.Thread(target=reader, daemon=True).start()
bpy.app.timers.register(drain_commands, first_interval=0.1)
