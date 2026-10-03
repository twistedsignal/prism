"""Local HTTP API used by the Studio plugin. Binds to 127.0.0.1 only."""

import base64
import json
import re
import sys
import threading
import time
import traceback
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlsplit

import config
import platform_open
import schema
import updater
import uploader
from jobs import JobQueue, Superseded
from scene import SceneCache, SceneError
from worker_client import Worker

import assets

MAX_BODY = 512 * 1024 * 1024
RENDER_TIMEOUT = 600
UNSAFE_FILENAME = re.compile(r'[<>:"/\\|?*\x00-\x1f]+')


class HttpError(Exception):
    def __init__(self, status, message):
        super().__init__(message)
        self.status = status
        self.message = message


def safe_filename(name):
    name = UNSAFE_FILENAME.sub("_", str(name)).strip(" .")
    return name[:100] or "icon"


class Bridge:
    """Shared state for request handlers; Blender jobs use an on-demand worker."""

    def __init__(self, store):
        self.store = store
        self.jobs = JobQueue()
        self.scenes = SceneCache(config.cache_dir())
        self.worker = Worker()
        self.updates = updater.Checker()
        self.updating = threading.Lock()

    # ---- serialized worker jobs -----------------------------------------

    def render(self, scene_id, settings, size, aa, format="rgba"):
        if not self.scenes.exists(scene_id):
            raise HttpError(404, "Unknown scene; send it again")
        return self.worker.render(scene_id, schema.normalize(settings), size, aa, format)

    def output_path(self, folder, name, index, overwrite, pattern):
        stem = safe_filename(pattern.replace("{name}", safe_filename(name)).replace("{index}", str(index)))
        path = folder / f"{stem}.png"
        counter = 2
        while not overwrite and path.exists():
            path = folder / f"{stem} ({counter}).png"
            counter += 1
        return path

    def export(self, items):
        settings_config = self.store.get_config()
        folder = Path(settings_config["outputFolder"]).expanduser()
        folder.mkdir(parents=True, exist_ok=True)
        results = []
        for index, item in enumerate(items, start=1):
            name = item.get("name") or f"Icon {index}"
            try:
                png = self.render(
                    item.get("sceneId"), item.get("settings"),
                    settings_config["renderSize"], settings_config["renderAA"], "png",
                )
                path = self.output_path(
                    folder, name, index, settings_config["overwrite"], settings_config["filenamePattern"],
                )
                path.write_bytes(png)
                results.append({"name": name, "path": str(path)})
            except Exception as error:  # noqa: BLE001 - reported per item
                results.append({"name": name, "error": error_message(error)})
        return results


def error_message(error):
    if isinstance(error, HttpError):
        return error.message
    return str(error) or error.__class__.__name__


def read_items(body):
    items = body.get("items")
    if not isinstance(items, list) or not items:
        raise HttpError(400, "items must be a non-empty list")
    for item in items:
        if not isinstance(item, dict) or not isinstance(item.get("sceneId"), str):
            raise HttpError(400, "each item needs a sceneId")
    return items


