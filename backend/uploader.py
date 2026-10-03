"""Upload rendered PNGs to Roblox through the raven CLI (Open Cloud)."""

import json
import os
import shutil
import sys
from pathlib import Path

from config import CREATOR_PATTERN

UPLOAD_TIMEOUT = 300


class UploadError(RuntimeError):
    pass


def find_raven(configured=""):
    if configured and Path(configured).is_file():
        return configured
    found = shutil.which("raven")
    if found:
        return found
    candidates = []
    if sys.platform == "win32":
        appdata = os.environ.get("APPDATA")
        if appdata:
            candidates.append(Path(appdata) / "npm" / "raven.cmd")
    else:
        candidates += [Path.home() / ".local" / "bin" / "raven", Path.home() / ".npm-global" / "bin" / "raven", Path("/usr/local/bin/raven"),
                       Path("/opt/homebrew/bin/raven")]
    for candidate in candidates:
        if candidate.is_file():
            return str(candidate)
    return None


def upload(path, name, creator, raven_path=""):
    """Upload one image as a Decal. Returns {"assetId", "moderation"}."""
    if not CREATOR_PATTERN.match(creator or ""):
        raise UploadError("Choose who to upload to (user:<id> or group:<id>) in Settings.")
    raven = find_raven(raven_path)
    if raven is None:
        raise UploadError("raven was not found. Re-run the Prism installer or set its path in Settings.")

    from assets import AssetError, run_raven

    try:
        result = run_raven(
            raven, ["--json", "asset", "upload", "--path", str(path), "--creator", creator,
                    "--name", name[:50] or "Prism icon", "--description", "Rendered with Prism"],
            timeout=UPLOAD_TIMEOUT,
        )
    except AssetError as error:
        raise UploadError(str(error)) from error

    if result.returncode != 0:
        message = (result.stderr or result.stdout).strip().lstrip("✖").strip()
        raise UploadError(message or f"raven exited with code {result.returncode}")
    try:
        asset = json.loads(result.stdout)
    except ValueError as error:
        raise UploadError("raven returned output Prism could not read") from error
    asset_id = asset.get("assetId")
    if not asset_id:
        raise UploadError("raven did not return an asset id")
    moderation = (asset.get("moderationResult") or {}).get("moderationState", "Unknown")
    return {"assetId": str(asset_id), "moderation": moderation}
