"""Turn the plugin's serialized model into an OBJ/MTL/PNG set the renderer can import.

Payload (all coordinates are Roblox studs, Y up, relative to the model pivot):

    {
      "name": "Sword",
      "parts": [{
        "kind": "block" | "wedge" | "cornerWedge" | "cylinder" | "ball" | "head" | "mesh",
        "cframe": [x, y, z, r00, r01, r02, r10, r11, r12, r20, r21, r22],
        "size": [x, y, z],
        "color": "#RRGGBB",
        "transparency": 0,
        "texture": {"id": "<key in textures>", "mode": "overlay" | "alpha"},
        "mesh": {
          "positions": base64 float32 xyz per triangle corner,
          "uvs": base64 float32 uv per corner (Roblox convention, v down) or null,
          "normals": base64 float32 xyz per corner or null,
          "scale": [x, y, z], "offset": [x, y, z], "center": true
        }
      }],
      "textures": {"<key>": {"width": w, "height": h, "pixels": base64 RGBA8 rows top-down}}
    }
"""

import base64
import hashlib
import json
import math
import shutil
import struct
import sys
import uuid
import zlib
from array import array
from functools import lru_cache
from pathlib import Path

import schema

MAX_CACHED_SCENES = 64
PRIMITIVE_SEGMENTS = 24


class SceneError(ValueError):
    pass


# ============================================================
# DECODING
# ============================================================

def decode_floats(data, name):
    if data is None:
        return None
    try:
        raw = base64.b64decode(data, validate=True)
    except (ValueError, TypeError) as error:
        raise SceneError(f"{name} is not valid base64") from error
    if len(raw) % 4:
        raise SceneError(f"{name} is not a float32 buffer")
    values = array("f")
    values.frombytes(raw)
    if sys.byteorder != "little":
        values.byteswap()
    if any(not math.isfinite(value) for value in values):
        raise SceneError(f"{name} contains non-finite values")
    return values


def vector(values, name, length=3):
    if (
        not isinstance(values, list) or len(values) != length
        or not all(isinstance(v, (int, float)) and math.isfinite(v) for v in values)
    ):
        raise SceneError(f"{name} must be {length} finite numbers")
    return [float(v) for v in values]


def color_of(part):
    value = part.get("color", "#A3A2A5")
    if not isinstance(value, str) or not schema.HEX_COLOR.match(value):
        raise SceneError("Part color must be #RRGGBB")
    return schema.hex_to_rgb(value)


# ============================================================
# PNG
# ============================================================

def write_png(path, width, height, rgba):
    """Write top-down RGBA8 rows with no dependencies beyond zlib."""
    stride = width * 4
    rows = b"".join(b"\x00" + rgba[y * stride:(y + 1) * stride] for y in range(height))

    def chunk(kind, data):
        body = kind + data
        return struct.pack(">I", len(data)) + body + struct.pack(">I", zlib.crc32(body) & 0xFFFFFFFF)

    Path(path).write_bytes(
        b"\x89PNG\r\n\x1a\n"
        + chunk(b"IHDR", struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0))
        + chunk(b"IDAT", zlib.compress(rows, 6))
        + chunk(b"IEND", b"")
    )


def decode_texture(texture):
    if not isinstance(texture, dict):
        raise SceneError("Texture must be an object")
    width, height = texture.get("width"), texture.get("height")
    if not isinstance(width, int) or not isinstance(height, int) or not (0 < width <= 4096 and 0 < height <= 4096):
        raise SceneError("Texture size must be between 1 and 4096")
    try:
        pixels = base64.b64decode(texture.get("pixels", ""), validate=True)
    except (ValueError, TypeError) as error:
        raise SceneError("Texture pixels are not valid base64") from error
    if len(pixels) != width * height * 4:
        raise SceneError("Texture pixel count does not match its size")
    return width, height, pixels


def overlay_texture(pixels, rgb):
    """Composite a texture over a solid color, as MeshPart textures show their part color."""
    import numpy as np

    data = np.frombuffer(pixels, dtype=np.uint8).reshape(-1, 4).astype(np.float32)
    alpha = data[:, 3:4] / 255
    background = np.asarray(rgb, dtype=np.float32) * 255
    data[:, :3] = data[:, :3] * alpha + background * (1 - alpha)
    data[:, 3] = 255
    return (data + 0.5).astype(np.uint8).tobytes()


