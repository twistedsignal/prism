"""Start Blender only for scene/render jobs; release it after 60 idle seconds."""

import json
import secrets
import socket
import subprocess
import tempfile
import time
from pathlib import Path

import config
import runtime
from scene import SceneError

IDLE_SECONDS = 60
STARTUP_TIMEOUT = 30
RENDER_TIMEOUT = 600


class Worker:
    def __init__(self, idle_seconds=IDLE_SECONDS, command=None, cache=None):
        self.idle_seconds = idle_seconds
        self.command = command
        self.cache = cache if cache is not None else config.cache_dir()
        self.process = None
        self.connection = None
        self.stream = None
        self.directory = None
        self.log = None
        self.last_used = 0
        self.version = runtime.settings().get("blenderVersion", "")

    def start(self):
        if self.process is not None and self.process.poll() is None:
            return
        self.close()
        self.directory = tempfile.TemporaryDirectory(prefix="prism-worker-")
        self.log = (Path(self.directory.name) / "worker.log").open("wb")
        token = secrets.token_hex(32)
        try:
            with socket.socket() as listener:
                listener.bind(("127.0.0.1", 0))
                listener.listen()
                listener.settimeout(0.25)
                command = self.command or runtime.blender_command() + [
                    "--background", "--factory-startup", "--python-exit-code", "1",
                    "--python", str(Path(__file__).with_name("worker.py")), "--",
                ]
                options = {}
                if hasattr(subprocess, "CREATE_NO_WINDOW"):
                    options["creationflags"] = subprocess.CREATE_NO_WINDOW
                self.process = subprocess.Popen(
                    command + [str(listener.getsockname()[1]), token, self.directory.name, str(self.cache)],
                    stdin=subprocess.DEVNULL, stdout=self.log, stderr=subprocess.STDOUT,
                    **options,
                )
                deadline = time.monotonic() + STARTUP_TIMEOUT
                while True:
                    if self.process.poll() is not None:
                        raise RuntimeError(self.failure(f"Blender worker exited during startup with code {self.process.returncode}"))
                    if time.monotonic() >= deadline:
                        raise TimeoutError("Blender worker startup timed out")
                    try:
                        connection, _ = listener.accept()
                    except socket.timeout:
                        continue
                    connection.settimeout(min(5, max(0.1, deadline - time.monotonic())))
                    stream = connection.makefile("rwb")
                    try:
                        greeting = json.loads(stream.readline(4096))
                        if greeting.get("token") != token:
                            raise ValueError("Invalid worker token")
                    except (OSError, ValueError):
                        stream.close()
                        connection.close()
                        continue
                    self.connection, self.stream = connection, stream
                    self.version = greeting["version"]
                    self.connection.settimeout(RENDER_TIMEOUT)
                    break
            print(f"[prism] Blender worker started (PID {self.process.pid})", flush=True)
            self.last_used = time.monotonic()
        except BaseException:
            self.close()
            raise

    def call(self, operation, **parameters):
        self.start()
        try:
            self.stream.write(json.dumps({"operation": operation, **parameters}).encode() + b"\n")
            self.stream.flush()
            line = self.stream.readline(1024 * 1024)
            if not line:
                raise RuntimeError(self.failure("Blender worker disconnected; retry the render"))
            response = json.loads(line)
        except (OSError, ValueError, RuntimeError):
            self.close()
            raise
        finally:
            self.last_used = time.monotonic()
        if not response["ok"]:
            error = SceneError if response.get("sceneError") else RuntimeError
            raise error(response["error"])
        return response["result"]

    def failure(self, message):
        if self.directory is not None:
            path = Path(self.directory.name) / "worker.log"
            try:
                with path.open("rb") as log:
                    log.seek(0, 2)
                    log.seek(max(0, log.tell() - 2000))
                    detail = log.read().decode("utf-8", errors="replace").strip()
                if detail:
                    return f"{message}\n{detail}"
            except OSError:
                pass
        return message

    def add_scene(self, raw):
        self.start()
        path = Path(self.directory.name) / "scene.json"
        try:
            path.write_bytes(raw)
            return self.call("scene")
        finally:
            path.unlink(missing_ok=True)

    def render(self, scene_id, settings, size, aa, format="rgba", text_bounds=False):
        result = self.call("render", sceneId=scene_id, settings=settings, size=size, aa=aa,
                           format=format, textBounds=text_bounds)
        path = Path(self.directory.name) / ("render.png" if format == "png" else "render.rgba")
        try:
            pixels = path.read_bytes()
            return (pixels, result.get("textBounds")) if text_bounds else pixels
        finally:
            path.unlink(missing_ok=True)

    def stop_if_idle(self):
        if self.process is not None and time.monotonic() - self.last_used >= self.idle_seconds:
            print("[prism] Releasing idle Blender worker", flush=True)
            self.close()

    def close(self):
        if self.connection is not None:
            try:
                self.connection.shutdown(socket.SHUT_RDWR)
            except OSError:
                pass
        if self.stream is not None:
            try:
                self.stream.close()
            except OSError:
                pass
        if self.connection is not None:
            self.connection.close()
        self.connection = self.stream = None
        if self.process is not None:
            try:
                # EOF lets Blender exit normally and clean up its render files.
                self.process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                self.process.terminate()
                try:
                    self.process.wait(timeout=4)
                except subprocess.TimeoutExpired:
                    self.process.kill()
                    self.process.wait()
            self.process = None
        if self.directory is not None:
            if self.log is not None:
                self.log.close()
                self.log = None
            self.directory.cleanup()
            self.directory = None
