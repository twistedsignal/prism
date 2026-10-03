"""Recover asset references through public delivery, then Raven's saved credentials."""

import base64
import copy
import hashlib
import json
import os
import re
import shutil
import subprocess
import tempfile
import time
import urllib.error
import urllib.request
import xml.etree.ElementTree as ET
from pathlib import Path

import config
import mesh_asset
import uploader

MAX_BYTES = 128 * 1024 * 1024
# Decoded meshes and textures also live on disk; memory only speeds up re-selection.
DECODED_CACHE_BYTES = 16 * 1024 * 1024
# Keep in sync with install.sh and install.ps1 (tests/test_installers.py checks this).
RAVEN_VERSION = "0.3.0"
RAVEN_ARCHIVE = f"https://github.com/twistedsignal/raven/archive/refs/tags/v{RAVEN_VERSION}.tar.gz"
IMAGE_PROPERTIES = (
    "Texture",
    "TextureContent",
    "TextureId",
    "TextureID",
    "ShirtTemplate",
    "ShirtTemplateContent",
    "PantsTemplate",
    "PantsTemplateContent",
    "Graphic",
    "GraphicContent",
    "ColorMap",
    "ColorMapContent",
)


class AssetError(RuntimeError):
    pass


def asset_id(value):
    if not isinstance(value, str) or not re.fullmatch(r"[1-9][0-9]*", value):
        raise AssetError("Asset ID must be a positive numeric string")
    return value


def raven_environment(path):
    env = dict(os.environ)
    env["PATH"] = os.pathsep.join([str(Path(path).parent), env.get("PATH", "")])
    env["NO_COLOR"] = "1"
    return env


def run_raven(path, arguments, timeout=180):
    # npm's Windows .cmd shim needs cmd.exe; keys remain in Raven's credentials/environment.
    command = [path, *arguments]
    if os.name == "nt" and str(path).lower().endswith((".cmd", ".bat")):
        command = [
            os.environ.get("COMSPEC", "cmd.exe"),
            "/d",
            "/s",
            "/c",
            subprocess.list2cmdline(command),
        ]
    try:
        return subprocess.run(
            command,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=timeout,
            env=raven_environment(path),
            check=False,
        )
    except (OSError, subprocess.TimeoutExpired) as error:
        raise AssetError(
            "Could not run Raven or its request timed out. Re-run the Prism installer."
        ) from error


def supports_download(path):
    if not path:
        return False
    result = run_raven(path, ["asset", "download", "--help"], timeout=20)
    return result.returncode == 0 and "--output" in result.stdout


def ensure_raven(configured=""):
    path = uploader.find_raven(configured)
    if supports_download(path):
        enable_download(path)
        return path
    npm = shutil.which("npm.cmd" if os.name == "nt" else "npm")
    if not npm:
        raise AssetError(
f"Raven v{RAVEN_VERSION} is required. Install Node.js and re-run the Prism installer."
        )
    result = run_raven(npm, ["install", "-g", RAVEN_ARCHIVE], timeout=300)
    if result.returncode and os.name != "nt":
        result = run_raven(
            npm,
            ["install", "-g", "--prefix", str(Path.home() / ".local"), RAVEN_ARCHIVE],
            timeout=300,
        )
    if result.returncode:
        raise AssetError(
            "Could not upgrade Raven. Re-run the Prism installer before updating Prism."
        )
    candidates = [
        uploader.find_raven(configured),
        uploader.find_raven(),
        str(Path.home() / ".local" / "bin" / "raven"),
        str(Path.home() / ".npm-global" / "bin" / "raven"),
    ]
    path = next(
        (
            candidate
            for candidate in candidates
            if candidate and Path(candidate).is_file() and supports_download(candidate)
        ),
        None,
    )
    if path is None:
        raise AssetError(
            "Raven was upgraded but its download command is unavailable. Re-run the Prism installer."
        )
    enable_download(path)
    return path


def enable_download(path):
    result = run_raven(
        path, ["--json", "auth", "enable", "--feature", "asset-download"], timeout=20
    )
    if result.returncode:
        raise AssetError(
            "Could not enable Raven asset downloads. Re-run the Prism installer."
        )


def read_public(identifier):
    url = f"https://assetdelivery.roblox.com/v1/asset/?id={identifier}"
    request = urllib.request.Request(url, headers={"User-Agent": f"Prism/{config.version()}"})
    with urllib.request.urlopen(request, timeout=20) as response:
        data = response.read(MAX_BYTES + 1)
    if not data or len(data) > MAX_BYTES:
        raise AssetError("Empty asset or asset exceeds 128 MB")
    return data