# ============================================================
# PRIMITIVES
# Each returns (positions, uvs, normals) per triangle corner in part space.
# ============================================================

def add_triangle(corners, a, b, c, normal, uvs=((0, 1), (1, 1), (1, 0))):
    # Wind counter-clockwise around the given normal.
    ab = [b[i] - a[i] for i in range(3)]
    ac = [c[i] - a[i] for i in range(3)]
    cross = (ab[1] * ac[2] - ab[2] * ac[1], ab[2] * ac[0] - ab[0] * ac[2], ab[0] * ac[1] - ab[1] * ac[0])
    if sum(cross[i] * normal[i] for i in range(3)) < 0:
        b, c = c, b
        uvs = (uvs[0], uvs[2], uvs[1])
    for point, uv in zip((a, b, c), uvs):
        corners.append((point, uv, normal))


def add_quad(corners, a, b, c, d, normal):
    add_triangle(corners, a, b, c, normal, ((0, 1), (1, 1), (1, 0)))
    add_triangle(corners, a, c, d, normal, ((0, 1), (1, 0), (0, 0)))


def face_normal(a, b, c):
    ab = [b[i] - a[i] for i in range(3)]
    ac = [c[i] - a[i] for i in range(3)]
    n = (ab[1] * ac[2] - ab[2] * ac[1], ab[2] * ac[0] - ab[0] * ac[2], ab[0] * ac[1] - ab[1] * ac[0])
    length = math.sqrt(sum(v * v for v in n)) or 1.0
    return tuple(v / length for v in n)


def outward(normal, point):
    """Flip a face normal so it points away from the part's center."""
    return normal if sum(normal[i] * point[i] for i in range(3)) >= 0 else tuple(-v for v in normal)


def block(size):
    x, y, z = (s / 2 for s in size)
    corners = []
    add_quad(corners, (x, -y, -z), (x, -y, z), (x, y, z), (x, y, -z), (1, 0, 0))
    add_quad(corners, (-x, -y, z), (-x, -y, -z), (-x, y, -z), (-x, y, z), (-1, 0, 0))
    add_quad(corners, (-x, y, -z), (x, y, -z), (x, y, z), (-x, y, z), (0, 1, 0))
    add_quad(corners, (-x, -y, z), (x, -y, z), (x, -y, -z), (-x, -y, -z), (0, -1, 0))
    add_quad(corners, (-x, -y, z), (x, -y, z), (x, y, z), (-x, y, z), (0, 0, 1))
    add_quad(corners, (x, -y, -z), (-x, -y, -z), (-x, y, -z), (x, y, -z), (0, 0, -1))
    return corners


def wedge(size):
    # Full bottom, vertical back face at +Z, slope rising from the front-bottom edge.
    x, y, z = (s / 2 for s in size)
    corners = []
    add_quad(corners, (-x, -y, z), (x, -y, z), (x, -y, -z), (-x, -y, -z), (0, -1, 0))
    add_quad(corners, (-x, -y, z), (x, -y, z), (x, y, z), (-x, y, z), (0, 0, 1))
    slope = face_normal((-x, -y, -z), (x, -y, -z), (x, y, z))
    add_quad(corners, (-x, -y, -z), (x, -y, -z), (x, y, z), (-x, y, z), outward(slope, (0, y, -z)))
    add_triangle(corners, (x, -y, -z), (x, -y, z), (x, y, z), (1, 0, 0))
    add_triangle(corners, (-x, -y, -z), (-x, -y, z), (-x, y, z), (-1, 0, 0))
    return corners


def corner_wedge(size):
    # Full bottom with the apex above the (+X, -Z) corner.
    x, y, z = (s / 2 for s in size)
    apex = (x, y, -z)
    a, b, c, d = (-x, -y, -z), (x, -y, -z), (x, -y, z), (-x, -y, z)
    corners = []
    add_quad(corners, d, c, b, a, (0, -1, 0))
    add_triangle(corners, b, c, apex, (1, 0, 0))
    add_triangle(corners, a, b, apex, (0, 0, -1))
    for p, q in ((c, d), (d, a)):
        normal = face_normal(p, q, apex)
        add_triangle(corners, p, q, apex, outward(normal, tuple((p[i] + q[i]) / 2 for i in range(3))))
    return corners


