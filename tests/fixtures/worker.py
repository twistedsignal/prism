"""Small IPC worker for lifecycle tests without Blender."""

import json
import os
import socket
import sys
import time
from pathlib import Path

port, token, directory, _cache = sys.argv[1:]
directory = Path(directory)
with socket.create_connection(("127.0.0.1", int(port))) as connection:
    with connection.makefile("rwb") as stream:
        stream.write(json.dumps({"token": token, "version": "test"}).encode() + b"\n")
        stream.flush()
        for line in stream:
            request = json.loads(line)
            result = {}
            if request["operation"] == "scene":
                json.loads((directory / "scene.json").read_bytes())
                result = {"sceneId": "testscene", "warnings": [], "incomplete": False}
            if request["operation"] == "render":
                mode = (request.get("settings") or {}).get("test")
                if mode == "crash":
                    os._exit(2)
                if mode == "timeout":
                    time.sleep(1)
                extension = "png" if request["format"] == "png" else "rgba"
                (directory / f"render.{extension}").write_bytes(b"image")
            response = {"ok": True, "result": result}
            if request["operation"] == "invalid":
                response = {"ok": False, "sceneError": True, "error": "Invalid scene"}
            stream.write(json.dumps(response).encode() + b"\n")
            stream.flush()