def make_handler(bridge):
    class Handler(BaseHTTPRequestHandler):
        server_version = "Prism"
        protocol_version = "HTTP/1.1"

        def log_message(self, format, *args):  # noqa: A002 - signature from the base class
            sys.stdout.write(f"[prism] {self.address_string()} {format % args}\n")

        # ---- plumbing ----------------------------------------------------

        def send_json(self, status, value):
            data = json.dumps(value).encode()
            self.send_response(status)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(data)))
            self.send_header("Cache-Control", "no-store")
            self.end_headers()
            self.wfile.write(data)

        def read_body(self):
            length = int(self.headers.get("Content-Length") or 0)
            if length > MAX_BODY:
                raise HttpError(413, "Request is too large")
            return self.rfile.read(length) if length else b""

        def read_json(self, raw=None):
            raw = self.read_body() if raw is None else raw
            if not raw:
                return {}
            try:
                value = json.loads(raw)
            except ValueError as error:
                raise HttpError(400, "Body is not valid JSON") from error
            if not isinstance(value, dict):
                raise HttpError(400, "Body must be a JSON object")
            return value

        def dispatch(self, method):
            try:
                # Browsers always send Origin on cross-site requests and can't add
                # custom headers without a CORS preflight we never answer.
                if self.headers.get("Origin") is not None:
                    raise HttpError(403, "Browser requests are not allowed")
                if self.headers.get("X-Prism") != "1":
                    raise HttpError(403, "Missing X-Prism header")
                path = self.path.split("?", 1)[0].rstrip("/") or "/"
                handler = ROUTES.get((method, path))
                argument = None
                if handler is None and path.startswith("/presets/"):
                    handler = ROUTES.get((method, "/presets/<name>"))
                    argument = unquote(path[len("/presets/"):])
                if handler is None:
                    raise HttpError(404, "Not found")
                status, value = handler(self, argument) if argument is not None else handler(self)
                self.send_json(status, value)
            except HttpError as error:
                self.send_json(error.status, {"error": error.message})
            except Superseded:
                self.send_json(409, {"error": "superseded"})
            except SceneError as error:
                self.send_json(400, {"error": str(error)})
            except Exception as error:  # noqa: BLE001 - never kill the server thread
                traceback.print_exc()
                self.send_json(500, {"error": error_message(error)})

        def do_GET(self):  # noqa: N802 - http.server naming
            self.dispatch("GET")

        def do_POST(self):  # noqa: N802
            self.dispatch("POST")

        def do_PUT(self):  # noqa: N802
            self.dispatch("PUT")

        def do_DELETE(self):  # noqa: N802
            self.dispatch("DELETE")

        # ---- routes ------------------------------------------------------

        def status(self):
            process = bridge.worker.process
            return 200, {
                "version": config.version(),
                "blender": bridge.worker.version,
                "workerRunning": process is not None and process.poll() is None,
                "busy": bridge.jobs.busy,
                "platform": sys.platform,
            }

        def get_schema(self):
            return 200, schema.schema()

        def get_config(self):
            return 200, bridge.store.get_config()

        def put_config(self):
            return 200, bridge.store.update_config(self.read_json())

        def get_presets(self):
            return 200, bridge.store.get_presets()

        def put_preset(self, name):
            body = self.read_json()
            try:
                saved = bridge.store.save_preset(name, body.get("settings"))
            except ValueError as error:
                raise HttpError(400, str(error)) from error
            return 200, {"name": saved, "presets": bridge.store.get_presets()}

        def delete_preset(self, name):
            if not bridge.store.delete_preset(name):
                raise HttpError(404, "No preset with that name")
            return 200, {"presets": bridge.store.get_presets()}

        def post_scene(self):
            raw = self.read_body()
            self.read_json(raw)
            result = bridge.jobs.submit(lambda: bridge.worker.add_scene(raw), timeout=RENDER_TIMEOUT)
            return 200, result

        def preview(self):
            body = self.read_json()
            settings_config = bridge.store.get_config()
            size = body.get("size", settings_config["previewSize"])
            if size not in config.SIZE_OPTIONS:
                size = settings_config["previewSize"]
            client = body.get("client") if isinstance(body.get("client"), str) else None
            scene_id = body.get("sceneId")
            if not isinstance(scene_id, str):
                raise HttpError(400, "sceneId is required")

            def work():
                return bridge.render(scene_id, body.get("settings"), size, settings_config["previewAA"])

            data = bridge.jobs.submit(work, client=client, timeout=RENDER_TIMEOUT)
            return 200, {"width": size, "height": size, "pixels": base64.b64encode(data).decode("ascii")}

        def export(self):
            items = read_items(self.read_json())
            results = bridge.jobs.submit(lambda: bridge.export(items), timeout=RENDER_TIMEOUT * len(items))
            return 200, {"results": results, "folder": bridge.store.get_config()["outputFolder"]}

        def upload(self):
            body = self.read_json()
            items = read_items(body)
            settings_config = bridge.store.get_config()
            creator = body.get("creator") or settings_config["defaultCreator"]
            if not isinstance(creator, str) or not config.CREATOR_PATTERN.match(creator):
                raise HttpError(400, "Choose who to upload to (user:<id> or group:<id>)")
            results = bridge.jobs.submit(lambda: bridge.export(items), timeout=RENDER_TIMEOUT * len(items))
            # Uploads wait on Roblox, so they run here rather than blocking renders.
            for result in results:
                if "error" in result:
                    continue
                try:
                    result.update(uploader.upload(
                        result["path"], result["name"], creator, settings_config["ravenPath"],
                    ))
                except uploader.UploadError as error:
                    result["error"] = str(error)
            return 200, {"results": results, "creator": creator}

        def update_status(self):
            query = parse_qs(urlsplit(self.path).query)
            plugin_version = (query.get("plugin") or [None])[0]
            force = (query.get("force") or ["0"])[0] == "1"
            return 200, bridge.updates.status(plugin_version, force)

        def update(self):
            if not bridge.updating.acquire(blocking=False):
                raise HttpError(409, "An update is already running")
            try:
                status = bridge.updates.status(force=True)
                version = status["latest"]
                if not version:
                    raise HttpError(502, status["error"] or "Could not find the latest release")
                if not status["canUpdate"]:
                    raise HttpError(400, "Prism is running from a source checkout; update it with git instead.")
                try:
                    plugins = updater.install(version)
                except updater.UpdateError as error:
                    raise HttpError(502, str(error)) from error
            except BaseException:
                bridge.updating.release()
                raise
            print(f"[prism] Updated to {version}; restarting")
            # Restart after this response reaches the plugin.
            threading.Timer(1.0, updater.restart).start()
            return 200, {"version": version, "plugins": plugins, "restarting": True}

        def open_folder(self):
            folder = bridge.store.get_config()["outputFolder"]
            platform_open.open_folder(folder)
            return 200, {"folder": folder}

        def pick_folder(self):
            current = bridge.store.get_config()["outputFolder"]
            chosen = platform_open.pick_folder(current)
            if chosen is None:
                return 200, {"folder": None, "config": bridge.store.get_config()}
            return 200, {"folder": chosen, "config": bridge.store.update_config({"outputFolder": chosen})}

    ROUTES = {
        ("GET", "/status"): Handler.status,
        ("GET", "/schema"): Handler.get_schema,
        ("GET", "/config"): Handler.get_config,
        ("PUT", "/config"): Handler.put_config,
        ("GET", "/presets"): Handler.get_presets,
        ("PUT", "/presets/<name>"): Handler.put_preset,
        ("DELETE", "/presets/<name>"): Handler.delete_preset,
        ("POST", "/scenes"): Handler.post_scene,
        ("POST", "/preview"): Handler.preview,
        ("POST", "/export"): Handler.export,
        ("POST", "/upload"): Handler.upload,
        ("GET", "/update"): Handler.update_status,
        ("POST", "/update"): Handler.update,
        ("POST", "/open-folder"): Handler.open_folder,
        ("POST", "/pick-folder"): Handler.pick_folder,
    }
    return Handler