def cylinder(size):
    # Roblox cylinders run along the X axis.
    half = size[0] / 2
    radius = min(size[1], size[2]) / 2
    corners = []
    steps = PRIMITIVE_SEGMENTS
    ring = [
        (math.cos(2 * math.pi * i / steps), math.sin(2 * math.pi * i / steps))
        for i in range(steps + 1)
    ]
    for i in range(steps):
        (c0, s0), (c1, s1) = ring[i], ring[i + 1]
        p = [(-half, c0 * radius, s0 * radius), (half, c0 * radius, s0 * radius),
             (half, c1 * radius, s1 * radius), (-half, c1 * radius, s1 * radius)]
        u0, u1 = i / steps, (i + 1) / steps
        n0, n1 = (0, c0, s0), (0, c1, s1)
        for corner in ((p[0], (u0, 0), n0), (p[1], (u0, 1), n0), (p[2], (u1, 1), n1),
                       (p[0], (u0, 0), n0), (p[2], (u1, 1), n1), (p[3], (u1, 0), n1)):
            corners.append(corner)
        for sign in (-1, 1):
            add_triangle(
                corners, (sign * half, 0, 0), (sign * half, c0 * radius, s0 * radius),
                (sign * half, c1 * radius, s1 * radius), (sign, 0, 0),
                ((0.5, 0.5), (0.5 + c0 / 2, 0.5 + s0 / 2), (0.5 + c1 / 2, 0.5 + s1 / 2)),
            )
    return corners


def ball(size):
    radius = min(size) / 2
    rings, steps = PRIMITIVE_SEGMENTS // 2, PRIMITIVE_SEGMENTS
    corners = []

    def point(ring, step):
        theta = math.pi * ring / rings
        phi = 2 * math.pi * step / steps
        normal = (math.sin(theta) * math.cos(phi), math.cos(theta), math.sin(theta) * math.sin(phi))
        return tuple(v * radius for v in normal), (step / steps, ring / rings), normal

    for ring in range(rings):
        for step in range(steps):
            a, b = point(ring, step), point(ring + 1, step)
            c, d = point(ring + 1, step + 1), point(ring, step + 1)
            corners.extend((a, b, c, a, c, d))
    return corners


@lru_cache(maxsize=1)
def head_mesh():
    import mesh_asset

    return mesh_asset.decode((Path(__file__).parent / "primitives" / "head.mesh").read_bytes())


def head(size):
    return mesh_corners({**head_mesh(), "scale": size, "center": False})


PRIMITIVES = {
    "block": block,
    "wedge": wedge,
    "cornerWedge": corner_wedge,
    "cylinder": cylinder,
    "ball": ball,
    "head": head,
}


def mesh_corners(mesh):
    if not isinstance(mesh, dict):
        raise SceneError("Mesh part is missing mesh data")
    positions = decode_floats(mesh.get("positions"), "positions")
    if positions is None or len(positions) % 9:
        raise SceneError("Mesh positions must be whole triangles")
    count = len(positions) // 3
    uvs = decode_floats(mesh.get("uvs"), "uvs")
    normals = decode_floats(mesh.get("normals"), "normals")
    if uvs is not None and len(uvs) != count * 2:
        raise SceneError("Mesh uvs must have one entry per corner")
    if normals is not None and len(normals) != count * 3:
        raise SceneError("Mesh normals must have one entry per corner")
    scale = vector(mesh.get("scale", [1, 1, 1]), "mesh scale")
    offset = vector(mesh.get("offset", [0, 0, 0]), "mesh offset")

    center = [0.0, 0.0, 0.0]
    if mesh.get("center", True) and count:
        for axis in range(3):
            values = positions[axis::3]
            center[axis] = (min(values) + max(values)) / 2

    corners = []
    for i in range(count):
        point = tuple((positions[i * 3 + a] - center[a]) * scale[a] + offset[a] for a in range(3))
        # Roblox UVs start at the top-left; OBJ UVs start at the bottom-left.
        uv = (uvs[i * 2], 1.0 - uvs[i * 2 + 1]) if uvs is not None else (0.0, 0.0)
        if normals is not None:
            # Inverse-transpose of a diagonal scale keeps normals perpendicular.
            normal = [normals[i * 3 + a] / (scale[a] or 1.0) for a in range(3)]
        else:
            normal = None
        corners.append((point, uv, normal))
    if normals is None:
        for i in range(0, count, 3):
            normal = face_normal(corners[i][0], corners[i + 1][0], corners[i + 2][0])
            for j in range(3):
                corners[i + j] = (corners[i + j][0], corners[i + j][1], normal)
    return corners


