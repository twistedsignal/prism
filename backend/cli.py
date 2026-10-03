"""Prism's terminal interface for live Studio renders."""
import argparse
import json
import math
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent))
import config

INSTRUCTIONS = """Use Prism to render live Roblox Studio parts and models.
Run prism status --json, then prism sessions --json. Select a session explicitly when several are open.
Discover target ids with prism models --session ID --root Workspace --query NAME --json.
Use prism schema --json, prism fonts --json and prism presets --json for supported settings.
Render with prism render --session ID --target ID --preset NAME --size 1024 --output /absolute/icon.png --json.
Use --path Workspace.Folder.Model or --path-json '[\"Workspace\",\"Name.with.dots\"]' instead of a target id.
Use --settings '{\"cameraRotation\":45,\"text\":\"Hello 😀\"}' or --settings-file FILE for per-call settings.
Use --aa 32 and --emoji-provider apple for per-call quality and emoji overrides.
Upload with prism upload using the same options plus --creator user:ID or group:ID.
Batch with prism batch MANIFEST.json --json. Manifest: {\"session\":\"ID\",\"defaults\":{\"preset\":\"NAME\",\"size\":512},\"items\":[{\"path\":\"Workspace.Model\",\"output\":\"/absolute/icon.png\",\"upload\":false}]}.
Batch defaults and each item accept settings, preset, size, aa, emojiProvider, creator and upload.
Inspect a timed-out job with prism job JOB_ID --json. Never automatically resubmit an upload after a timeout or backend restart.
Commands return JSON; progress goes to stderr. Exit 0 means success, 1 means failure or partial failure, 2 means waiting timed out.
Options never change saved preferences or panel settings. Output files are not overwritten.
If no Studio session is available, open Studio and allow Prism localhost HTTP access. Restart Studio after upgrading the plugin.
"""


