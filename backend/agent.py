"""Versioned live-Studio jobs. No operation executes arbitrary Studio code."""
import copy
import json
import threading
import time
import uuid
from pathlib import Path

import assets
import config
import schema
import uploader

API_VERSION = 1
TERMINAL = {"completed", "partial", "failed"}


class AgentError(ValueError):
    pass


class Broker:
    def __init__(self, bridge, clock=time.monotonic):
        self.bridge, self.clock = bridge, clock
        self.lock = threading.RLock()
        self.sessions = {}
        self.jobs = {}
        self.closed = False
        self.legacy_version = None

    def expire(self):
        now = self.clock()
        for identifier, session in list(self.sessions.items()):
            if now - session["seen"] > 30:
                del self.sessions[identifier]
                for job in self.jobs.values():
                    if job["session"] == identifier and job["status"] in {"queued", "studio"}:
                        job.update(status="failed", error="Studio session disconnected; submit a new job after reconnecting")
        for identifier, job in list(self.jobs.items()):
            if job["status"] in TERMINAL and now - job["created"] > 3600:
                del self.jobs[identifier]

    def register(self, body):
        if body.get("apiVersion") != API_VERSION:
            raise AgentError("Unsupported agent API; update Prism and restart Studio")
        identifier = body.get("id")
        if not isinstance(identifier, str) or not identifier or len(identifier) > 100:
            raise AgentError("Session id is required")
        with self.lock:
            self.expire()
            if identifier not in self.sessions and len(self.sessions) >= 32:
                raise AgentError("Too many Studio sessions")
            self.sessions[identifier] = {"id": identifier, "name": str(body.get("name", "Studio"))[:200],
                                         "placeId": body.get("placeId", 0), "pluginVersion": body.get("pluginVersion"),
                                         "apiVersion": API_VERSION, "seen": self.clock()}
        return {"id": identifier, "apiVersion": API_VERSION}

    def session_list(self):
        with self.lock:
            self.expire()
            return [{k: v for k, v in s.items() if k != "seen"} for s in self.sessions.values()]

    def options(self, values, defaults, validate_upload=True):
        if not isinstance(values, dict):
            raise AgentError("Each item must be an object")
        result = copy.deepcopy(defaults)
        preset = values.get("preset")
        if preset is not None:
            if not isinstance(preset, str):
                raise AgentError("preset must be a name")
            presets = self.bridge.store.get_presets()
            if preset not in presets:
                raise AgentError(f"Unknown preset: {preset}")
            result["settings"].update(presets[preset])
        overrides = values.get("settings", {})
        if not isinstance(overrides, dict):
            raise AgentError("settings must be an object")
        for key, value in overrides.items():
            if key not in schema.SETTINGS:
                raise AgentError(f"Unknown setting: {key}")
            setting = schema.SETTINGS[key]
            normalized = schema.normalize_value(setting, value)
            valid_color = setting["type"] in ("color", "rgba") and isinstance(value, str) and (
                schema.HEX_COLOR if setting["type"] == "color" else schema.HEX_RGBA).fullmatch(value)
            if not valid_color and (normalized != value or type(value) is bool and setting["type"] != "bool"):
                raise AgentError(f"Invalid value for {key}; inspect prism schema")
            result["settings"][key] = normalized
        if "textEmojiProvider" in overrides:
            result["emojiProvider"] = overrides["textEmojiProvider"]
        for key in ("size", "aa", "emojiProvider", "creator", "output", "name", "upload"):
            if key in values:
                result[key] = values[key]
        if type(result["size"]) is not int or result["size"] not in config.RENDER_SIZE_OPTIONS:
            raise AgentError("Unsupported resolution; inspect prism schema")
        if result["aa"] not in config.AA_OPTIONS or result["emojiProvider"] not in ("apple", "google", "facebook", "twitter"):
            raise AgentError("Invalid anti-aliasing or emoji provider")
        if not isinstance(result.get("upload", False), bool):
            raise AgentError("upload must be boolean")
        if validate_upload and result.get("upload") and (not isinstance(result["creator"], str) or not config.CREATOR_PATTERN.fullmatch(result["creator"])):
            raise AgentError("Upload requires creator user:<id> or group:<id>, or a default creator in Settings")
        for key in ("output", "name"):
            if key in result and (not isinstance(result[key], str) or not result[key]):
                raise AgentError(f"{key} must be a non-empty string")
        if "output" in result and Path(result["output"]).suffix.lower() != ".png":
            raise AgentError("output must be a PNG filename")
        return result

    def submit(self, body):
        with self.lock:
            self.expire()
            session = body.get("session")
            if not session:
                if len(self.sessions) != 1:
                    raise AgentError("Choose --session when multiple sessions are open" if self.sessions else
                                     "No agent-capable Studio session. Open Studio and allow Prism localhost access. If upgraded, restart Studio.")
                session = next(iter(self.sessions))
            if session not in self.sessions:
                raise AgentError("Studio session is missing or expired")
            if len(self.jobs) >= 256:
                terminal = next((identifier for identifier, j in self.jobs.items() if j["status"] in TERMINAL), None)
                if terminal:
                    del self.jobs[terminal]
                else:
                    raise AgentError("Agent job capacity reached; wait for active jobs to finish")
            operation = body.get("operation", "render")
            if operation not in ("models", "render", "upload", "batch"):
                raise AgentError("Unsupported agent operation")
            job = {"id": uuid.uuid4().hex, "session": session, "operation": operation,
                   "status": "queued", "created": self.clock()}
            if operation == "models":
                root, query, limit = body.get("root", "Workspace"), body.get("query", ""), body.get("limit", 100)
                if not isinstance(root, (str, list)) or not isinstance(query, str) or not isinstance(limit, int) or isinstance(limit, bool) or not 1 <= limit <= 1000:
                    raise AgentError("Invalid model discovery options")
                job["request"] = {"operation": "models", "root": root, "query": query, "limit": limit}
            else:
                cfg = self.bridge.store.get_config()
                base = {"settings": dict(schema.DEFAULTS), "size": cfg["renderSize"], "aa": cfg["renderAA"],
                        "emojiProvider": cfg["emojiProvider"], "creator": cfg["defaultCreator"], "upload": operation == "upload"}
                shared = self.options(body.get("defaults", {}), base, validate_upload=False)
                items = body.get("items") if operation == "batch" else [body]
                if not isinstance(items, list) or not 1 <= len(items) <= 100:
                    raise AgentError("items must contain 1 to 100 targets")
                prepared = []
                for index, item in enumerate(items):
                    settings = self.options(item, shared)
                    if not item.get("target") and not item.get("path"):
                        raise AgentError("Each item needs target or path")
                    if item.get("target") is not None and (not isinstance(item["target"], str) or not item["target"]):
                        raise AgentError("target must be a non-empty id")
                    path = item.get("path")
                    if path is not None and (not isinstance(path, (str, list)) or not path or isinstance(path, list) and not all(isinstance(p, str) and p for p in path)):
                        raise AgentError("path must be a dotted string or non-empty array of names")
                    settings.update(target=item.get("target"), path=path)
                    if "output" not in settings:
                        directory = body.get("outputDir") or cfg["outputFolder"]
                        if not isinstance(directory, str):
                            raise AgentError("outputDir must be a directory path")
                        folder = Path(directory).expanduser()
                        # Unique job paths avoid overwriting manual renders or earlier agent jobs.
                        settings["output"] = str(folder / f"prism-{job['id']}-{index + 1}.png")
                    if not Path(settings["output"]).is_absolute():
                        raise AgentError("Output paths must be absolute")
                    prepared.append(settings)
                outputs = [item["output"] for item in prepared]
                if len(set(outputs)) != len(outputs):
                    raise AgentError("Batch output filenames must be distinct")
                job["items"] = prepared
                job["request"] = {"operation": "serialize", "items": [{"target": i["target"], "path": i["path"]} for i in prepared]}
            self.jobs[job["id"]] = job
            return self.public(job)

    def poll(self, body):
        with self.lock:
            self.expire()
            session = self.sessions.get(body.get("session"))
            if session is None:
                raise AgentError("Session expired; register again")
            session["seen"] = self.clock()
            active = [j for j in self.jobs.values() if j["session"] == session["id"] and j["status"] not in TERMINAL]
            if not active or active[0]["status"] != "queued":
                return {"job": None}
            job = active[0]
            job["status"] = "studio"
            return {"job": dict(job["request"], id=job["id"])}

    def complete(self, body):
        with self.lock:
            self.expire()
            job = self.jobs.get(body.get("id"))
            if job is None or job["session"] != body.get("session"):
                raise AgentError("Unknown job or wrong session")
            if job["status"] != "studio":
                return self.public(job)  # A lost HTTP response must not repeat an upload.
            if body.get("error"):
                job.update(status="failed", error=str(body["error"]))
            elif job["operation"] == "models":
                if not isinstance(body.get("models"), list):
                    raise AgentError("models must be a list")
                job.update(status="completed", models=body["models"], truncated=body.get("truncated", False))
            else:
                items = body.get("items")
                if not isinstance(items, list) or not all(isinstance(i, dict) for i in items) or len(items) != len(job["items"]):
                    raise AgentError("Studio response must match the requested items")
                job["status"] = "processing"
                threading.Thread(target=self.process, args=(job, items), daemon=True).start()
            return self.public(job)

    def process(self, job, snapshots):
        results = []
        for index, (item, snapshot) in enumerate(zip(job["items"], snapshots), 1):
            result = {"index": index, "name": item.get("name") or snapshot.get("name") or f"Icon {index}"}
            try:
                if self.closed:
                    raise AgentError("Backend stopped; job interrupted")
                if snapshot.get("error"):
                    raise AgentError(snapshot["error"])
                payload = snapshot.get("payload")
                if not isinstance(payload, dict) or not payload.get("parts"):
                    raise AgentError("Target has no visible parts")
                def render_item():
                    scene = self.bridge.worker.add_scene(json.dumps(payload).encode())
                    png = self.bridge.render(scene["sceneId"], item["settings"], item["size"], item["aa"], "png",
                                             emoji_provider=item["emojiProvider"])
                    return png, scene.get("warnings", [])
                png, warnings = self.bridge.jobs.submit(render_item, timeout=600)
                path = Path(item["output"])
                path.parent.mkdir(parents=True, exist_ok=True)
                # Exclusive creation makes accidental overwrites an explicit per-item error.
                with path.open("xb") as file:
                    file.write(png)
                result.update(path=str(path), warnings=list(dict.fromkeys(snapshot.get("warnings", []) + warnings)))
                if item["upload"]:
                    cfg = self.bridge.store.get_config()
                    if self.closed:
                        raise AgentError("Backend stopped before upload")
                    result["uploadStarted"] = True
                    result.update(uploader.upload(path, result["name"], item["creator"], cfg["ravenPath"]))
                    resolver = assets.Resolver(config.cache_dir(), lambda: cfg["ravenPath"])
                    result["imageId"] = resolver.decal_image_id(result["assetId"])
            except Exception as error:  # Report failures without abandoning the remaining targets.
                result["error"] = str(error)
            results.append(result)
            with self.lock:
                job["results"] = copy.deepcopy(results)
        with self.lock:
            failures = sum("error" in result for result in results)
            job["status"] = "failed" if failures == len(results) else "partial" if failures else "completed"
            job.pop("items", None)

    @staticmethod
    def public(job):
        return copy.deepcopy({k: v for k, v in job.items() if k not in ("request", "items", "created")})

    def get(self, identifier):
        with self.lock:
            self.expire()
            if identifier not in self.jobs:
                raise AgentError("Unknown job; jobs are lost on backend restart. Do not automatically resubmit uploads.")
            return self.public(self.jobs[identifier])