# ============================================================
# BUILD
# ============================================================

def scene_id(body):
    return hashlib.sha256(body).hexdigest()[:24]


def build(payload, directory):
    """Write model.obj, model.mtl and textures into directory. Returns warnings."""
    if not isinstance(payload, dict):
        raise SceneError("Scene must be an object")
    parts = payload.get("parts")
    if not isinstance(parts, list) or not parts:
        raise SceneError("Scene has no parts")
    textures = payload.get("textures") or {}
    if not isinstance(textures, dict):
        raise SceneError("Scene textures must be an object")

    directory = Path(directory)
    directory.mkdir(parents=True, exist_ok=True)
    decoded_textures = {}
    materials = {}
    material_lines = []
    obj_lines = ["# Generated by Prism", "mtllib model.mtl", "o Model"]
    face_lines = []
    vertex_count = 0
    warnings = []

    def material_for(rgb, transparency, texture):
        texture_id = texture.get("id") if isinstance(texture, dict) else None
        mode = texture.get("mode", "overlay") if isinstance(texture, dict) else None
        if texture_id is not None and texture_id not in textures:
            warnings.append(f"Missing texture {texture_id}")
            texture_id = None
        key = (rgb if texture_id is None or mode == "overlay" else None, transparency, texture_id, mode)
        if key in materials:
            return materials[key]
        name = f"Material{len(materials)}"
        materials[key] = name
        material_lines.append(f"newmtl {name}")
        if texture_id is None:
            # Workbench treats Kd as linear; convert so the render shows the Studio color.
            kd = tuple(schema.srgb_to_linear(c) for c in rgb)
        else:
            kd = (1.0, 1.0, 1.0)
        material_lines.append("Kd {:.6f} {:.6f} {:.6f}".format(*kd))
        material_lines.append(f"d {1.0 - transparency:.6f}")
        if texture_id is not None:
            if texture_id not in decoded_textures:
                decoded_textures[texture_id] = decode_texture(textures[texture_id])
            width, height, pixels = decoded_textures[texture_id]
            if mode == "overlay":
                pixels = overlay_texture(pixels, rgb)
            filename = f"texture{len(materials)}.png"
            write_png(directory / filename, width, height, pixels)
            material_lines.append(f"map_Kd {filename}")
        material_lines.append("")
        return name

    for index, part in enumerate(parts):
        if not isinstance(part, dict):
            raise SceneError(f"Part {index} must be an object")
        kind = part.get("kind")
        size = vector(part.get("size"), "part size")
        cframe = vector(part.get("cframe"), "part cframe", 12)
        transparency = part.get("transparency", 0)
        if not isinstance(transparency, (int, float)) or not math.isfinite(transparency):
            transparency = 0
        transparency = min(max(float(transparency), 0.0), 1.0)
        if transparency >= 1.0:
            continue
        if kind == "mesh":
            corners = mesh_corners(part.get("mesh"))
        elif kind in PRIMITIVES:
            corners = PRIMITIVES[kind](size)
        else:
            raise SceneError(f"Unknown part kind {kind!r}")
        if isinstance(part.get("warning"), str):
            warnings.append(part["warning"])

        position = cframe[:3]
        r = cframe[3:]
        texture = part.get("texture")
        if part.get("layers"):
            import appearance
            corners, baked = appearance.bake(corners, size, color_of(part), texture, part["layers"], textures)
            baked_id = f"appearance:{index}"
            textures[baked_id] = baked
            texture = {"id": baked_id, "mode": "alpha"}
        material = material_for(color_of(part), transparency, texture)
        face_lines.append(f"usemtl {material}")
        positions, uvs, normals = [], [], []
        for point, uv, normal in corners:
            x, y, z = point
            positions.append("v {:.6f} {:.6f} {:.6f}".format(
                r[0] * x + r[1] * y + r[2] * z + position[0],
                r[3] * x + r[4] * y + r[5] * z + position[1],
                r[6] * x + r[7] * y + r[8] * z + position[2],
            ))
            uvs.append("vt {:.6f} {:.6f}".format(*uv))
            nx, ny, nz = normal
            wx = r[0] * nx + r[1] * ny + r[2] * nz
            wy = r[3] * nx + r[4] * ny + r[5] * nz
            wz = r[6] * nx + r[7] * ny + r[8] * nz
            length = math.sqrt(wx * wx + wy * wy + wz * wz) or 1.0
            normals.append("vn {:.6f} {:.6f} {:.6f}".format(wx / length, wy / length, wz / length))
        obj_lines.extend(positions)
        obj_lines.extend(uvs)
        obj_lines.extend(normals)
        for i in range(vertex_count + 1, vertex_count + len(corners) + 1, 3):
            face_lines.append(f"f {i}/{i}/{i} {i + 1}/{i + 1}/{i + 1} {i + 2}/{i + 2}/{i + 2}")
        vertex_count += len(corners)

    if vertex_count == 0:
        raise SceneError("Scene has no visible geometry")

    (directory / "model.mtl").write_text("\n".join(material_lines) + "\n", encoding="utf-8")
    (directory / "model.obj").write_text("\n".join(obj_lines + face_lines) + "\n", encoding="utf-8")
    return warnings