class Client:
    def __init__(self, port=None):
        self.port = port or config.Store().get_config()["port"]

    def request(self, method, route, body=None):
        request = urllib.request.Request(f"http://127.0.0.1:{self.port}{route}", method=method,
            data=json.dumps(body).encode() if body is not None else None,
            headers={"X-Prism": "1", "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(request, timeout=30) as response:
                return json.load(response)
        except urllib.error.HTTPError as error:
            try:
                message = json.load(error).get("error", str(error))
            except (ValueError, AttributeError):
                message = str(error)
            raise RuntimeError(message) from error
        except urllib.error.URLError as error:
            raise RuntimeError(f"Prism backend unavailable on port {self.port}. Start Prism or rerun the installer: {error.reason}") from error

    def wait(self, job, timeout):
        end = time.monotonic() + timeout
        next_progress = time.monotonic() + 3
        while job["status"] not in ("completed", "partial", "failed"):
            if time.monotonic() >= end:
                return dict(job, timedOut=True), 2
            time.sleep(min(0.5, max(0, end - time.monotonic())))
            job = self.request("GET", "/agent/v1/jobs/" + job["id"])
            if job["status"] not in ("completed", "partial", "failed") and time.monotonic() >= next_progress:
                progress = job.get("progress") or {}
                count = f" ({progress['completed']}/{progress['total']} steps)" if progress.get("total") else ""
                elapsed = f" {progress['elapsedSeconds']:.0f}s" if "elapsedSeconds" in progress else ""
                item = f" item {progress['itemIndex']}/{progress['itemTotal']}" if "itemIndex" in progress else ""
                print(f"Prism {job['id']}:{item} {progress.get('stage', job['status'])}{count}{elapsed}", file=sys.stderr)
                next_progress = time.monotonic() + 3
        return job, 0 if job["status"] == "completed" else 1


def parser():
    root = argparse.ArgumentParser(prog="prism", description="Render live Studio models without changing selection or preferences")
    commands = root.add_subparsers(dest="command", required=True)
    for name in ("status", "sessions", "models", "schema", "fonts", "presets", "render", "upload", "batch", "job", "agent"):
        cmd = commands.add_parser(name)
        cmd.add_argument("--json", action="store_true", help="Print structured JSON (also the default for results)")
        cmd.add_argument("--port", type=int, help="Override the configured local backend port")
        if name in ("models", "render", "upload", "batch"):
            cmd.add_argument("--session")
            cmd.add_argument("--timeout", type=float, default=300, help="Wait seconds; timed-out jobs continue, use prism job to inspect")
        if name == "models":
            cmd.add_argument("--root", default="Workspace")
            cmd.add_argument("--query", default="")
            cmd.add_argument("--limit", type=int, default=100)
        if name in ("render", "upload"):
            target = cmd.add_mutually_exclusive_group(required=True)
            target.add_argument("--target")
            target.add_argument("--path")
            target.add_argument("--path-json", help="JSON array of exact instance names")
            cmd.add_argument("--preset")
            settings = cmd.add_mutually_exclusive_group()
            settings.add_argument("--settings", help="JSON object of render setting overrides")
            settings.add_argument("--settings-file", type=Path)
            cmd.add_argument("--size", type=int)
            cmd.add_argument("--aa")
            cmd.add_argument("--emoji-provider", choices=("apple", "google", "facebook", "twitter"))
            cmd.add_argument("--output", type=Path)
            cmd.add_argument("--creator")
            cmd.add_argument("--name")
        if name == "batch":
            cmd.add_argument("manifest", type=Path)
        if name == "job":
            cmd.add_argument("id")
            cmd.add_argument("--wait", action="store_true")
            cmd.add_argument("--timeout", type=float, default=300)
        if name == "agent":
            cmd.add_argument("action", choices=("instructions", "describe", "install-skill"))
            cmd.add_argument("--directory", type=Path, help="Agent's skills directory; installs its prism subdirectory")
    return root


def absolute_outputs(body):
    for values in [body, body.get("defaults", {}), *body.get("items", [])]:
        if isinstance(values, dict) and "output" in values:
            values["output"] = str(Path(values["output"]).expanduser().resolve())
    if "outputDir" in body:
        body["outputDir"] = str(Path(body["outputDir"]).expanduser().resolve())
    return body


def execute(args):
    if hasattr(args, "timeout") and (not math.isfinite(args.timeout) or args.timeout < 0):
        raise ValueError("timeout must be finite and non-negative")
    if args.command == "agent":
        if args.action == "instructions":
            return {"instructions": INSTRUCTIONS}, 0
        if args.action == "describe":
            return {"apiVersion": 1, "commands": ["status", "sessions", "models", "schema", "fonts", "presets", "render", "upload", "batch", "job"],
                    "instructions": INSTRUCTIONS, "batchExample": {"defaults": {"size": 1024}, "items": [{"path": ["Workspace", "Crate"]}]}}, 0
        if args.directory is None:
            raise ValueError("Pass --directory with your agent's skills directory")
        destination = args.directory.expanduser().resolve() / "prism" / "SKILL.md"
        content = Path(__file__).with_name("agent-skill.md").read_text(encoding="utf-8")
        if destination.exists() and destination.read_text(encoding="utf-8") != content:
            raise ValueError(f"Skill already exists at {destination}; remove it explicitly before replacing it")
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(content, encoding="utf-8")
        return {"path": str(destination)}, 0
    client = Client(args.port)
    if args.command == "status":
        import cli_install
        result = client.request("GET", "/status")
        result.update(cli_install.discovery())
        return result, 0
    if args.command in ("sessions", "schema", "fonts", "presets"):
        route = "/agent/v1/sessions" if args.command == "sessions" else "/" + args.command
        result = client.request("GET", route)
        if args.command == "schema":
            result["jobOptions"] = {"sizes": config.RENDER_SIZE_OPTIONS, "aa": config.AA_OPTIONS,
                                    "emojiProviders": ["apple", "google", "facebook", "twitter"]}
        return result, 0
    if args.command == "job":
        if args.timeout < 0:
            raise ValueError("timeout cannot be negative")
        job = client.request("GET", "/agent/v1/jobs/" + args.id)
        return client.wait(job, args.timeout) if args.wait else (job, 1 if job["status"] in ("failed", "partial") else 0)
    if args.timeout < 0:
        raise ValueError("timeout cannot be negative")
    if args.command == "batch":
        body = json.loads(args.manifest.read_text(encoding="utf-8"))
        if not isinstance(body, dict):
            raise ValueError("Batch manifest must be an object")
        body["operation"] = "batch"
        if args.session:
            body["session"] = args.session
    elif args.command == "models":
        body = {"operation": "models", "session": args.session, "root": args.root, "query": args.query, "limit": args.limit}
    else:
        body = {"operation": args.command, "session": args.session}
        for key in ("target", "path", "preset", "size", "aa", "creator", "name"):
            if getattr(args, key) is not None:
                body[key] = getattr(args, key)
        if args.path_json:
            body["path"] = json.loads(args.path_json)
        if args.settings_file:
            body["settings"] = json.loads(args.settings_file.read_text(encoding="utf-8"))
        elif args.settings:
            body["settings"] = json.loads(args.settings)
        if args.emoji_provider:
            body["emojiProvider"] = args.emoji_provider
        if args.output:
            body["output"] = str(args.output)
    status = client.request("GET", "/status")
    if status.get("agentApiVersion") != 1:
        raise RuntimeError("Backend lacks agent API v1; update Prism and restart Studio")
    job = client.request("POST", "/agent/v1/jobs", absolute_outputs(body))
    print(f"Prism job {job['id']} submitted; inspect with prism job {job['id']} --json", file=sys.stderr)
    return client.wait(job, args.timeout)


def main(argv=None):
    args = parser().parse_args(argv)
    try:
        result, code = execute(args)
    except (OSError, ValueError, RuntimeError, TypeError) as error:
        result, code = {"error": str(error)}, 1
    print(json.dumps(result, ensure_ascii=False))
    return code


if __name__ == "__main__":
    sys.exit(main())
