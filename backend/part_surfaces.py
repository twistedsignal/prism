"""Legacy part surfaces: repeating detail tiles and hinge/motor indicators."""

import base64
from functools import lru_cache
from pathlib import Path

FACES = ("Right", "Left", "Top", "Bottom", "Back", "Front")
PATTERNS = {"Studs": 0, "Glue": 1, "Weld": 1, "Inlet": 2, "Universal": 3}
PINS = {"Hinge", "Motor", "SteppingMotor"}
TYPES = {*PATTERNS, *PINS, "Smooth", "SmoothNoOutlines"}


def validate(value):
    from scene import SceneError

    if value is None:
        return {}
    if not isinstance(value, dict) or any(
        face not in FACES or not isinstance(kind, str) or kind not in TYPES
        for face, kind in value.items()
    ):
        raise SceneError("Part surfaces must map NormalId face names to SurfaceType names")
    return value


@lru_cache(maxsize=1)
def tiles():
    import numpy as np

    return np.frombuffer((Path(__file__).parent / "surfaces" / "tiles.bin").read_bytes(),
                         dtype=np.uint8).reshape(4, 128, 128)


def texture(kind, rgb):
    """Apply the atlas's neutral-centered shading in linear light before encoding."""
    import numpy as np
    from schema import srgb_to_linear

    light = tiles()[PATTERNS[kind]][..., None] / 128 * [srgb_to_linear(c) for c in rgb]
    encoded = np.where(light <= 0.0031308, light * 12.92,
                       1.055 * np.maximum(light, 0) ** (1 / 2.4) - 0.055)
    pixels = np.full((128, 128, 4), 255, dtype=np.uint8)
    pixels[..., :3] = (np.clip(encoded, 0, 1) * 255 + 0.5).astype(np.uint8)
    return {"width": 128, "height": 128, "pixels": base64.b64encode(pixels.tobytes()).decode("ascii")}


def face_indices(corners, kind):
    """Slopes retain their Roblox face ID even when Y is the dominant normal."""
    result = []
    fixed = {"wedge": [3, 3, 4, 4, 5, 5, 0, 1],
             "cornerWedge": [3, 3, 0, 5, 4, 1]}.get(kind)
    for start in range(0, len(corners), 3):
        if fixed:
            index = fixed[start // 3]
        else:
            normal = [sum(c[2][a] for c in corners[start:start + 3]) for a in range(3)]
            axis = max(range(3), key=lambda a: abs(normal[a]))
            index = axis * 2 + (0 if normal[axis] > 0 else 1)
        result.extend([index] * 3)
    return result


def dimensions(face, size, kind):
    x, y, z = size
    width, height = {"Right": (z, y), "Left": (z, y), "Top": (x, z),
                     "Bottom": (x, z), "Back": (x, y), "Front": (x, y)}[face]
    # Studio adds the two local axes along a slope, rather than using its hypotenuse.
    if (kind == "wedge" and face == "Front") or (kind == "cornerWedge" and face == "Back"):
        height = y + z
    elif kind == "cornerWedge" and face == "Left":
        height = y + x
    return width, height


def prepare(corners, size, kind, surfaces, rgb, textures):
    """Return tiled face groups and layers for the decal/clothing compositor."""
    import appearance

    indices = face_indices(corners, kind)
    groups, layers = {}, []
    for index, face in enumerate(FACES):
        pattern = surfaces.get(face)
        if pattern not in PATTERNS or index not in indices:
            continue
        key = f"part-surface:{PATTERNS[pattern]}:{rgb}"
        if key not in textures:
            textures[key] = texture(pattern, rgb)
        width, height = dimensions(face, size, kind)
        base_height = size[1] if face not in ("Top", "Bottom") else size[2]
        layers.append({"id": key, "face": face, "repeat": [2, 2 * base_height / max(height, 1e-6)]})
    for start in range(0, len(corners), 3):
        index = indices[start]
        face = FACES[index]
        pattern = surfaces.get(face)
        key = f"part-surface:{PATTERNS[pattern]}:{rgb}" if pattern in PATTERNS else None
        triangle = corners[start:start + 3]
        if key:
            uv = appearance.project([c[0] for c in triangle], face, size)
            width, height = dimensions(face, size, kind)
            triangle = [(point, (float(p[0] * width / 2), float(1 - p[1] * height / 2)), normal)
                        for (point, _, normal), p in zip(triangle, uv)]
        groups.setdefault(key, []).extend(triangle)
    return groups if layers else None, layers, indices


def indicators(corners, kind, surfaces):
    """Place pins at each actual face's center, oriented along its outward normal."""
    import numpy as np
    from scene import cylinder

    indices = face_indices(corners, kind)
    for index, face in enumerate(FACES):
        surface = surfaces.get(face)
        if surface not in PINS or index not in indices:
            continue
        selected = [c for c, i in zip(corners, indices) if i == index]
        points = np.asarray([c[0] for c in selected])
        normal = np.mean([c[2] for c in selected], axis=0)
        normal /= max(np.linalg.norm(normal), 1e-8)
        center = (points.min(axis=0) + points.max(axis=0)) / 2
        # A slope's bounding-box center lies on its plane. Curved patches need
        # the outermost extent, so the indicator doesn't start inside the part.
        center += normal * (np.max(points @ normal) - center @ normal)
        tangent = np.cross(normal, [0, 1, 0] if abs(normal[1]) < 0.9 else [0, 0, 1])
        tangent /= np.linalg.norm(tangent)
        bitangent = np.cross(normal, tangent)
        shapes = [(0.5, 0.4, (1.0, 1.0, 0.8))]
        if surface != "Hinge":
            shapes.insert(0, (0.1, 0.6, (0.64, 0.64, 0.64)))
        for length, diameter, color in shapes:
            result = []
            for point, uv, n in cylinder([length, diameter, diameter]):
                p = center + normal * (point[0] + length / 2) + tangent * point[1] + bitangent * point[2]
                n = normal * n[0] + tangent * n[1] + bitangent * n[2]
                result.append((tuple(p), uv, tuple(n)))
            yield result, color