class SceneCache:
    """Stores built scenes by content hash under the cache directory."""

    def __init__(self, root, resolver=None):
        self.resolver = resolver
        self.root = Path(root) / "scenes"
        self.root.mkdir(parents=True, exist_ok=True)

    def path(self, identifier):
        if not isinstance(identifier, str) or not identifier.isalnum():
            raise SceneError("Invalid scene id")
        return self.root / identifier / "model.obj"

    def exists(self, identifier):
        try:
            return self.path(identifier).exists()
        except SceneError:
            return False

    def add(self, body, payload):
        if not isinstance(payload, dict) or not isinstance(payload.get("parts"), list):
            raise SceneError("Scene parts must be an array")
        if payload.get("textures") and not isinstance(payload["textures"], dict):
            raise SceneError("Scene textures must be an object")
        for part in payload["parts"]:
            if not isinstance(part, dict):
                raise SceneError("Part must be an object")
            if part.get("layers") and (not isinstance(part["layers"], list) or len(part["layers"]) > 64):
                raise SceneError("Part layers must be an array of at most 64 appearances")
            entries = [part.get("mesh"), part.get("texture"), *(part.get("layers") or [])]
            for entry in entries:
                if entry is not None and not isinstance(entry, dict):
                    raise SceneError("Part mesh, texture and layers must be objects")
                if entry and "assetId" in entry:
                    import assets
                    try:
                        assets.asset_id(entry["assetId"])
                    except assets.AssetError as error:
                        raise SceneError(str(error)) from error
        recovery_warnings, incomplete = [], False
        if self.resolver:
            payload, recovery_warnings, incomplete = self.resolver.resolve(payload)
        # Resolved bytes change the ID after credential repair, invalidating renderer objects.
        resolved = json.dumps(payload, sort_keys=True, separators=(",", ":")).encode()
        identifier = scene_id(b"appearance-v4:" + resolved)
        if incomplete:
            identifier += uuid.uuid4().hex[:8]
        directory = self.root / identifier
        if (directory / "model.obj").exists():
            (directory / "model.obj").touch()
            manifest = directory / "warnings.json"
            return identifier, json.loads(manifest.read_text()) if manifest.exists() else []
        staging = self.root / f".{identifier}.tmp"
        shutil.rmtree(staging, ignore_errors=True)
        try:
            warnings = list(dict.fromkeys(recovery_warnings + payload.get("warnings", []) + build(payload, staging)))
            (staging / "warnings.json").write_text(json.dumps(warnings), encoding="utf-8")
            (staging / "incomplete").write_text("1" if incomplete else "0", encoding="utf-8")
            staging.replace(directory)
        finally:
            shutil.rmtree(staging, ignore_errors=True)
        self.prune()
        return identifier, warnings

    def incomplete(self, identifier):
        marker = self.path(identifier).parent / "incomplete"
        return marker.exists() and marker.read_text() == "1"

    def prune(self):
        scenes = sorted(
            (path for path in self.root.iterdir() if path.is_dir() and not path.name.startswith(".")),
            key=lambda path: (path / "model.obj").stat().st_mtime if (path / "model.obj").exists() else 0,
            reverse=True,
        )
        for path in scenes[MAX_CACHED_SCENES:]:
            shutil.rmtree(path, ignore_errors=True)