def image_reference(data):
    """The image asset ID inside a Roblox asset document (Decal, Shirt, ...), or None."""
    try:
        root = ET.fromstring(data)
    except ET.ParseError as error:
        raise AssetError("Invalid Roblox texture asset document") from error
    for content in root.iter("Content"):
        if content.get("name") in IMAGE_PROPERTIES:
            match = re.search(
                r"(?:rbxassetid://|[?&]id=)([1-9][0-9]*)",
                content.findtext("url", ""),
                re.IGNORECASE,
            )
            if match:
                return match.group(1)
    return None


def valid_content(data):
    return data.startswith(
        (b"version ", b"\x89PNG\r\n\x1a\n", b"\xff\xd8\xff", b"<roblox", b"<?xml")
    )


class Resolver:
    def __init__(self, root, raven_path=lambda: ""):
        self.root = Path(root) / "assets"
        self.root.mkdir(parents=True, exist_ok=True)
        self.raven_path = raven_path
        self.decoded = {}
        self.decoded_bytes = 0
        self.decoded_sizes = {}
        self.routes_path = self.root / "routes.json"
        try:
            self.routes = json.loads(self.routes_path.read_text())
            if not isinstance(self.routes, dict):
                self.routes = {}
        except (OSError, ValueError):
            self.routes = {}

    def remember_route(self, identifier, seconds):
        self.routes = {
            key: value
            for key, value in self.routes.items()
            if isinstance(value, (int, float)) and value > time.time()
        }
        self.routes[identifier] = time.time() + seconds
        temporary = self.routes_path.with_suffix(".tmp")
        try:
            temporary.write_text(json.dumps(self.routes))
            temporary.replace(self.routes_path)
        finally:
            temporary.unlink(missing_ok=True)

    def decode_cached(self, identifier, kind, loader):
        data = self.download(identifier)
        digest = hashlib.sha256(data).hexdigest()
        key = (identifier, kind, digest)
        if key in self.decoded:
            return self.decoded[key]
        path = self.root / f"{identifier}.{kind}.json"
        try:
            cached = (
                json.loads(path.read_text())
                if path.stat().st_size <= 128 * 1024 * 1024
                else {}
            )
        except (OSError, ValueError):
            cached = {}
        if cached.get("digest") == digest and "data" in cached:
            result = cached["data"]
        else:
            result = loader(data)
        serialized = json.dumps({"digest": digest, "data": result})
        weight = len(serialized)
        if weight <= 128 * 1024 * 1024:
            temporary = path.with_suffix(".tmp")
            try:
                temporary.write_text(serialized)
                temporary.replace(path)
            finally:
                temporary.unlink(missing_ok=True)
        if weight <= DECODED_CACHE_BYTES:
            while self.decoded and (
                self.decoded_bytes + weight > DECODED_CACHE_BYTES
                or len(self.decoded) >= 32
            ):
                removed = next(iter(self.decoded))
                self.decoded.pop(removed)
                self.decoded_bytes -= self.decoded_sizes.pop(removed)
            self.decoded[key] = result
            self.decoded_sizes[key] = weight
            self.decoded_bytes += weight
        return result

    def download(self, identifier):
        identifier = asset_id(identifier)
        cached = self.root / identifier
        if cached.is_file():
            data = cached.read_bytes()
            if valid_content(data) and len(data) <= MAX_BYTES:
                return data
            cached.unlink()
        descriptor, temporary = tempfile.mkstemp(
            prefix=f".{identifier}-", dir=self.root
        )
        os.close(descriptor)
        temporary = Path(temporary)
        try:
            try:
                if self.routes.get(identifier, 0) > time.time():
                    raise AssetError("Legacy access is known to be unavailable")
                try:
                    data = read_public(identifier)
                except urllib.error.HTTPError as error:
                    error.close()
                    self.remember_route(
                        identifier, 86400 if error.code in (400, 401, 403, 404) else 60
                    )
                    raise
                except OSError:
                    self.remember_route(identifier, 60)
                    raise
                if not valid_content(data):
                    raise AssetError(
                        "Legacy delivery returned unsupported asset content"
                    )
                temporary.write_bytes(data)
            except (OSError, ValueError, AssetError):
                raven = uploader.find_raven(self.raven_path())
                if not raven:
                    raise AssetError(
                        "Raven was not found. Re-run the Prism installer."
                    ) from None
                result = run_raven(
                    raven,
                    [
                        "--json",
                        "asset",
                        "download",
                        "--id",
                        identifier,
                        "--output",
                        str(temporary),
                    ],
                )
                if result.returncode:
                    # Avoid echoing signed URLs or arbitrary CLI output into the Studio UI.
                    message = result.stderr.lower()
                    if "legacy" in message or "403" in message or "disabled" in message:
                        raise AssetError(
                            "Add Legacy Assets > Manage to your Raven key and re-run the Prism installer."
                        )
                    raise AssetError(
                        f"Raven could not download the asset. Check your key, asset access, and Raven v{RAVEN_VERSION}."
                    )
                try:
                    info = json.loads(result.stdout)
                    data = temporary.read_bytes()
                    if info["assetId"] != identifier or info["bytes"] != len(data):
                        raise ValueError("Download metadata mismatch")
                except (ValueError, KeyError, OSError) as error:
                    raise AssetError("Raven returned an incomplete download") from error
            if not valid_content(data) or len(data) > MAX_BYTES:
                raise AssetError(
                    "Asset delivery returned unsupported or oversized content"
                )
            temporary.replace(cached)
            return data
        finally:
            temporary.unlink(missing_ok=True)

    def decal_image_id(self, identifier):
        """The image ID behind an uploaded Decal, or None if Roblox hasn't exposed it yet."""
        try:
            data = self.download(identifier)
            if not data.startswith((b"<roblox", b"<?xml")):
                return None
            return image_reference(data)
        except (AssetError, OSError, ValueError):
            return None

    def mesh(self, identifier):
        return self.decode_cached(identifier, "mesh", mesh_asset.decode)

    def texture(self, identifier, depth=0):
        if depth > 4:
            raise AssetError(
                "Texture asset references form a cycle or exceed four levels"
            )
        return self.decode_cached(
            identifier,
            "texture",
            lambda data: self.load_texture(identifier, data, depth),
        )

    def load_texture(self, identifier, data, depth):
        if data.startswith((b"<roblox", b"<?xml")):
            reference = image_reference(data)
            if reference is None:
                raise AssetError("Asset document has no downloadable image reference")
            return self.texture(reference, depth + 1)
        import bpy
        import numpy as np

        image = bpy.data.images.load(str(self.root / identifier), check_existing=False)
        try:
            image.colorspace_settings.name = "Non-Color"
            width, height = image.size
            if not 0 < width <= 4096 or not 0 < height <= 4096:
                raise AssetError("Texture dimensions exceed 4096 pixels")
            values = np.empty(width * height * 4, dtype=np.float32)
            image.pixels.foreach_get(values)
            pixels = (
                np.clip(values.reshape(height, width, 4)[::-1], 0, 1) * 255 + 0.5
            ).astype(np.uint8)
            return {
                "width": width,
                "height": height,
                "pixels": base64.b64encode(pixels.tobytes()).decode("ascii"),
            }
        finally:
            bpy.data.images.remove(image)

    def resolve(self, payload):
        payload = copy.deepcopy(payload)
        warnings = []
        incomplete = False
        # HttpService serializes an empty Luau table as []; accept it as an empty map.
        if not payload.get("textures"):
            payload["textures"] = {}
        textures = payload["textures"]
        mesh_results, texture_results, failures = {}, {}, {}
        for part in payload.get("parts", []):
            mesh = part.get("mesh") or {}
            identifier = mesh.get("assetId")
            if identifier and not mesh.get("positions"):
                try:
                    if identifier in failures:
                        raise AssetError(failures[identifier])
                    if identifier not in mesh_results:
                        mesh_results[identifier] = self.mesh(identifier)
                    part["mesh"] = {**mesh, **mesh_results[identifier]}
                except (AssetError, mesh_asset.MeshError, OSError, ValueError) as error:
                    if isinstance(error, mesh_asset.MeshError):
                        (self.root / identifier).unlink(missing_ok=True)
                    failures[identifier] = str(error)
                    warnings.append(f"Mesh {identifier}: {error}; using a box")
                    part["kind"] = "block"
                    incomplete = True
            references = [("texture", part.get("texture"))]
            references += [("layer", layer) for layer in part.get("layers", [])]
            if isinstance(part.get("material"), dict):
                references.append(("material", part["material"].get("texture")))
            retained_layers = []
            for kind, texture in references:
                if not texture:
                    continue
                identifier = texture.get("assetId")
                if not identifier:
                    if kind == "layer":
                        retained_layers.append(texture)
                    continue
                try:
                    if identifier in failures:
                        raise AssetError(failures[identifier])
                    if identifier not in texture_results:
                        texture_results[identifier] = self.texture(identifier)
                    textures[identifier] = texture_results[identifier]
                    texture["id"] = identifier
                    if kind == "layer":
                        retained_layers.append(texture)
                except (AssetError, OSError, ValueError, RuntimeError) as error:
                    (self.root / identifier).unlink(missing_ok=True)
                    failures[identifier] = str(error)
                    if kind == "material":
                        # Fall back to the variant's base material texture.
                        warnings.append(f"MaterialVariant texture {identifier}: {error}; using the base material")
                        part["material"].pop("texture", None)
                    else:
                        warnings.append(f"Texture {identifier}: {error}; using part color")
                    if kind == "texture":
                        part.pop("texture", None)
                    incomplete = True
            part["layers"] = retained_layers
        return payload, list(dict.fromkeys(warnings)), incomplete