def bind(bridge, port, attempts=30):
    """Retry briefly: after an update the previous backend may still be releasing the port."""
    for attempt in range(attempts):
        try:
            return ThreadingHTTPServer(("127.0.0.1", port), make_handler(bridge))
        except OSError:
            if attempt == attempts - 1:
                raise
            time.sleep(0.5)


def serve(store, port):
    # A v0.2 updater cannot run the new migration before swapping its backend.
    # Run it on first v0.3 startup too, before accepting scene requests.
    try:
        raven_path = assets.ensure_raven(store.get_config()["ravenPath"])
        store.update_config({"ravenPath": raven_path})
    except assets.AssetError as error:
        print(f"[prism] Asset recovery setup: {error}", flush=True)
    bridge = Bridge(store)
    httpd = bind(bridge, port)
    httpd.daemon_threads = True
    thread = threading.Thread(target=httpd.serve_forever, name="prism-http", daemon=True)
    thread.start()
    print(f"[prism] Prism {config.version()} listening on http://127.0.0.1:{port} (on-demand Blender)")
    sys.stdout.flush()
    try:
        while True:
            bridge.jobs.run_pending()
            bridge.worker.stop_if_idle()
    except KeyboardInterrupt:
        print("[prism] Shutting down")
    finally:
        httpd.shutdown()
        httpd.server_close()
        bridge.worker.close()
